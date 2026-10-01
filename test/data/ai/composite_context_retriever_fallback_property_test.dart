// Property test for CompositeContextRetriever fallback availability (task 9.2).
//
// Feature: ai_feature_3.6 — on-device semantic retrieval (RAG).
//
// Property 9: Fallback preserves availability. For every combination of
// {embedding-model ready?, index present/partial/empty?, semantic throws?} the
// composite returns a well-formed (possibly empty) passage list *without
// throwing* for a retrieval reason, and never blocks — the semantic → keyword →
// chat-only precedence holds behind the `ContextRetriever` seam (Req 7.5).
//
// **Validates: Requirements 7.1, 7.2, 7.3, 7.4**
//
// Strategy: build one CompositeContextRetriever per generated case over
//   - a real `SemanticContextRetriever` scoped to a project in a FRESH in-memory
//     store, with a `_FakeEmbeddingModel` that either embeds deterministically
//     or *throws* on `embed` (the query-time semantic failure of Req 7.4), and
//   - a real `KeywordContextRetriever` over lightweight in-memory fake
//     document/character repositories (its only real dependencies), so the
//     keyword tier is exercised for real without a DB.
//
// The generated `Scenario` spans the three axes the property names:
//   * embeddingReady  — the `isSemanticReady` gate (model downloaded or not, Req
//     7.1);
//   * indexState      — empty / partial / present stored vectors (Req 7.2). A
//     "partial" index is modelled as a present-but-small index (a build in
//     progress still holds ≥1 vector), which the composite treats as available;
//   * semanticThrows  — whether the embedding model throws at query time
//     (model-load / embed error, Req 7.4);
//   * keywordMaterial — whether the project has any keyword-indexable documents/
//     characters, so the fallback itself is sometimes empty (→ chat-only, Req
//     7.3) and sometimes non-empty.
//
// For each case the test asserts the availability invariants:
//   1. `retrieve(query)` completes without throwing and returns a non-null,
//      well-formed list (every passage has the required fields) — the assistant
//      always has a working path (Req 7).
//   2. When semantic is *not* attempted (not ready, or empty index) OR it throws
//      OR it returns nothing usable, the result equals the keyword tier's own
//      result — the fallback is what surfaces (Req 7.1, 7.2, 7.4).
//   3. `onSemanticError` fires exactly once iff semantic was attempted, the
//      query reached the embed call (a blank query short-circuits before it),
//      AND the model threw; it never fires on the "semantic returned empty"
//      path (Req 7.4).
//   4. `hasProjectMaterial()` equals the OR of the two tiers' own material flags
//      and never throws (Req 7 emptiness semantics).
//
// A FRESH in-memory database is opened per case and closed in a `finally`, so
// cases never leak into each other. The `forAll` block is async: kiri_check
// 1.3.1 declares the block as `FutureOr<void> Function(T)` and awaits it
// internally (see the sibling data-layer property tests), so repository/
// retriever calls are awaited directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:kiri_check/kiri_check.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spwrite/data/ai/chunk_embedding_repository.dart';
import 'package:spwrite/data/ai/chunker.dart';
import 'package:spwrite/data/ai/composite_context_retriever.dart';
import 'package:spwrite/data/ai/keyword_context_retriever.dart';
import 'package:spwrite/data/ai/semantic_context_retriever.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/domain/ai/context_retriever.dart';
import 'package:spwrite/domain/ai/embedding_model.dart';
import 'package:spwrite/domain/character.dart';
import 'package:spwrite/domain/character_repository.dart';
import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';
import 'package:spwrite/domain/project.dart';

/// The fixed embedding dimension used by the fake model and stored rows.
const int _dim = 16;

/// The fake model id tagged onto stored rows and reported by the fake model, so
/// no row ever looks stale (this property is about the fallback paths, not the
/// stale-index path — that is Property 10 / task 10.2).
const String _modelId = 'fake-embed-v1';

/// The project every case operates on. A single project is enough: the property
/// is about fallback behaviour, not cross-project scoping (Property 3).
const String _projectId = 'p0';

/// A thrown-error sentinel so the test can assert `onSemanticError` receives the
/// exact object the model threw.
class _EmbedFailure implements Exception {
  const _EmbedFailure();
  @override
  String toString() => 'embed failed (simulated)';
}

/// A deterministic, offline [EmbeddingModel]. When [shouldThrow] is true, its
/// [embed] throws a [_EmbedFailure] to simulate a query-time semantic failure
/// (model load / embed error, Req 7.4); otherwise it maps text to a fixed-length
/// vector by hashing whitespace-delimited tokens into buckets, so the same text
/// always yields the same vector with no real model or network.
class _FakeEmbeddingModel implements EmbeddingModel {
  _FakeEmbeddingModel({this.shouldThrow = false});

  /// Whether [embed]/[embedBatch] throw, simulating a query-time failure.
  final bool shouldThrow;

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
    if (shouldThrow) throw const _EmbedFailure();
    final List<double> v = List<double>.filled(_dim, 0.0);
    final List<String> tokens = text
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((String t) => t.isNotEmpty)
        .toList();
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
    if (shouldThrow) throw const _EmbedFailure();
    final List<List<double>> out = <List<double>>[];
    for (final String t in texts) {
      out.add(await embed(t));
    }
    return out;
  }
}

/// An in-memory [DocumentRepository] returning a fixed set of documents for the
/// scoped project. Only [getByProject] is exercised by [KeywordContextRetriever];
/// the rest are unused in this test and throw if ever called.
class _FakeDocumentRepository implements DocumentRepository {
  _FakeDocumentRepository(this._docs);

  final List<Document> _docs;

  @override
  Future<List<Document>> getByProject(String projectId) async =>
      _docs.where((Document d) => d.projectId == projectId).toList();

  @override
  Future<List<Document>> getByContainer(String projectId, String? folderId) =>
      throw UnimplementedError();

  @override
  Future<Document?> getById(String id) => throw UnimplementedError();

  @override
  Future<Document> create(Document doc) => throw UnimplementedError();

  @override
  Future<void> update(Document doc) => throw UnimplementedError();

  @override
  Future<void> updatePositions(List<Document> documents) =>
      throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();
}

/// An in-memory [CharacterRepository] returning a fixed set of characters for
/// the scoped project. Only [getAllForProject] is exercised by the keyword
/// retriever; the rest throw if called.
class _FakeCharacterRepository implements CharacterRepository {
  _FakeCharacterRepository(this._characters);

  final List<Character> _characters;

  @override
  Future<List<Character>> getAllForProject(String projectId) async =>
      _characters.where((Character c) => c.projectId == projectId).toList();

  @override
  Future<Character?> getById(String id) => throw UnimplementedError();

  @override
  Future<Character> create(Character character) => throw UnimplementedError();

  @override
  Future<void> update(Character character) => throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();
}

/// How many chunk vectors the semantic index holds for a case.
enum IndexState {
  /// No stored vectors — semantic tier is never attempted (Req 7.1/7.2).
  empty,

  /// A single stored vector — a "partial"/still-building index that the
  /// composite still treats as available (Req 7.2).
  partial,

  /// Several stored vectors — a fully present index (Req 7.2).
  present,
}

/// One generated availability scenario across the three named axes plus whether
/// the keyword tier has any material and which query text is used.
typedef Scenario = ({
  bool embeddingReady,
  IndexState indexState,
  bool semanticThrows,
  bool keywordMaterial,
  int querySelector,
});

/// Query pool: some share tokens with the seeded material (to produce matches),
/// some are unrelated, and one is blank (early-return path in both tiers).
const List<String> _queryPool = <String>[
  'dragon gate dawn',
  'harbor rain autumn',
  'promise orchard council',
  'completely unrelated query terms zzz',
  '   ', // whitespace-only
];

/// The document bodies seeded when a case has keyword material. Chosen to share
/// tokens with several queries so the keyword tier returns non-empty results on
/// the fallback path.
const List<String> _docBodies = <String>[
  'the dragon guards the northern gate at dawn near the harbor',
  'she remembered the promise made in the orchard before the council met',
];

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Arbitrary<Scenario> scenario() => combine5(
        boolean(),
        integer(min: 0, max: IndexState.values.length - 1),
        boolean(),
        boolean(),
        integer(min: 0, max: 1000),
      ).map(
        (rec) => (
          embeddingReady: rec.$1,
          indexState: IndexState.values[rec.$2],
          semanticThrows: rec.$3,
          keywordMaterial: rec.$4,
          querySelector: rec.$5,
        ),
      );

  property(
    'Property 9: fallback preserves availability — every {ready?, index?, '
    'throws?} combination returns a well-formed list without throwing',
    () {
      forAll(
        scenario(),
        (Scenario s) async {
          final Database db = await DatabaseProvider.openAppDatabase(
            overridePath: inMemoryDatabasePath,
          );
          try {
            // Seed the parent project row so the ai_chunk_embeddings FK holds
            // (the FFI factory enables PRAGMA foreign_keys = ON).
            await db.insert(
              DatabaseProvider.projectsTable,
              Project.create(
                id: _projectId,
                name: 'Project 0',
                now: DateTime.utc(2024, 1, 1),
              ).toRow(),
            );

            final ChunkEmbeddingRepository embeddings =
                ChunkEmbeddingRepository(db);

            // A model that never throws is used at *index time* to produce the
            // stored vectors; the retriever gets a model whose throwing depends
            // on the scenario, so an index can be present even when the query
            // embed throws.
            final _FakeEmbeddingModel indexModel = _FakeEmbeddingModel();
            final int vectorCount = switch (s.indexState) {
              IndexState.empty => 0,
              IndexState.partial => 1,
              IndexState.present => 4,
            };
            if (vectorCount > 0) {
              final List<EmbeddedChunk> embedded = <EmbeddedChunk>[];
              for (int i = 0; i < vectorCount; i++) {
                const String sourceId = '$_projectId-src';
                final String text = _docBodies[i % _docBodies.length];
                final SourceChunk chunk = SourceChunk(
                  id: DocumentChunker.chunkId(sourceId, i),
                  sourceId: sourceId,
                  sourceType: ChunkSourceType.document,
                  sourceTitle: 'Seed source',
                  chunkIndex: i,
                  text: text,
                  contentHash: DocumentChunker.contentHashOf('$text#$i'),
                );
                embedded.add(EmbeddedChunk(
                  chunk: chunk,
                  vector: await indexModel.embed(text),
                ));
              }
              await embeddings.upsertChunks(
                _projectId,
                embedded,
                modelId: indexModel.modelId,
                dim: indexModel.dimension,
              );
            }

            final SemanticContextRetriever semantic =
                SemanticContextRetriever(
              embeddingModel:
                  _FakeEmbeddingModel(shouldThrow: s.semanticThrows),
              embeddings: embeddings,
              projectId: _projectId,
              // A low floor and generous topN so any usable semantic match
              // surfaces — the harshest availability condition.
              topN: 1000,
              minSimilarity: -1.0,
            );

            // Keyword tier over in-memory fakes. When the case has no keyword
            // material, both repos return empty, so the fallback is itself empty
            // (→ chat-only, Req 7.3).
            final List<Document> docs = s.keywordMaterial
                ? <Document>[
                    for (int i = 0; i < _docBodies.length; i++)
                      Document(
                        id: 'doc$i',
                        title: 'Doc $i',
                        content: _docBodies[i],
                        projectId: _projectId,
                        createdAt: DateTime.utc(2024, 1, 1),
                        modifiedAt: DateTime.utc(2024, 1, 1),
                      ),
                  ]
                : const <Document>[];
            final KeywordContextRetriever keyword = KeywordContextRetriever(
              documentRepository: _FakeDocumentRepository(docs),
              characterRepository:
                  _FakeCharacterRepository(const <Character>[]),
              projectId: _projectId,
            );

            // Observe swallowed semantic errors.
            int semanticErrors = 0;
            Object? lastError;
            final CompositeContextRetriever composite =
                CompositeContextRetriever(
              semantic: semantic,
              keyword: keyword,
              isSemanticReady: () => s.embeddingReady,
              onSemanticError: (Object e) {
                semanticErrors++;
                lastError = e;
              },
            );

            final String query =
                _queryPool[s.querySelector % _queryPool.length];

            // (1) retrieve must complete without throwing and return a
            // well-formed list (Req 7).
            final List<RetrievedPassage> result =
                await composite.retrieve(query);
            expect(result, isNotNull);
            for (final RetrievedPassage p in result) {
              expect(p.text, isNotNull);
              expect(p.sourceId, isNotNull);
              expect(p.sourceTitle, isNotNull);
              expect(p.score, isA<double>());
            }

            // Ground truth about whether the semantic tier is even attempted:
            // ready gate AND the index holds ≥1 vector.
            final bool semanticAttempted =
                s.embeddingReady && vectorCount > 0;

            // A blank query short-circuits inside the semantic retriever *before*
            // it embeds (query.trim().isEmpty → []), so a throwing model never
            // actually throws and the composite simply degrades to keyword. Only
            // a query with usable text reaches the embed call that can throw.
            final bool queryReachesEmbed = query.trim().isNotEmpty;

            // The keyword tier's own result for this query — what the fallback
            // must surface whenever semantic does not win.
            final KeywordContextRetriever keywordProbe =
                KeywordContextRetriever(
              documentRepository: _FakeDocumentRepository(docs),
              characterRepository:
                  _FakeCharacterRepository(const <Character>[]),
              projectId: _projectId,
            );
            final List<RetrievedPassage> keywordResult =
                await keywordProbe.retrieve(query);

            // (3) onSemanticError fires exactly once iff semantic was attempted,
            // the query reaches the embed call, and the model threw; never on the
            // empty-semantic path or the blank-query short-circuit (Req 7.4).
            final bool expectSemanticError =
                semanticAttempted && queryReachesEmbed && s.semanticThrows;
            if (expectSemanticError) {
              expect(semanticErrors, 1,
                  reason: 'a thrown semantic query must be reported once');
              expect(lastError, isA<_EmbedFailure>());
            } else {
              expect(semanticErrors, 0,
                  reason: 'onSemanticError must not fire when semantic was not '
                      'attempted, short-circuited on a blank query, or did not '
                      'throw');
            }

            // (2) When semantic is not attempted, or it threw, the composite
            // must surface the keyword tier's result verbatim (Req 7.1, 7.2,
            // 7.4). When semantic was attempted and did NOT throw, it may return
            // its own (non-empty) result or, on an empty semantic result, the
            // keyword result — in either case the result stays well-formed and
            // never-throwing, already asserted in (1).
            if (!semanticAttempted || s.semanticThrows) {
              expect(
                _passageKeys(result),
                _passageKeys(keywordResult),
                reason: 'fallback must surface the keyword result when semantic '
                    'is unavailable or throws',
              );
            }

            // (4) hasProjectMaterial is the OR of the two tiers and never throws
            // (Req 7 emptiness semantics).
            final bool expectedMaterial =
                vectorCount > 0 || keywordResultHasMaterial(docs);
            expect(await composite.hasProjectMaterial(), expectedMaterial);
          } finally {
            await db.close();
          }
        },
        maxExamples: 100,
      );
    },
  );
}

/// Whether the keyword tier has any indexable material for the seeded [docs]
/// (the only keyword source in this test; characters are always empty here).
bool keywordResultHasMaterial(List<Document> docs) =>
    docs.any((Document d) => d.content.trim().isNotEmpty);

/// A stable projection of a passage list to comparable keys (sourceId +
/// chunkIndex proxy via text), so two results can be compared for equality
/// without depending on floating-point scores.
List<String> _passageKeys(List<RetrievedPassage> passages) =>
    passages.map((RetrievedPassage p) => '${p.sourceId}|${p.text}').toList();
