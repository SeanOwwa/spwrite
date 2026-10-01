// Property test for SemanticContextRetriever project scoping (task 7.2).
//
// Feature: ai_feature_3.6 — on-device semantic retrieval (RAG).
//
// Property 3: Retrieval is project-scoped. For any mix of projects in the
// store, `retrieve(query)` for project P returns only passages whose `sourceId`
// belongs to P; no other project's chunk can ever appear.
//
// **Validates: Requirements 1.5, 8.4**
//
// Strategy: generate a compact "world spec" — a set of projects, each owning a
// set of sources, each source owning a few chunks with arbitrary text. Every
// source id is made globally unique by prefixing it with its owning project id,
// mirroring the app (source ids are globally unique), so a `sourceId` also
// records which project produced it. All chunks across all projects are stored
// in ONE shared in-memory database through the real
// `ChunkEmbeddingRepository`, so a scoping bug (a missing project filter, a
// cross-project row leak) would surface as a foreign passage.
//
// The query is embedded and chunks are scored by a deterministic fake
// `EmbeddingModel` (design §"Component tests with a fake EmbeddingModel"): a
// hashed bag-of-words → fixed-dim vector, so retrieval results are exact and
// reproducible with no real model and no network. To make the property bite, we
// use a low relevance floor and a large topN so the retriever returns as many
// passages as it can — if any cross-project row could leak, it would be
// returned.
//
// For each generated case a FRESH in-memory database is opened via
// `DatabaseProvider.openAppDatabase(overridePath: inMemoryDatabasePath)` so
// cases never leak into each other, and it is closed in a `finally` block. The
// `forAll` block is async: kiri_check 1.3.1 declares the block as
// `FutureOr<void> Function(T)` and awaits it internally (see the sibling
// data-layer property tests), so repository/retriever calls are awaited
// directly.
//
// The test asserts, for the retrieve of a randomly-chosen present project P and
// a random query:
//   - every returned passage's `sourceId` belongs to P (its prefix is P's id);
//   - equivalently, no returned `sourceId` belongs to any other project;
//   - `hasProjectMaterial()` for P reflects exactly whether P stored any chunk,
//     independent of the other projects' contents.

import 'package:flutter_test/flutter_test.dart';
import 'package:kiri_check/kiri_check.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spwrite/data/ai/chunk_embedding_repository.dart';
import 'package:spwrite/data/ai/chunker.dart';
import 'package:spwrite/data/ai/semantic_context_retriever.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/domain/ai/context_retriever.dart';
import 'package:spwrite/domain/ai/embedding_model.dart';
import 'package:spwrite/domain/project.dart';

/// The fixed embedding dimension used by the fake model and stored rows.
const int _dim = 16;

/// The fake model id tagged onto stored rows (also what the retriever's dim
/// guard compares length against — only the length matters here).
const String _modelId = 'fake-embed-v1';

/// A deterministic, offline [EmbeddingModel]: it maps text to a fixed-length
/// vector by hashing its whitespace-delimited tokens into buckets, so the same
/// text always yields the same vector and no real model or network is involved
/// (design §"Component tests with a fake EmbeddingModel"). Vector *values* are
/// irrelevant to project scoping — only that every chunk and query embed to the
/// same [dimension], so cross-project rows are eligible to be returned and a
/// scoping bug would surface.
class _FakeEmbeddingModel implements EmbeddingModel {
  @override
  int get dimension => _dim;

  @override
  String get modelId => _modelId;

  @override
  Future<void> load() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<List<double>> embed(String text) async {
    final List<double> v = List<double>.filled(_dim, 0.0);
    final List<String> tokens =
        text.toLowerCase().split(RegExp(r'\s+')).where((String t) => t.isNotEmpty).toList();
    // A non-empty text with no usable tokens still needs a non-zero vector so it
    // is scored rather than dropped as a zero vector; seed a single bucket.
    if (tokens.isEmpty) {
      v[text.hashCode.abs() % _dim] += 1.0;
      return v;
    }
    for (final String token in tokens) {
      v[token.hashCode.abs() % _dim] += 1.0;
    }
    return v;
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    final List<List<double>> out = <List<double>>[];
    for (final String t in texts) {
      out.add(await embed(t));
    }
    return out;
  }
}

/// One generated chunk: a text-pool index (so distinct/overlapping text and the
/// empty string all appear) driving both the chunk body and its content hash.
typedef ChunkSpec = ({int textIdx});

/// One generated source: how many chunks it owns.
typedef SourceSpec = ({int chunkCount});

/// One generated project: how many sources it owns, each with its chunks.
typedef ProjectSpec = ({List<SourceSpec> sources});

/// The whole generated world plus the selectors that pick which present project
/// to query and which query text to use.
typedef WorldSpec = ({
  List<ProjectSpec> projects,
  int projectSelector,
  int querySelector,
});

/// Small text pool: distinct phrases, overlapping tokens, and the empty string,
/// so chunk texts (and hashes) vary and some queries share tokens with chunks.
const List<String> _textPool = <String>[
  'the dragon guards the northern gate at dawn',
  'a quiet harbor town under grey autumn rain',
  'she remembered the promise made in the orchard',
  'the council debated the fate of the border war',
  'salt wind and the cry of gulls over the pier',
  'overlap tokens dragon harbor promise council',
  'dragon',
  'harbor',
  '', // empty chunk text — still a valid stored row
];

/// Query pool: some share tokens with the text pool (to produce matches), some
/// are unrelated, and one is blank (early-return path).
const List<String> _queryPool = <String>[
  'dragon gate dawn',
  'harbor rain autumn',
  'promise orchard',
  'border war council',
  'gulls pier salt',
  'completely unrelated query terms zzz',
  '   ', // whitespace-only → retriever returns [] without touching the index
];

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Arbitrary<ChunkSpec> chunkSpec() =>
      integer(min: 0, max: _textPool.length - 1).map((int i) => (textIdx: i));

  // A project spec: a list of sources, each a list of chunk specs. We keep only
  // the per-source chunk count and regenerate each chunk's text below from a
  // deterministic index so the spec stays compact.
  Arbitrary<ProjectSpec> projectSpec() => list(
        list(chunkSpec(), minLength: 0, maxLength: 3),
        minLength: 0,
        maxLength: 3,
      ).map(
        (List<List<ChunkSpec>> sources) => (
          sources: sources
              .map((List<ChunkSpec> cs) => (chunkCount: cs.length))
              .toList(),
        ),
      );

  Arbitrary<WorldSpec> worldSpec() => combine3(
        // minLength 1 guarantees at least one project to query.
        list(projectSpec(), minLength: 1, maxLength: 4),
        integer(min: 0, max: 1000),
        integer(min: 0, max: 1000),
      ).map(
        (rec) => (
          projects: rec.$1,
          projectSelector: rec.$2,
          querySelector: rec.$3,
        ),
      );

  /// Builds the per-chunk text for the (source, chunk) position deterministically
  /// so a stored chunk's body is reproducible and content hashes vary.
  String textFor(int projectIdx, int sourceIdx, int chunkIdx) {
    final int pick = (projectIdx * 31 + sourceIdx * 7 + chunkIdx * 3) % _textPool.length;
    return _textPool[pick];
  }

  property('Property 3: retrieval is project-scoped — no foreign passage ever '
      'appears', () {
    forAll(
      worldSpec(),
      (WorldSpec world) async {
        final Database db = await DatabaseProvider.openAppDatabase(
          overridePath: inMemoryDatabasePath,
        );
        try {
          final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
          final _FakeEmbeddingModel model = _FakeEmbeddingModel();

          // Materialize every project's chunks into ONE shared store. Project
          // ids are p0..pN; source ids are globally unique by prefixing the
          // project id, so a returned sourceId records its owning project.
          final List<String> projectIds = <String>[];
          for (int pi = 0; pi < world.projects.length; pi++) {
            final String projectId = 'p$pi';
            projectIds.add(projectId);

            // Seed the parent project row so the ai_chunk_embeddings FK holds
            // (the FFI factory enables PRAGMA foreign_keys = ON).
            await db.insert(
              DatabaseProvider.projectsTable,
              Project.create(
                id: projectId,
                name: 'Project $pi',
                now: DateTime.utc(2024, 1, 1),
              ).toRow(),
            );

            final ProjectSpec pspec = world.projects[pi];
            for (int si = 0; si < pspec.sources.length; si++) {
              final String sourceId = '$projectId-src-$si';
              final int chunkCount = pspec.sources[si].chunkCount;
              final List<EmbeddedChunk> embedded = <EmbeddedChunk>[];
              for (int ci = 0; ci < chunkCount; ci++) {
                final String text = textFor(pi, si, ci);
                final SourceChunk chunk = SourceChunk(
                  id: DocumentChunker.chunkId(sourceId, ci),
                  sourceId: sourceId,
                  sourceType: ChunkSourceType.document,
                  sourceTitle: 'Source $si of $projectId',
                  chunkIndex: ci,
                  text: text,
                  contentHash: DocumentChunker.contentHashOf(text),
                );
                embedded.add(EmbeddedChunk(
                  chunk: chunk,
                  vector: await model.embed(text),
                ));
              }
              await repo.upsertChunks(
                projectId,
                embedded,
                modelId: model.modelId,
                dim: model.dimension,
              );
            }
          }

          // Pick a present project to query and a query text.
          final String targetProject =
              projectIds[world.projectSelector % projectIds.length];
          final String query = _queryPool[world.querySelector % _queryPool.length];

          // A large topN and a floor at the bottom of cosine's range so the
          // retriever returns as many passages as it possibly can — the harshest
          // condition for scoping (a leak would be returned rather than trimmed).
          final SemanticContextRetriever retriever = SemanticContextRetriever(
            embeddingModel: model,
            embeddings: repo,
            projectId: targetProject,
            topN: 1000,
            minSimilarity: -1.0,
          );

          final List<RetrievedPassage> passages =
              await retriever.retrieve(query);

          // Every returned passage must belong to the target project: its source
          // id is prefixed with that project's id. No other project's chunk can
          // appear (Req 1.5, 8.4).
          for (final RetrievedPassage p in passages) {
            expect(
              p.sourceId.startsWith('$targetProject-'),
              isTrue,
              reason: 'retrieve("$query") for $targetProject returned a foreign '
                  'passage from sourceId=${p.sourceId}',
            );
          }
          // Equivalently, no returned source belongs to a different project.
          final Set<String> foreignPrefixes = <String>{
            for (final String id in projectIds)
              if (id != targetProject) '$id-',
          };
          for (final RetrievedPassage p in passages) {
            for (final String foreign in foreignPrefixes) {
              expect(
                p.sourceId.startsWith(foreign),
                isFalse,
                reason: 'foreign passage ${p.sourceId} leaked into '
                    '$targetProject results',
              );
            }
          }

          // hasProjectMaterial reflects only the target project's own stored
          // chunks, independent of the other projects (Req 1.5, 8.4).
          final int expectedTargetChunks = _expectedChunkCount(
            world,
            projectIds.indexOf(targetProject),
          );
          expect(
            await retriever.hasProjectMaterial(),
            expectedTargetChunks > 0,
          );
        } finally {
          await db.close();
        }
      },
      maxExamples: 80,
    );
  });
}

/// The number of chunks the project at [projectIdx] contributes, summed across
/// its sources — the ground truth for `hasProjectMaterial`.
int _expectedChunkCount(WorldSpec world, int projectIdx) {
  int count = 0;
  for (final SourceSpec s in world.projects[projectIdx].sources) {
    count += s.chunkCount;
  }
  return count;
}
