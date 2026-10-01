// Property test for ProjectIndexer idempotent reindex (task 12.4).
//
// Feature: ai_feature_3.6 — on-device semantic retrieval (RAG).
//
// Property 8: Reindex is idempotent and convergent. Running a full reindex
// twice over unchanged content produces the same stored rows (same ids, hashes,
// vectors) and performs no embedding work on the second pass.
//
// **Validates: Requirements 4.2**
//
// Strategy: generate a compact project — a set of documents (arbitrary
// title/body) and characters (arbitrary name/role/notes) — then drive a real
// `ProjectIndexer` over a real `ChunkEmbeddingRepository` backed by a FRESH
// in-memory SQLite database, with a *counting* deterministic fake
// `EmbeddingModel` and lightweight in-memory fake document/character
// repositories (mirroring the sibling data-layer property tests, e.g.
// composite_context_retriever_fallback_property_test.dart).
//
// The counting fake records how many chunk texts it embeds. We call
// `reindexProject` once to build the index, snapshot the embed count and the
// full stored row set, then call `reindexProject` a SECOND time over the
// unchanged sources and assert:
//   1. the second pass embeds NOTHING — every chunk's `content_hash` already
//      matches the stored hash, so the incremental diff finds nothing to
//      re-embed (Req 4.2: unchanged passages are never re-embedded); and
//   2. the stored state is byte-for-byte unchanged — the same set of row ids,
//      the same `content_hash` per row, and the same encoded embedding BLOB per
//      row (the index converged and did not drift).
//
// A deterministic fake model is essential: the same chunk text must embed to
// the same vector so "unchanged rows" is a meaningful assertion. The model
// hashes whitespace-delimited tokens into fixed-dim buckets (design §"Component
// tests with a fake EmbeddingModel"), so there is no real model and no network.
//
// A FRESH in-memory database is opened per case and closed in a `finally`, so
// cases never leak into each other. The `forAll` block is async: kiri_check
// 1.3.1 declares the block as `FutureOr<void> Function(T)` and awaits it
// internally (see the sibling data-layer property tests), so repository/indexer
// calls are awaited directly.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiri_check/kiri_check.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spwrite/data/ai/chunk_embedding_repository.dart';
import 'package:spwrite/data/ai/project_indexer.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/domain/ai/embedding_model.dart';
import 'package:spwrite/domain/character.dart';
import 'package:spwrite/domain/character_repository.dart';
import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';
import 'package:spwrite/domain/project.dart';

/// The fixed embedding dimension used by the fake model and stored rows.
const int _dim = 16;

/// The fake model id tagged onto stored rows and reported by the fake model.
const String _modelId = 'fake-embed-v1';

/// The project every case indexes. A single project is enough: this property is
/// about idempotence of a rebuild, not cross-project scoping (Property 3).
const String _projectId = 'p0';

/// A deterministic, offline [EmbeddingModel] that *counts* how many chunk texts
/// it embeds, so the test can assert the second reindex does no embedding work.
///
/// It maps text to a fixed-length vector by hashing its whitespace-delimited
/// tokens into buckets, so the same text always yields the same vector (design
/// §"Component tests with a fake EmbeddingModel") — which makes "the stored rows
/// are unchanged after a re-run" a meaningful, exact assertion. No real model
/// and no network are involved.
class _CountingFakeEmbeddingModel implements EmbeddingModel {
  /// Total number of texts embedded via [embed]/[embedBatch] over this model's
  /// lifetime. The indexer only embeds new/changed chunks, so on an idempotent
  /// re-run this must not advance.
  int embedCount = 0;

  /// Number of times [load] was invoked (should be at most once — the indexer
  /// loads lazily on first use).
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

  @override
  Future<List<double>> embed(String text) async {
    embedCount++;
    return _vectorFor(text);
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    final List<List<double>> out = <List<double>>[];
    for (final String t in texts) {
      embedCount++;
      out.add(_vectorFor(t));
    }
    return out;
  }

  /// A deterministic bag-of-words vector for [text]: the same text always maps
  /// to the same vector, so re-embedding identical content is a no-op change.
  static List<double> _vectorFor(String text) {
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
}

/// An in-memory [DocumentRepository] returning a fixed set of documents for the
/// scoped project. Only [getByProject] is exercised by [ProjectIndexer]; the
/// rest throw if ever called.
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
/// the scoped project. Only [getAllForProject] is exercised by the indexer; the
/// rest throw if called.
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

/// One generated project spec: how many documents and characters it has, plus
/// the raw text material each is built from. The counts are kept small so a
/// case runs fast while still spanning documents that produce multiple chunks
/// (long bodies) and characters with varied fields.
typedef ProjectSpec = ({
  List<({String title, String body})> docs,
  List<({String name, String role, String notes})> characters,
});

/// A pool of body texts of varying length: short bodies produce one content
/// chunk, the long one (well over `maxChunkChars = 800`) produces several, so
/// the property exercises multi-chunk sources too.
final List<String> _bodyPool = <String>[
  '',
  'A short single-paragraph body about the harbor at dawn.',
  'First paragraph about the northern gate.\n\n'
      'Second paragraph about the orchard and the council that met there.',
  // A long body (repeated sentence) that forces the chunker to emit several
  // ~800-char windows, so incremental idempotence is tested across many chunks.
  'The dragon guarded the northern gate at dawn near the harbor. ' * 40,
];

const List<String> _titlePool = <String>[
  '',
  'Chapter One',
  'The Orchard',
  'Notes on the Council',
];

const List<String> _rolePool = <String>['', 'Protagonist', 'Mentor'];

const List<String> _notesPool = <String>[
  '',
  'A brief note.',
  'She kept a promise made in the orchard before the council met at dawn.',
];

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  /// Generates a small project: 0..3 documents and 0..3 characters, each drawn
  /// from the pools above, so a case spans empty sources, single-chunk sources,
  /// and multi-chunk (long) documents.
  Arbitrary<ProjectSpec> projectSpec() {
    final Arbitrary<({String title, String body})> docArb = combine2(
      integer(min: 0, max: _titlePool.length - 1),
      integer(min: 0, max: _bodyPool.length - 1),
    ).map((rec) => (title: _titlePool[rec.$1], body: _bodyPool[rec.$2]));

    final Arbitrary<({String name, String role, String notes})> charArb =
        combine3(
      integer(min: 0, max: 5),
      integer(min: 0, max: _rolePool.length - 1),
      integer(min: 0, max: _notesPool.length - 1),
    ).map(
      (rec) => (
        name: rec.$1 == 0 ? '' : 'Character ${rec.$1}',
        role: _rolePool[rec.$2],
        notes: _notesPool[rec.$3],
      ),
    );

    return combine2(
      list(docArb, minLength: 0, maxLength: 3),
      list(charArb, minLength: 0, maxLength: 3),
    ).map((rec) => (docs: rec.$1, characters: rec.$2));
  }

  property(
    'Property 8: reindex is idempotent and convergent — a second reindex over '
    'unchanged content embeds nothing and leaves the stored rows identical',
    () {
      forAll(
        projectSpec(),
        (ProjectSpec spec) async {
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

            final DateTime ts = DateTime.utc(2024, 1, 1);
            final List<Document> docs = <Document>[
              for (int i = 0; i < spec.docs.length; i++)
                Document(
                  id: 'doc$i',
                  title: spec.docs[i].title,
                  content: spec.docs[i].body,
                  projectId: _projectId,
                  createdAt: ts,
                  modifiedAt: ts,
                ),
            ];
            final List<Character> characters = <Character>[
              for (int i = 0; i < spec.characters.length; i++)
                Character(
                  id: 'char$i',
                  projectId: _projectId,
                  name: spec.characters[i].name,
                  role: spec.characters[i].role,
                  notes: spec.characters[i].notes,
                  image: null,
                  createdAt: ts,
                  modifiedAt: ts,
                ),
            ];

            final ChunkEmbeddingRepository embeddings =
                ChunkEmbeddingRepository(db);
            final _CountingFakeEmbeddingModel model =
                _CountingFakeEmbeddingModel();
            final ProjectIndexer indexer = ProjectIndexer(
              embeddingModel: model,
              embeddings: embeddings,
              documents: _FakeDocumentRepository(docs),
              characters: _FakeCharacterRepository(characters),
            );

            // First reindex: build the whole index.
            await indexer.reindexProject(_projectId);

            final int embedsAfterFirst = model.embedCount;
            final Map<String, _RowSnapshot> stateAfterFirst =
                await _snapshotRows(db);

            // Sanity: the number of chunks embedded on the first pass equals the
            // number of stored rows (every stored row was embedded exactly once,
            // so the fake and the repository agree on the chunk count).
            expect(embedsAfterFirst, stateAfterFirst.length,
                reason: 'first build embeds exactly one vector per stored row');

            // Second reindex over the SAME, unchanged sources.
            await indexer.reindexProject(_projectId);

            // (1) The second pass must embed NOTHING: every chunk's content hash
            // already matches the stored hash, so the incremental diff finds no
            // new/changed chunk to re-embed (Req 4.2).
            expect(model.embedCount, embedsAfterFirst,
                reason: 'a reindex over unchanged content must re-embed nothing');

            // (2) The stored state must be byte-for-byte unchanged: same row ids,
            // same content hashes, same encoded embedding BLOBs (the index
            // converged and did not drift).
            final Map<String, _RowSnapshot> stateAfterSecond =
                await _snapshotRows(db);
            expect(stateAfterSecond.keys.toSet(), stateAfterFirst.keys.toSet(),
                reason: 'the set of stored row ids must be identical');
            for (final String id in stateAfterFirst.keys) {
              final _RowSnapshot before = stateAfterFirst[id]!;
              final _RowSnapshot after = stateAfterSecond[id]!;
              expect(after.contentHash, before.contentHash,
                  reason: 'row $id content_hash must be unchanged');
              expect(after.embedding, before.embedding,
                  reason: 'row $id embedding BLOB must be unchanged');
              expect(after.chunkIndex, before.chunkIndex,
                  reason: 'row $id chunk_index must be unchanged');
              expect(after.sourceId, before.sourceId,
                  reason: 'row $id source_id must be unchanged');
            }

            // The model is loaded at most once, lazily (unless there was nothing
            // to embed, in which case it is never loaded).
            expect(model.loadCount, lessThanOrEqualTo(1),
                reason: 'the embedding model is loaded at most once, lazily');
          } finally {
            await db.close();
          }
        },
        maxExamples: 60,
      );
    },
  );
}

/// A comparable snapshot of the identity/hash/vector of one stored row, so two
/// full-index states can be compared for exact equality.
class _RowSnapshot {
  const _RowSnapshot({
    required this.contentHash,
    required this.chunkIndex,
    required this.sourceId,
    required this.embedding,
  });

  final String contentHash;
  final int chunkIndex;
  final String sourceId;

  /// The raw stored Float32 embedding BLOB bytes; compared for exact equality so
  /// a re-embed (which would rewrite these bytes) would be detected.
  final List<int> embedding;
}

/// Reads every `ai_chunk_embeddings` row for the test project and projects it to
/// a comparable [_RowSnapshot] keyed by the stable chunk id.
Future<Map<String, _RowSnapshot>> _snapshotRows(Database db) async {
  final List<Map<String, Object?>> rows = await db.query(
    DatabaseProvider.aiChunkEmbeddingsTable,
    where: '${ChunkEmbeddingColumns.projectId} = ?',
    whereArgs: <Object?>[_projectId],
  );
  final Map<String, _RowSnapshot> out = <String, _RowSnapshot>{};
  for (final Map<String, Object?> row in rows) {
    final String id = row[ChunkEmbeddingColumns.id]! as String;
    final Object? blob = row[ChunkEmbeddingColumns.embedding];
    final List<int> bytes = blob is Uint8List
        ? List<int>.from(blob)
        : (blob as List).cast<int>();
    out[id] = _RowSnapshot(
      contentHash: row[ChunkEmbeddingColumns.contentHash]! as String,
      chunkIndex: (row[ChunkEmbeddingColumns.chunkIndex] as num).toInt(),
      sourceId: row[ChunkEmbeddingColumns.sourceId]! as String,
      embedding: bytes,
    );
  }
  return out;
}
