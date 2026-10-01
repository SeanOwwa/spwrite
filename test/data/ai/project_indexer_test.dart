// Unit tests for ProjectIndexer add/remove/rename and resume (task 12.5).
//
// Feature: ai_feature_3.6 — on-device semantic retrieval (RAG).
//
// Example-based coverage of the incremental write side of the semantic path
// (design §"ProjectIndexer", Req 4.3, 4.4, 4.5, 9.3):
//
//   * onSourceAdded  — a newly added source embeds *all* of its chunks and its
//     rows become readable through the vector index (Req 4.3).
//   * onSourceRemoved — deletes every stored row of the source *and* clears its
//     `ai_index_state` resume marker so a stale marker can never mask a re-add
//     (Req 4.4).
//   * onDocumentRenamed — refreshes the stored `source_title` on *every* row for
//     citation while re-embedding only the small title chunk (index 0); the body
//     chunks keep their text/hash and are never re-embedded (Req 4.5).
//   * resume — a source recorded `complete` at its current `source_hash` is
//     *skipped* by `reindexProject` (no re-embed), but is re-processed once its
//     content (and therefore its source hash) changes (Req 9.3).
//
// The tests use a real [ChunkEmbeddingRepository] and a real
// [SqliteIndexStateStore] over a fresh in-memory SQLite database (the FFI
// factory, matching the sibling data-layer tests), a *counting* fake
// [EmbeddingModel] that records exactly which texts it embedded (so
// re-embedding can be asserted precisely), and lightweight in-memory fake
// document/character repositories (mirroring
// composite_context_retriever_fallback_property_test.dart) so the indexer's
// read side is exercised without a heavier persistence layer.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spwrite/data/ai/chunk_embedding_repository.dart';
import 'package:spwrite/data/ai/chunker.dart';
import 'package:spwrite/data/ai/index_state_store.dart';
import 'package:spwrite/data/ai/project_indexer.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/domain/ai/embedding_model.dart';
import 'package:spwrite/domain/character.dart';
import 'package:spwrite/domain/character_repository.dart';
import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';
import 'package:spwrite/domain/project.dart';

/// The fixed embedding dimension the fake model and stored rows use.
const int _dim = 8;

/// The fake embedding model id tagged onto stored rows.
const String _modelId = 'fake-embed-v1';

/// A deterministic, offline [EmbeddingModel] that records every text it embeds
/// (in call order) and counts `load()` calls, so a test can assert *exactly*
/// which chunks were (re-)embedded and that the model is loaded lazily once.
///
/// The vector is a deterministic function of the text (token-bucket hashing),
/// so the same text always yields the same vector — an incremental re-index of
/// unchanged text would produce identical stored bytes.
class _CountingEmbeddingModel implements EmbeddingModel {
  /// Every text passed to [embed]/[embedBatch], in the order embedded.
  final List<String> embeddedTexts = <String>[];

  /// How many times [load] has been called.
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

  List<double> _vectorFor(String text) {
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
  Future<List<double>> embed(String text) async {
    embeddedTexts.add(text);
    return _vectorFor(text);
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

/// An in-memory [DocumentRepository]. Only [getByProject] is exercised by
/// [ProjectIndexer.reindexProject]; the rest throw if ever called.
class _FakeDocumentRepository implements DocumentRepository {
  _FakeDocumentRepository(this.docs);

  /// Mutable so a test can change content between reindex runs (the resume
  /// path re-reads through this repository).
  List<Document> docs;

  @override
  Future<List<Document>> getByProject(String projectId) async =>
      docs.where((Document d) => d.projectId == projectId).toList();

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

/// An in-memory [CharacterRepository]. Only [getAllForProject] is exercised;
/// the rest throw if called.
class _FakeCharacterRepository implements CharacterRepository {
  _FakeCharacterRepository(this.characters);

  List<Character> characters;

  @override
  Future<List<Character>> getAllForProject(String projectId) async =>
      characters.where((Character c) => c.projectId == projectId).toList();

  @override
  Future<Character?> getById(String id) => throw UnimplementedError();

  @override
  Future<Character> create(Character character) => throw UnimplementedError();

  @override
  Future<void> update(Character character) => throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const String projectId = 'p1';

  late Database db;
  late ChunkEmbeddingRepository embeddings;
  late SqliteIndexStateStore stateStore;
  late _CountingEmbeddingModel model;

  setUp(() async {
    db = await DatabaseProvider.openAppDatabase(
      overridePath: inMemoryDatabasePath,
    );
    // Seed the parent project row so the ai_chunk_embeddings FK holds (the FFI
    // factory enables PRAGMA foreign_keys = ON).
    await db.insert(
      DatabaseProvider.projectsTable,
      Project.create(
        id: projectId,
        name: 'Project 1',
        now: DateTime.utc(2024, 1, 1),
      ).toRow(),
    );
    embeddings = ChunkEmbeddingRepository(db);
    stateStore = SqliteIndexStateStore(db);
    model = _CountingEmbeddingModel();
  });

  tearDown(() async {
    await db.close();
  });

  /// Drains a paged scan into a single flat list preserving batch order.
  Future<List<StoredChunkEmbedding>> scanAll() async {
    final List<StoredChunkEmbedding> all = <StoredChunkEmbedding>[];
    await for (final List<StoredChunkEmbedding> batch
        in embeddings.scanProject(projectId)) {
      all.addAll(batch);
    }
    return all;
  }

  /// The stored rows of [sourceId], ordered by chunk index.
  Future<List<StoredChunkEmbedding>> rowsFor(String sourceId) async {
    final List<StoredChunkEmbedding> rows = (await scanAll())
        .where((StoredChunkEmbedding s) => s.sourceId == sourceId)
        .toList()
      ..sort((StoredChunkEmbedding a, StoredChunkEmbedding b) =>
          a.chunkIndex.compareTo(b.chunkIndex));
    return rows;
  }

  Document buildDoc(
    String id, {
    required String title,
    required String content,
  }) {
    return Document(
      id: id,
      title: title,
      content: content,
      projectId: projectId,
      createdAt: DateTime.utc(2024, 1, 1),
      modifiedAt: DateTime.utc(2024, 1, 2),
    );
  }

  Character buildCharacter(
    String id, {
    required String name,
    required String role,
    required String notes,
  }) {
    return Character(
      id: id,
      projectId: projectId,
      name: name,
      role: role,
      notes: notes,
      image: null,
      createdAt: DateTime.utc(2024, 1, 1),
      modifiedAt: DateTime.utc(2024, 1, 2),
    );
  }

  ProjectIndexer buildIndexer({
    List<Document> docs = const <Document>[],
    List<Character> characters = const <Character>[],
  }) {
    return ProjectIndexer(
      embeddingModel: model,
      embeddings: embeddings,
      documents: _FakeDocumentRepository(List<Document>.of(docs)),
      characters: _FakeCharacterRepository(List<Character>.of(characters)),
      indexState: stateStore,
    );
  }

  group('onSourceAdded', () {
    test('a new document embeds all of its chunks and stores every row',
        () async {
      final Document doc = buildDoc(
        'doc-1',
        title: 'The Northern Gate',
        content: 'The dragon guards the gate at dawn.\n\n'
            'Below the harbor the ships wait for the tide to turn.',
      );
      // Ground truth: what the chunker produces for this source.
      final List<SourceChunk> expected =
          const DocumentChunker().chunkDocument(doc);
      expect(expected, isNotEmpty);

      final ProjectIndexer indexer = buildIndexer();
      await indexer.onSourceAdded(doc);

      // Every produced chunk was embedded exactly once (a new source has no
      // stored chunks, so all are new — Req 4.3).
      expect(model.embeddedTexts,
          expected.map((SourceChunk c) => c.text).toList());

      // ...and every chunk is now a stored, readable row.
      final List<StoredChunkEmbedding> rows = await rowsFor('doc-1');
      expect(rows, hasLength(expected.length));
      expect(rows.map((StoredChunkEmbedding s) => s.text),
          expected.map((SourceChunk c) => c.text));
      expect(await embeddings.countForProject(projectId), expected.length);

      // The model was loaded lazily, exactly once.
      expect(model.loadCount, 1);
    });

    test('a new character embeds its compact chunk', () async {
      final Character character = buildCharacter(
        'char-1',
        name: 'Mara',
        role: 'Captain',
        notes: 'Leads the harbor guard; distrusts the council.',
      );
      final List<SourceChunk> expected =
          const DocumentChunker().chunkCharacter(character);
      expect(expected, isNotEmpty);

      final ProjectIndexer indexer = buildIndexer();
      await indexer.onSourceAdded(character);

      expect(model.embeddedTexts,
          expected.map((SourceChunk c) => c.text).toList());
      expect(await rowsFor('char-1'), hasLength(expected.length));
    });

    test('a non-document/character source is rejected', () async {
      final ProjectIndexer indexer = buildIndexer();
      await expectLater(
        indexer.onSourceAdded(42),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('onSourceRemoved', () {
    test('deletes all rows of the source and clears its resume marker',
        () async {
      final Document doc = buildDoc(
        'doc-1',
        title: 'Chapter One',
        content: 'A long paragraph of prose about the orchard and the council.',
      );
      final Document other = buildDoc(
        'doc-2',
        title: 'Chapter Two',
        content: 'Different content entirely, about the sea.',
      );

      final ProjectIndexer indexer = buildIndexer();
      await indexer.onSourceAdded(doc);
      await indexer.onSourceAdded(other);

      final int docRows = (await rowsFor('doc-1')).length;
      expect(docRows, greaterThan(0));
      // The source was marked complete at its content hash.
      final String docHash = _docSourceHash(doc);
      expect(await stateStore.isComplete(projectId, 'doc-1', docHash), isTrue);

      await indexer.onSourceRemoved(projectId, 'doc-1');

      // Every row of doc-1 is gone; doc-2 is untouched.
      expect(await rowsFor('doc-1'), isEmpty);
      expect(await rowsFor('doc-2'), isNotEmpty);

      // The resume marker was cleared (isComplete false at the previous hash).
      expect(await stateStore.isComplete(projectId, 'doc-1', docHash), isFalse);
    });
  });

  group('onDocumentRenamed', () {
    test(
        'refreshes source_title on all rows and re-embeds only the title chunk',
        () async {
      final Document doc = buildDoc(
        'doc-1',
        title: 'Old Title',
        content: 'The dragon guards the gate at dawn.\n\n'
            'Below the harbor the ships wait for the tide to turn.\n\n'
            'The council met in secret before the storm arrived.',
      );

      final ProjectIndexer indexer = buildIndexer();
      await indexer.onSourceAdded(doc);

      // Baseline: the initial build. Chunk 0 is the title chunk; the rest are
      // body chunks. Capture the body chunk vectors so we can prove they are
      // not re-embedded (their stored bytes stay identical) after a rename.
      final List<StoredChunkEmbedding> before = await rowsFor('doc-1');
      expect(before.length, greaterThan(1),
          reason: 'need a title chunk plus at least one body chunk');
      expect(before.first.text, 'Old Title'); // title chunk at index 0
      expect(before.every((StoredChunkEmbedding s) => s.sourceTitle == 'Old Title'),
          isTrue);

      final Map<int, List<double>> bodyVectorsBefore = <int, List<double>>{
        for (final StoredChunkEmbedding s in before)
          if (s.chunkIndex != 0) s.chunkIndex: s.embedding,
      };

      model.embeddedTexts.clear();

      // Rename: same content, new title. The caller hands the already-renamed
      // document (Req 4.5).
      final Document renamed = doc.copyWith(title: 'New Title');
      await indexer.onDocumentRenamed(renamed);

      // Only the new title text was re-embedded — the body was left untouched.
      expect(model.embeddedTexts, <String>['New Title']);

      final List<StoredChunkEmbedding> after = await rowsFor('doc-1');
      // Same number of rows (no chunk added/removed by a pure rename).
      expect(after.length, before.length);

      // Every row now carries the new source_title for citation (Req 4.5).
      expect(
        after.every((StoredChunkEmbedding s) => s.sourceTitle == 'New Title'),
        isTrue,
      );

      // The title chunk's text changed to the new title...
      expect(after.first.chunkIndex, 0);
      expect(after.first.text, 'New Title');

      // ...while every body chunk's stored vector is byte-for-byte unchanged
      // (it was never re-embedded).
      for (final StoredChunkEmbedding s
          in after.where((StoredChunkEmbedding s) => s.chunkIndex != 0)) {
        expect(s.embedding, bodyVectorsBefore[s.chunkIndex]);
      }
    });
  });

  group('resume via SqliteIndexStateStore', () {
    test(
        'a source complete at its hash is skipped, but re-processed after its '
        'content changes', () async {
      final Document doc = buildDoc(
        'doc-1',
        title: 'Prologue',
        content: 'The first draft of the prologue before any edits.',
      );
      final _FakeDocumentRepository docRepo =
          _FakeDocumentRepository(<Document>[doc]);
      final ProjectIndexer indexer = ProjectIndexer(
        embeddingModel: model,
        embeddings: embeddings,
        documents: docRepo,
        characters: _FakeCharacterRepository(const <Character>[]),
        indexState: stateStore,
      );

      // First build: everything is embedded and the source is marked complete.
      await indexer.reindexProject(projectId);
      final int firstEmbedCount = model.embeddedTexts.length;
      expect(firstEmbedCount, greaterThan(0));
      expect(
        await stateStore.isComplete(projectId, 'doc-1', _docSourceHash(doc)),
        isTrue,
      );

      // Re-run over unchanged content: the source is already complete at this
      // hash, so reindex SKIPS it — no chunk is re-embedded (Req 9.3).
      model.embeddedTexts.clear();
      await indexer.reindexProject(projectId);
      expect(model.embeddedTexts, isEmpty,
          reason: 'a source complete at its current hash must be skipped');

      // Change the content: the source hash no longer matches the recorded
      // marker, so the resuming build re-processes it and re-embeds.
      final Document edited =
          doc.copyWith(content: 'A revised prologue with new sentences.');
      docRepo.docs = <Document>[edited];

      model.embeddedTexts.clear();
      await indexer.reindexProject(projectId);
      expect(model.embeddedTexts, isNotEmpty,
          reason: 'content change invalidates the resume marker → re-embed');
      // And the marker now tracks the new content hash.
      expect(
        await stateStore.isComplete(projectId, 'doc-1', _docSourceHash(edited)),
        isTrue,
      );
    });

    test(
        'a partial (interrupted) marker is not skipped — the build resumes it',
        () async {
      final Document doc = buildDoc(
        'doc-1',
        title: 'Interrupted',
        content: 'Content that was mid-build when the app closed.',
      );

      // Simulate an interrupted first-time build: the source was marked
      // `partial` at its current hash (embedding began but did not finish), and
      // no rows were stored.
      final String hash = _docSourceHash(doc);
      await stateStore.markSource(
        projectId,
        'doc-1',
        ChunkSourceType.document,
        sourceHash: hash,
        chunkCount: 0,
        status: IndexSourceStatus.partial,
      );
      expect(await stateStore.isComplete(projectId, 'doc-1', hash), isFalse);

      final ProjectIndexer indexer = buildIndexer(docs: <Document>[doc]);

      // Resume: a partial marker is not `complete`, so the source is processed
      // rather than skipped, and ends up fully indexed + complete (Req 9.3).
      await indexer.reindexProject(projectId);
      expect(model.embeddedTexts, isNotEmpty);
      expect(await rowsFor('doc-1'), isNotEmpty);
      expect(await stateStore.isComplete(projectId, 'doc-1', hash), isTrue);
    });
  });
}

/// Recomputes the per-source resume hash for [doc] the same way the indexer
/// does (sha256 over `title\u0000content`), so a test can assert against the
/// recorded `ai_index_state` marker without reaching into private helpers.
String _docSourceHash(Document doc) {
  // Mirrors ProjectIndexer._sourceHashForDocument.
  return sha256.convert(utf8.encode('${doc.title}\u0000${doc.content}')).toString();
}
