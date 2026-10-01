// Property test for the deterministic, stable ordering of
// [SemanticContextRetriever] (ai_feature_3.6 task 7.3).
//
// Feature: ai_feature_3.6, Property 4: Retrieval is deterministic and stable.
// For a fixed index and query, repeated `retrieve` calls return an identical
// ordered passage list; equal-score ties always break by `(sourceId,
// chunkIndex)` ascending, with the stable chunk `id` as the final
// discriminator.
//
// **Validates: Requirements 1.6**
//
// This file exercises [SemanticContextRetriever]
// (`lib/data/ai/semantic_context_retriever.dart`) end to end against a real
// [ChunkEmbeddingRepository] over an in-memory SQLite database (the FFI
// factory, matching `chunk_embedding_repository_test.dart`) and a deterministic
// fake [EmbeddingModel]. No real model and no network are involved, so results
// are exact and reproducible (design §Testing Strategy).
//
// Strategy: each generated case builds a small project whose chunks are drawn
// from a *tiny fixed palette of one-hot basis vectors*. Because many chunks
// share the same vector, they score identically against the query, which is the
// whole point — it forces score ties so the `(sourceId, chunkIndex)` → stable
// `id` tie-break is actually exercised rather than left dormant. The fake
// embedding model maps a query to the same basis vectors, so the cosine scores
// are exact small rationals (0.0 or 1.0 after normalization) and the resulting
// order is fully determined by the tie-break rule, letting the test assert the
// exact expected order rather than merely "stable".

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

/// The embedding dimension used throughout — one basis vector per axis.
const int _dim = 4;

/// The catalog-style id stored rows and the fake model share, so no row is
/// skipped as a model mismatch.
const String _modelId = 'bge-small-en-v1.5';

/// A deterministic fake [EmbeddingModel] that maps a text to one of the [_dim]
/// one-hot basis vectors, chosen by a caller-supplied lookup.
///
/// Making the query embed to a basis vector means the cosine score of every
/// stored chunk is exactly 0.0 (orthogonal axis) or 1.0 (same axis), so the
/// candidate set that clears the relevance floor is precisely the chunks on the
/// query's axis, and their mutual order is decided solely by the tie-break.
class _BasisEmbeddingModel implements EmbeddingModel {
  _BasisEmbeddingModel(this._axisOf);

  /// Maps a raw text to the basis axis `[0, _dim)` it embeds onto.
  final int Function(String text) _axisOf;

  @override
  int get dimension => _dim;

  @override
  String get modelId => _modelId;

  @override
  Future<void> load() async {}

  @override
  Future<List<double>> embed(String text) async {
    final int axis = _axisOf(text) % _dim;
    return <double>[
      for (int i = 0; i < _dim; i++) i == axis ? 1.0 : 0.0,
    ];
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async =>
      <List<double>>[for (final String t in texts) await embed(t)];

  @override
  Future<void> dispose() async {}
}

/// A lightweight description of a chunk to seed: its source, position, and the
/// basis axis its stored vector points along (which fixes its score).
class _ChunkSpec {
  const _ChunkSpec({
    required this.sourceId,
    required this.chunkIndex,
    required this.axis,
  });

  final String sourceId;
  final int chunkIndex;
  final int axis;

  /// The stable chunk id the repository derives from `(sourceId, chunkIndex)`.
  String get id => DocumentChunker.chunkId(sourceId, chunkIndex);
}

void main() {
  setUpAll(() {
    // In-memory FFI factory: the retriever + repository run over a genuine
    // SQLite store on the dev machine without touching disk or a platform DB
    // (matches the other sqlite repository tests).
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// Seeds the parent project row so the `ai_chunk_embeddings` FK is satisfied
  /// (the FFI factory enables `PRAGMA foreign_keys = ON`).
  Future<void> seedProject(Database db, String id) async {
    await db.insert(
      DatabaseProvider.projectsTable,
      Project.create(id: id, name: 'Project $id', now: DateTime.utc(2024))
          .toRow(),
    );
  }

  /// Writes [specs] into the repository as one-hot embedded chunks. Each chunk's
  /// text is a distinct marker so a retrieved passage can be traced back to its
  /// spec, and its vector is the [_ChunkSpec.axis] basis vector.
  Future<void> seedChunks(
    ChunkEmbeddingRepository repo,
    String projectId,
    List<_ChunkSpec> specs,
  ) async {
    final List<EmbeddedChunk> embedded = <EmbeddedChunk>[
      for (final _ChunkSpec s in specs)
        EmbeddedChunk(
          chunk: SourceChunk(
            id: s.id,
            sourceId: s.sourceId,
            sourceType: ChunkSourceType.document,
            sourceTitle: 'Title ${s.sourceId}',
            chunkIndex: s.chunkIndex,
            text: 'text ${s.sourceId}#${s.chunkIndex}',
            contentHash: DocumentChunker.contentHashOf(
                'text ${s.sourceId}#${s.chunkIndex}'),
          ),
          vector: <double>[
            for (int i = 0; i < _dim; i++) i == (s.axis % _dim) ? 1.0 : 0.0,
          ],
        ),
    ];
    await repo.upsertChunks(projectId, embedded, modelId: _modelId, dim: _dim);
  }

  /// The tie-break key the retriever must sort equal-scoring chunks by:
  /// `(sourceId, chunkIndex)` ascending, then the stable `id`.
  int compareTieBreak(_ChunkSpec a, _ChunkSpec b) {
    final int bySource = a.sourceId.compareTo(b.sourceId);
    if (bySource != 0) return bySource;
    final int byIndex = a.chunkIndex.compareTo(b.chunkIndex);
    if (byIndex != 0) return byIndex;
    return a.id.compareTo(b.id);
  }

  /// Computes the exact ordered ids the retriever should return for a query on
  /// [queryAxis], given [specs] and [topN]: keep chunks whose axis matches the
  /// query (score 1.0, clearing the floor), drop the rest (score 0.0), then sort
  /// the survivors purely by the tie-break (all scores are equal), then cap.
  List<String> expectedOrder(
    List<_ChunkSpec> specs,
    int queryAxis,
    int topN,
  ) {
    final List<_ChunkSpec> survivors = specs
        .where((_ChunkSpec s) => (s.axis % _dim) == (queryAxis % _dim))
        .toList()
      ..sort(compareTieBreak);
    return <String>[
      for (final _ChunkSpec s in survivors.take(topN)) s.id,
    ];
  }

  // --- Generators ---------------------------------------------------------

  // A handful of source ids whose lexical order is deliberately *not* their
  // insertion order, so a naive "insertion order" implementation would fail the
  // tie-break assertion.
  const List<String> sourceIds = <String>['doc-c', 'doc-a', 'doc-b'];

  // A single chunk spec: a source, a chunk index in a small range, and a basis
  // axis. Small ranges guarantee frequent (sourceId, chunkIndex, axis)
  // collisions across a case, which is what forces score ties.
  Arbitrary<_ChunkSpec> chunkSpec() => combine3(
        integer(min: 0, max: sourceIds.length - 1),
        integer(min: 0, max: 3), // chunk index within a source
        integer(min: 0, max: _dim - 1), // basis axis → fixes the score
      ).map((r) => _ChunkSpec(
            sourceId: sourceIds[r.$1],
            chunkIndex: r.$2,
            axis: r.$3,
          ));

  // A project is a set of chunk specs deduplicated by stable id (the repository
  // keys rows by id, so two specs with the same (sourceId, chunkIndex) would be
  // an upsert-in-place, not two rows). We keep the *last* spec per id to mirror
  // the repository's replace-by-id semantics.
  Arbitrary<List<_ChunkSpec>> project() =>
      list(chunkSpec(), minLength: 1, maxLength: 12).map((List<_ChunkSpec> raw) {
        final Map<String, _ChunkSpec> byId = <String, _ChunkSpec>{};
        for (final _ChunkSpec s in raw) {
          byId[s.id] = s;
        }
        return byId.values.toList();
      });

  group('SemanticContextRetriever ordering — Property 4 (Req 1.6)', () {
    property('repeated identical queries return an identical ordered list', () {
      forAll(
        combine2(project(), integer(min: 0, max: _dim - 1)),
        ((List<_ChunkSpec>, int) r) async {
          final List<_ChunkSpec> specs = r.$1;
          final int queryAxis = r.$2;

          final Database db = await DatabaseProvider.openAppDatabase(
            overridePath: inMemoryDatabasePath,
          );
          try {
            final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
            await seedProject(db, 'p1');
            await seedChunks(repo, 'p1', specs);

            final SemanticContextRetriever retriever =
                SemanticContextRetriever(
              embeddingModel: _BasisEmbeddingModel((_) => queryAxis),
              embeddings: repo,
              projectId: 'p1',
              // A topN comfortably above the palette so ties, not the cap,
              // decide most cases; a couple of runs will still hit the cap.
              topN: 20,
            );

            final List<RetrievedPassage> first =
                await retriever.retrieve('q$queryAxis');
            final List<RetrievedPassage> second =
                await retriever.retrieve('q$queryAxis');
            final List<RetrievedPassage> third =
                await retriever.retrieve('q$queryAxis');

            List<String> ids(List<RetrievedPassage> ps) =>
                ps.map((RetrievedPassage p) => p.sourceId).toList();
            List<double> scores(List<RetrievedPassage> ps) =>
                ps.map((RetrievedPassage p) => p.score).toList();

            // Identical across repeated calls (deterministic + stable).
            expect(ids(second), ids(first),
                reason: 'second call must match the first exactly');
            expect(ids(third), ids(first),
                reason: 'third call must match the first exactly');
            expect(scores(second), scores(first));
          } finally {
            await db.close();
          }
        },
        maxExamples: 60,
      );
    });

    property(
        'equal-score ties break by (sourceId, chunkIndex) then stable id, '
        'and scores are non-increasing', () {
      forAll(
        combine2(project(), integer(min: 0, max: _dim - 1)),
        ((List<_ChunkSpec>, int) r) async {
          final List<_ChunkSpec> specs = r.$1;
          final int queryAxis = r.$2;
          const int topN = 20;

          final Database db = await DatabaseProvider.openAppDatabase(
            overridePath: inMemoryDatabasePath,
          );
          try {
            final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
            await seedProject(db, 'p1');
            await seedChunks(repo, 'p1', specs);

            final SemanticContextRetriever retriever =
                SemanticContextRetriever(
              embeddingModel: _BasisEmbeddingModel((_) => queryAxis),
              embeddings: repo,
              projectId: 'p1',
              topN: topN,
            );

            final List<RetrievedPassage> got =
                await retriever.retrieve('q$queryAxis');

            // The retriever returns sourceId/sourceTitle/score/text but not the
            // chunk id; the expected order is by id though. Map each returned
            // passage back to its spec via the unique per-chunk text marker to
            // recover the id sequence for an exact comparison.
            final Map<String, _ChunkSpec> byText = <String, _ChunkSpec>{
              for (final _ChunkSpec s in specs)
                'text ${s.sourceId}#${s.chunkIndex}': s,
            };
            final List<String> gotIds = <String>[
              for (final RetrievedPassage p in got) byText[p.text]!.id,
            ];

            expect(
              gotIds,
              expectedOrder(specs, queryAxis, topN),
              reason: 'ties must resolve by (sourceId, chunkIndex) then id',
            );

            // Scores must be non-increasing (descending order overall).
            for (int i = 1; i < got.length; i++) {
              expect(
                got[i - 1].score,
                greaterThanOrEqualTo(got[i].score),
                reason: 'passages must be ordered by non-increasing score',
              );
            }
          } finally {
            await db.close();
          }
        },
        maxExamples: 80,
      );
    });
  });

  group('SemanticContextRetriever ordering — concrete tie-break (Req 1.6)', () {
    test(
        'chunks with equal scores come back sorted by (sourceId, chunkIndex), '
        'not by insertion order', () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, 'p1');

        // Insert in a deliberately scrambled order; every chunk is on axis 0 so
        // all four tie at score 1.0 against a query on axis 0. Correct output
        // order is doc-a#0, doc-a#1, doc-b#0, doc-c#0.
        final List<_ChunkSpec> specs = <_ChunkSpec>[
          const _ChunkSpec(sourceId: 'doc-c', chunkIndex: 0, axis: 0),
          const _ChunkSpec(sourceId: 'doc-a', chunkIndex: 1, axis: 0),
          const _ChunkSpec(sourceId: 'doc-b', chunkIndex: 0, axis: 0),
          const _ChunkSpec(sourceId: 'doc-a', chunkIndex: 0, axis: 0),
        ];
        await seedChunks(repo, 'p1', specs);

        final SemanticContextRetriever retriever = SemanticContextRetriever(
          embeddingModel: _BasisEmbeddingModel((_) => 0),
          embeddings: repo,
          projectId: 'p1',
          topN: 10,
        );

        final List<RetrievedPassage> got = await retriever.retrieve('query');
        expect(
          got.map((RetrievedPassage p) => p.text).toList(),
          <String>[
            'text doc-a#0',
            'text doc-a#1',
            'text doc-b#0',
            'text doc-c#0',
          ],
        );
        // All scores are the identical tie value.
        expect(got.map((RetrievedPassage p) => p.score).toSet(), hasLength(1));
      } finally {
        await db.close();
      }
    });

    test('a higher-scoring chunk always precedes tied lower-scoring chunks',
        () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, 'p1');

        // One chunk on the query axis (score 1.0), two off-axis (score 0.0,
        // dropped by the floor). Only the on-axis chunk should return.
        await seedChunks(repo, 'p1', <_ChunkSpec>[
          const _ChunkSpec(sourceId: 'doc-a', chunkIndex: 0, axis: 1),
          const _ChunkSpec(sourceId: 'doc-b', chunkIndex: 0, axis: 2),
          const _ChunkSpec(sourceId: 'doc-c', chunkIndex: 0, axis: 3),
        ]);

        final SemanticContextRetriever retriever = SemanticContextRetriever(
          embeddingModel: _BasisEmbeddingModel((_) => 1),
          embeddings: repo,
          projectId: 'p1',
          topN: 10,
        );

        final List<RetrievedPassage> got = await retriever.retrieve('query');
        expect(got, hasLength(1));
        expect(got.single.text, 'text doc-a#0');
      } finally {
        await db.close();
      }
    });
  });
}
