// Property test for ProjectIndexer incremental reindex (task 12.3).
//
// Feature: ai_feature_3.6 — on-device semantic retrieval (RAG).
//
// Property 7: Incremental reindex touches only changed chunks. For any edit to
// a source, the chunks whose `content_hash` is unchanged are never re-embedded;
// only new/changed chunks are embedded and only vanished chunks are deleted;
// and the resulting stored set equals a full reindex of the new content.
//
// **Validates: Requirements 4.2, 4.3, 4.4**
//
// Strategy: build a document out of several clearly-separated paragraphs (blank
// lines between them) so the pure `DocumentChunker` slices it into a small
// standalone title chunk plus one content chunk per paragraph — a
// deterministic, easy-to-reason-about chunk set whose `content_hash`es change
// one-for-one with the paragraph text. We then:
//
//   1. Index the initial document through the real `ProjectIndexer` over a real
//      `ChunkEmbeddingRepository` backed by a FRESH in-memory SQLite database,
//      counting every chunk the (fake) `EmbeddingModel` embeds.
//   2. Generate an edit — a per-paragraph decision to keep / change / drop a
//      trailing run of paragraphs, plus optionally a title rename — and save the
//      edited document through `onDocumentSaved`.
//   3. Compute, purely from the two chunk sets (old vs new, produced by the same
//      chunker the indexer uses), the ground-truth set of chunks that should be
//      (re-)embedded: those whose `(chunkIndex → content_hash)` is new or
//      differs from what was stored. Every other chunk (same index + same hash)
//      must be left untouched, and every stored index the new chunking no longer
//      produces must be deleted.
//
// Assertions after the incremental save:
//   * the embed counter advanced by *exactly* the number of changed/new chunks
//     (unchanged chunks were never re-embedded) — the core of Property 7;
//   * the stored rows equal a full reindex of the edited content: same set of
//     chunk ids, same per-chunk `content_hash`es, same `text` (Req 4.2, 4.4);
//   * vanished chunk indices left no stale rows behind (Req 4.4).
//
// The embedding *values* are irrelevant to this property — only *which* chunks
// were embedded matters — so the fake model returns a cheap deterministic
// vector and simply records how many chunk texts it was asked to embed. A FRESH
// in-memory database is opened per case and closed in a `finally`, so cases
// never leak into each other. The `forAll` block is async: kiri_check 1.3.1
// declares the block as `FutureOr<void> Function(T)` and awaits it internally
// (see the sibling data-layer property tests), so repository/indexer calls are
// awaited directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:kiri_check/kiri_check.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spwrite/data/ai/chunk_embedding_repository.dart';
import 'package:spwrite/data/ai/chunker.dart';
import 'package:spwrite/data/ai/project_indexer.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/domain/ai/embedding_model.dart';
import 'package:spwrite/domain/character.dart';
import 'package:spwrite/domain/character_repository.dart';
import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';
import 'package:spwrite/domain/project.dart';

/// The fixed embedding dimension used by the fake model and stored rows.
const int _dim = 8;

/// The fake model id tagged onto stored rows and reported by the fake model.
const String _modelId = 'fake-embed-v1';

/// The project every case operates on. A single project suffices: this property
/// is about incremental diffing within a source, not cross-project scoping
/// (that is Property 3 / task 7.2).
const String _projectId = 'p0';

/// The document that gets edited across the case.
const String _docId = 'doc-0';

/// A counting, deterministic, offline [EmbeddingModel]. It records the total
/// number of chunk texts it was asked to embed via [embedBatch]/[embed] in
/// [embedCount], so a test can assert *how many* chunks were (re-)embedded. The
/// vector it returns is a cheap deterministic function of the text (irrelevant
/// to this property — only the count matters), so no real model or network is
/// involved.
class _CountingEmbeddingModel implements EmbeddingModel {
  /// Total number of texts embedded across all [embed]/[embedBatch] calls.
  int embedCount = 0;

  /// Number of times [load] was invoked (should be at most once — the indexer
  /// loads lazily and only on first embed).
  int loadCount = 0;

  @override
  int get dimension => _dim;

  @override
  String get modelId => _modelId;

  @override
  Future<void> load() async {
    loadCount++;
  }

  @override
  Future<void> dispose() async {}

  /// Maps [text] to a fixed-length vector by hashing its characters into
  /// buckets — deterministic and non-zero so the repository can L2-normalize it.
  List<double> _vectorFor(String text) {
    final List<double> v = List<double>.filled(_dim, 0.0);
    for (int i = 0; i < text.length; i++) {
      v[text.codeUnitAt(i) % _dim] += 1.0;
    }
    // Guard against an all-zero vector (e.g. empty text) so normalization is
    // well-defined; a lone chunk is never empty here but be safe.
    if (v.every((double x) => x == 0.0)) v[0] = 1.0;
    return v;
  }

  @override
  Future<List<double>> embed(String text) async {
    embedCount++;
    return _vectorFor(text);
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    embedCount += texts.length;
    return <List<double>>[for (final String t in texts) _vectorFor(t)];
  }
}

/// A single-project, single-document in-memory [DocumentRepository]. Only
/// [getByProject] is exercised by [ProjectIndexer.reindexProject]; the
/// incremental path (`onDocumentSaved`) takes the document directly, so the
/// other members throw if ever called.
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

/// A character repository with no characters — this property exercises a
/// document edit only, so the character path is empty.
class _EmptyCharacterRepository implements CharacterRepository {
  const _EmptyCharacterRepository();

  @override
  Future<List<Character>> getAllForProject(String projectId) async =>
      const <Character>[];

  @override
  Future<Character?> getById(String id) => throw UnimplementedError();

  @override
  Future<Character> create(Character character) => throw UnimplementedError();

  @override
  Future<void> update(Character character) => throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();
}

/// What happens to a paragraph across the edit.
enum _ParaEdit {
  /// Left exactly as-is (its content hash is unchanged → must NOT be re-embedded).
  keep,

  /// Text mutated (its content hash changes → must be re-embedded).
  change,
}

/// One generated edit scenario: how many paragraphs the initial document has,
/// what happens to each of them, how many brand-new paragraphs are appended,
/// how many trailing paragraphs are dropped, and whether the title is renamed.
typedef Scenario = ({
  List<_ParaEdit> paraEdits,
  int appended,
  int dropTrailing,
  bool renameTitle,
});

/// A distinctive, well-separated paragraph body for paragraph [n], long enough
/// that the chunker keeps each paragraph as its own content chunk (each is well
/// under the ~800-char budget yet distinct so hashes differ per paragraph).
String _paragraph(int n) =>
    'Paragraph number $n. It carries a distinctive sentence about topic $n so '
    'that its content hash is unique and independent of the other paragraphs '
    'in this document body.';

/// Builds a document body by joining [paragraphs] with blank lines, so the
/// chunker breaks it into one content chunk per paragraph.
String _bodyOf(List<String> paragraphs) => paragraphs.join('\n\n');

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const DocumentChunker chunker = DocumentChunker();

  /// Seeds the parent project row so the ai_chunk_embeddings FK holds (the FFI
  /// factory enables PRAGMA foreign_keys = ON).
  Future<void> seedProject(Database db) async {
    await db.insert(
      DatabaseProvider.projectsTable,
      Project.create(
        id: _projectId,
        name: 'Project 0',
        now: DateTime.utc(2024, 1, 1),
      ).toRow(),
    );
  }

  /// The set of chunk ids the indexer should have (re-)embedded when moving from
  /// [oldChunks] to [newChunks]: any new chunk whose `(chunkIndex → hash)` is
  /// new or differs from the stored hash at the same index.
  Set<String> changedChunkIds(
    List<SourceChunk> oldChunks,
    List<SourceChunk> newChunks,
  ) {
    final Map<int, String> oldHashByIndex = <int, String>{
      for (final SourceChunk c in oldChunks) c.chunkIndex: c.contentHash,
    };
    return <String>{
      for (final SourceChunk c in newChunks)
        if (oldHashByIndex[c.chunkIndex] != c.contentHash) c.id,
    };
  }

  Arbitrary<Scenario> scenario() => combine4(
        // 1..5 paragraphs, each kept or changed.
        list(
          integer(min: 0, max: 1).map((int i) => _ParaEdit.values[i]),
          minLength: 1,
          maxLength: 5,
        ),
        integer(min: 0, max: 3), // paragraphs appended (all new chunks)
        integer(min: 0, max: 3), // trailing paragraphs dropped (vanished chunks)
        boolean(), // rename the title (re-embeds only the title chunk)
      ).map(
        (rec) => (
          paraEdits: rec.$1,
          appended: rec.$2,
          dropTrailing: rec.$3,
          renameTitle: rec.$4,
        ),
      );

  property(
    'Property 7: incremental reindex embeds only changed/new chunks, deletes '
    'only vanished chunks, and converges to a full reindex of the new content',
    () {
      forAll(
        scenario(),
        (Scenario s) async {
          final Database db = await DatabaseProvider.openAppDatabase(
            overridePath: inMemoryDatabasePath,
          );
          try {
            await seedProject(db);
            final ChunkEmbeddingRepository embeddings =
                ChunkEmbeddingRepository(db);
            final _CountingEmbeddingModel model = _CountingEmbeddingModel();

            final _FakeDocumentRepository documents =
                _FakeDocumentRepository(<Document>[]);
            final ProjectIndexer indexer = ProjectIndexer(
              embeddingModel: model,
              embeddings: embeddings,
              documents: documents,
              characters: const _EmptyCharacterRepository(),
              chunker: chunker,
            );

            // --- Initial document: one paragraph per paraEdit entry. ---
            final int initialCount = s.paraEdits.length;
            final List<String> initialParas = <String>[
              for (int i = 0; i < initialCount; i++) _paragraph(i),
            ];
            const String initialTitle = 'Original Title';
            final Document initial = Document(
              id: _docId,
              title: initialTitle,
              content: _bodyOf(initialParas),
              projectId: _projectId,
              createdAt: DateTime.utc(2024, 1, 1),
              modifiedAt: DateTime.utc(2024, 1, 1),
            );

            final List<SourceChunk> oldChunks =
                chunker.chunkDocument(initial);

            // Initial index builds every chunk from scratch, so the embed count
            // must equal the number of chunks the chunker produced.
            await indexer.onDocumentSaved(initial);
            expect(
              model.embedCount,
              oldChunks.length,
              reason: 'the initial index embeds every chunk exactly once',
            );
            expect(model.loadCount, 1,
                reason: 'the model is loaded once, lazily, on first embed');

            // --- Build the edited document from the scenario. ---
            // Start from the initial paragraphs, apply keep/change per index,
            // drop a trailing run, and append brand-new paragraphs.
            final List<String> editedParas = <String>[
              for (int i = 0; i < initialCount; i++)
                if (s.paraEdits[i] == _ParaEdit.change)
                  // A mutated body → a different content hash for that chunk.
                  '${_paragraph(i)} (revised edition with extra detail)'
                else
                  _paragraph(i),
            ];
            // Drop up to `dropTrailing` trailing paragraphs (never below zero).
            final int dropCount =
                s.dropTrailing.clamp(0, editedParas.length);
            editedParas.removeRange(
                editedParas.length - dropCount, editedParas.length);
            // Append brand-new paragraphs (indices beyond the original range so
            // their text — and hashes — are new).
            for (int j = 0; j < s.appended; j++) {
              editedParas.add(_paragraph(1000 + j));
            }

            final Document edited = initial.copyWith(
              title: s.renameTitle ? 'Renamed Title' : initialTitle,
              content: _bodyOf(editedParas),
              modifiedAt: DateTime.utc(2024, 1, 2),
            );

            final List<SourceChunk> newChunks = chunker.chunkDocument(edited);

            // Ground truth: exactly which chunks must be (re-)embedded.
            final Set<String> mustEmbed = changedChunkIds(oldChunks, newChunks);

            // --- Incremental save. ---
            final int embedsBefore = model.embedCount;
            await indexer.onDocumentSaved(edited);
            final int incrementalEmbeds = model.embedCount - embedsBefore;

            // (1) Core of Property 7: only changed/new chunks were embedded.
            // Unchanged chunks (same index + same hash) were left untouched.
            expect(
              incrementalEmbeds,
              mustEmbed.length,
              reason: 'the incremental save must embed only the changed/new '
                  'chunks (${mustEmbed.length}), never the unchanged ones',
            );
            // The model is loaded once for the whole indexer lifetime.
            expect(model.loadCount, 1);

            // (2) The stored set equals a full reindex of the edited content:
            // exactly the new chunk ids, with matching content hashes and text.
            final List<StoredChunkHash> storedHashes =
                await embeddings.readStoredHashesForSource(_projectId, _docId);
            final Map<int, String> storedHashByIndex = <int, String>{
              for (final StoredChunkHash h in storedHashes)
                h.chunkIndex: h.contentHash,
            };
            final Map<int, String> newHashByIndex = <int, String>{
              for (final SourceChunk c in newChunks) c.chunkIndex: c.contentHash,
            };
            expect(
              storedHashByIndex,
              newHashByIndex,
              reason: 'stored per-chunk hashes must match a full reindex of the '
                  'edited content (converged set)',
            );

            // (3) Vanished chunk indices left no stale rows behind (Req 4.4):
            // every stored id belongs to the new chunk set, and the row count
            // equals the new chunk count.
            final Set<String> storedIds =
                storedHashes.map((StoredChunkHash h) => h.id).toSet();
            final Set<String> newIds =
                newChunks.map((SourceChunk c) => c.id).toSet();
            expect(storedIds, newIds,
                reason: 'no vanished chunk may remain and no new chunk may be '
                    'missing after the incremental save');
            expect(
              await embeddings.countForProject(_projectId),
              newChunks.length,
              reason: 'the stored row count equals the edited chunk count',
            );
          } finally {
            await db.close();
          }
        },
        maxExamples: 100,
      );
    },
  );
}
