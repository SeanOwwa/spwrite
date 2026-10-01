// Tests for the 3.6 composition wiring (task 16.3): the change-observable
// repository decorators and the per-project IndexingBinding that keeps an
// IndexingState / ProjectIndexer in step with persisted saves.
//
// Validates: Requirements 4.3, 4.4, 4.5, 4.6, 9.2, 10.3
//
// Uses real SQLite repositories, a real ChunkEmbeddingRepository /
// SqliteIndexStateStore / ProjectIndexer / IndexingState over an in-memory
// database, and a deterministic offline EmbeddingModel. Only the model
// downloader is faked (presence only; no network).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spwrite/data/ai/chunk_embedding_repository.dart';
import 'package:spwrite/data/ai/index_state_store.dart';
import 'package:spwrite/data/ai/model_downloader.dart';
import 'package:spwrite/data/ai/project_indexer.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/data/observable_repositories.dart';
import 'package:spwrite/data/sqlite_character_repository.dart';
import 'package:spwrite/data/sqlite_document_repository.dart';
import 'package:spwrite/domain/ai/embedding_model.dart';
import 'package:spwrite/domain/ai/model_catalog.dart';
import 'package:spwrite/domain/character.dart';
import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/state/indexing_binding.dart';
import 'package:spwrite/state/indexing_state.dart';

const int _dim = 8;

/// Deterministic offline embedding model: bag-of-token hashing into [_dim]
/// buckets. Counts embedded texts so tests can assert whether work happened.
class _FakeEmbeddingModel implements EmbeddingModel {
  int embeddedCount = 0;

  @override
  int get dimension => _dim;

  @override
  String get modelId => 'fake-embed';

  @override
  Future<void> load() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<List<double>> embed(String text) async {
    embeddedCount++;
    final List<double> v = List<double>.filled(_dim, 0.0);
    v[text.hashCode.abs() % _dim] = 1.0;
    v[(text.length) % _dim] += 0.5;
    return v;
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async =>
      <List<double>>[for (final String t in texts) await embed(t)];
}

/// Downloader fake: only presence is used by the binding's start-up probe.
class _FakeDownloader extends ModelDownloader {
  _FakeDownloader({required this.present})
      : super(directoryResolver: _neverResolve);

  bool present;

  static Future<Directory> _neverResolve() async =>
      throw StateError('must not resolve directories');

  @override
  Future<bool> isModelPresent(ModelMetadata model) async => present;
}

/// A DocumentRepository whose writes always fail, to check that the
/// observable decorator only reports successful writes.
class _FailingDocumentRepository implements DocumentRepository {
  @override
  Future<Document> create(Document doc) async => throw StateError('boom');
  @override
  Future<void> update(Document doc) async => throw StateError('boom');
  @override
  Future<void> delete(String id) async => throw StateError('boom');
  @override
  Future<List<Document>> getByProject(String projectId) async => <Document>[];
  @override
  Future<List<Document>> getByContainer(
          String projectId, String? folderId) async =>
      <Document>[];
  @override
  Future<Document?> getById(String id) async => null;
  @override
  Future<void> updatePositions(List<Document> documents) async {}
}

/// Lets fire-and-forget background work (stream delivery, indexer awaits,
/// SQLite FFI round-trips) settle.
Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const String projectId = 'p1';
  const String otherProjectId = 'p2';

  late Database db;
  late ObservableDocumentRepository documents;
  late ObservableCharacterRepository characters;
  late ChunkEmbeddingRepository embeddings;
  late _FakeEmbeddingModel model;

  setUp(() async {
    db = await DatabaseProvider.openAppDatabase(
      overridePath: inMemoryDatabasePath,
    );
    for (final String id in <String>[projectId, otherProjectId]) {
      await db.insert(
        DatabaseProvider.projectsTable,
        Project.create(id: id, name: 'Project $id', now: DateTime.utc(2024))
            .toRow(),
      );
    }
    documents = ObservableDocumentRepository(SqliteDocumentRepository(db));
    characters = ObservableCharacterRepository(SqliteCharacterRepository(db));
    embeddings = ChunkEmbeddingRepository(db);
    model = _FakeEmbeddingModel();
  });

  tearDown(() async {
    await documents.close();
    await characters.close();
    await db.close();
  });

  Document doc(String id, {String project = projectId, String? title}) {
    final DateTime now = DateTime.utc(2024, 1, 1);
    return Document(
      id: id,
      title: title ?? 'Chapter $id',
      content: 'The lighthouse keeper rowed out at dawn to meet the ferry.',
      projectId: project,
      createdAt: now,
      modifiedAt: now,
    );
  }

  Character character(String id) {
    final DateTime now = DateTime.utc(2024, 1, 1);
    return Character(
      id: id,
      projectId: projectId,
      name: 'Mara',
      role: 'Keeper',
      notes: 'Afraid of deep water.',
      image: null,
      createdAt: now,
      modifiedAt: now,
    );
  }

  /// Builds the same IndexingState + ProjectIndexer + binding main.dart builds.
  (IndexingState, IndexingBinding) bind({required bool modelPresent}) {
    final IndexingState indexing = IndexingState(
      projectId,
      indexer: ProjectIndexer(
        embeddingModel: model,
        embeddings: embeddings,
        documents: documents,
        characters: characters,
        indexState: SqliteIndexStateStore(db),
      ),
      downloader: _FakeDownloader(present: modelPresent),
    );
    final IndexingBinding binding = IndexingBinding(
      indexing: indexing,
      documentChanges: documents.changes,
      characterChanges: characters.changes,
    )..start();
    addTearDown(() {
      binding.dispose();
      indexing.dispose();
    });
    return (indexing, binding);
  }

  Future<List<StoredChunkEmbedding>> rowsFor(String sourceId,
      {String project = projectId}) async {
    final List<StoredChunkEmbedding> all = <StoredChunkEmbedding>[];
    await for (final List<StoredChunkEmbedding> batch
        in embeddings.scanProject(project)) {
      all.addAll(batch.where((StoredChunkEmbedding r) => r.sourceId == sourceId));
    }
    return all;
  }

  group('ObservableDocumentRepository', () {
    test('reports successful writes and nothing for failed ones', () async {
      final List<RepositoryChangeKind> seen = <RepositoryChangeKind>[];
      documents.changes.listen((RepositoryChange c) => seen.add(c.kind));

      final Document created = await documents.create(doc('d1'));
      await documents.update(created.copyWith(content: 'Edited.'));
      await documents.delete(created.id);
      await _settle();
      expect(seen, <RepositoryChangeKind>[
        RepositoryChangeKind.added,
        RepositoryChangeKind.updated,
        RepositoryChangeKind.removed,
      ]);

      final ObservableDocumentRepository failing =
          ObservableDocumentRepository(_FailingDocumentRepository());
      final List<RepositoryChange> failedSeen = <RepositoryChange>[];
      failing.changes.listen(failedSeen.add);
      await expectLater(failing.create(doc('x')), throwsStateError);
      await expectLater(failing.update(doc('x')), throwsStateError);
      await expectLater(failing.delete('x'), throwsStateError);
      await _settle();
      expect(failedSeen, isEmpty);
      await failing.close();
    });
  });

  group('IndexingBinding', () {
    test('model cached: probes, builds the existing project, then follows '
        'add / rename / remove saves', () async {
      // Pre-existing content is picked up by the initial full build (Req 9.2).
      await documents.create(doc('existing'));
      final (IndexingState indexing, _) = bind(modelPresent: true);
      await _settle();
      expect(indexing.embeddingModelReady, isTrue);
      expect(indexing.status, IndexStatus.ready);
      expect(await rowsFor('existing'), isNotEmpty);

      // Add → indexed (Req 4.3).
      final Document added = await documents.create(doc('d1'));
      await characters.create(character('c1'));
      await _settle();
      expect(await rowsFor('d1'), isNotEmpty);
      expect(await rowsFor('c1'), isNotEmpty);

      // Rename → every stored row carries the new title (Req 4.5).
      await documents.update(added.copyWith(title: 'Renamed'));
      await _settle();
      final List<StoredChunkEmbedding> renamed = await rowsFor('d1');
      expect(renamed, isNotEmpty);
      expect(
        renamed.every((StoredChunkEmbedding r) => r.sourceTitle == 'Renamed'),
        isTrue,
      );

      // Remove → rows gone (Req 4.4).
      await documents.delete('d1');
      await characters.delete('c1');
      await _settle();
      expect(await rowsFor('d1'), isEmpty);
      expect(await rowsFor('c1'), isEmpty);
      expect(await rowsFor('existing'), isNotEmpty);
    });

    test('ignores saves for other projects', () async {
      final (IndexingState indexing, _) = bind(modelPresent: true);
      await _settle();
      expect(indexing.status, IndexStatus.ready);

      await documents.create(doc('foreign', project: otherProjectId));
      await _settle();
      expect(await rowsFor('foreign', project: otherProjectId), isEmpty);
      expect(await embeddings.countForProject(otherProjectId), 0);
    });

    test('model absent: no build and no per-save embedding', () async {
      final (IndexingState indexing, _) = bind(modelPresent: false);
      await _settle();
      expect(indexing.embeddingModelStatus, EmbeddingModelStatus.absent);
      expect(indexing.status, IndexStatus.idle);

      await documents.create(doc('d1'));
      await _settle();
      expect(model.embeddedCount, 0);
      expect(await embeddings.countForProject(projectId), 0);
    });

    test('after dispose, saves are no longer forwarded', () async {
      final (IndexingState indexing, IndexingBinding binding) =
          bind(modelPresent: true);
      await _settle();
      expect(indexing.status, IndexStatus.ready);

      binding.dispose();
      await documents.create(doc('late'));
      await _settle();
      expect(await rowsFor('late'), isEmpty);
    });
  });
}
