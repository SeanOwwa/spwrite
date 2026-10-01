// Unit tests for IndexingState with fakes for every collaborator (task 13.2).
//
// Validates: Requirements 9.1, 9.2, 9.6, 3.2, 3.4, 7.4
//
// These tests drive IndexingState through its public surface with lightweight
// fakes for its collaborators (ProjectIndexer, ModelDownloader,
// ConnectivityProbe), so the state layer is exercised deterministically with no
// real embedding runtime, database, network, or timers:
//
//   1. reindex() drives the injected indexer and moves the status
//      idle -> building -> ready while forwarding the indexer's (done, total)
//      progress into progress / indexedSources / totalSources (Req 9.1, 9.2,
//      9.6).
//   2. A build failure settles status == error with a recoverable
//      transientError and never throws out of reindex() (Req 7.4).
//   3. isSemanticReady() reflects embeddingModelReady AND not-error: false while
//      the model is absent, true once ready, false again after a build error
//      (Req 7.1).
//   4. prepareEmbeddingModel() sets ready when the model is present and absent
//      when it is missing, without ever starting a download (Req 3.2, 3.7).
//   5. downloadEmbeddingModel() drives downloading -> ready on success (progress
//      reaching 1.0) and downloading -> failed with a transientError on a
//      ModelDownloadException, never throwing (Req 3.2, 3.4, 3.5).
//   6. onStaleIndexDetected(projectId) schedules a rebuild for the matching
//      project and ignores signals for any other project (Req 7.4).
//   7. onDocumentSaved / onSourceAdded / onSourceRemoved / onDocumentRenamed
//      forward to the indexer as background work (Req 4.3, 4.4, 4.5).
//   8. dispose() prevents further notifications (a late progress callback or a
//      settling build never mutates a disposed notifier).
//
// Test-double strategy. Both ProjectIndexer and ModelDownloader are concrete
// classes taken by IndexingState by type, and their methods are not final, so
// each fake subclasses the real class and overrides only the members the state
// touches. The overrides short-circuit before any base behavior runs, so the
// (never-called) EmbeddingModel / repositories handed to ProjectIndexer's super
// constructor and the (never-called) directoryResolver handed to
// ModelDownloader's super constructor are inert — the same pattern the existing
// AiAssistantState tests use for their ModelDownloader fake. No production code
// is modified to make the state testable.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spwrite/data/ai/chunk_embedding_repository.dart';
import 'package:spwrite/data/ai/model_downloader.dart';
import 'package:spwrite/data/ai/project_indexer.dart';
import 'package:spwrite/domain/ai/connectivity_probe.dart';
import 'package:spwrite/domain/ai/embedding_model.dart';
import 'package:spwrite/domain/ai/model_catalog.dart';
import 'package:spwrite/domain/character.dart';
import 'package:spwrite/domain/character_repository.dart';
import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';
import 'package:spwrite/state/indexing_state.dart';

// ---------------------------------------------------------------------------
// Inert collaborators for ProjectIndexer's super constructor.
//
// ProjectIndexer requires an EmbeddingModel and repositories, but the fake
// indexer below overrides every method IndexingState calls, so none of these
// are ever invoked. They throw if touched, which would surface a mistake in the
// fake rather than silently pass.
// ---------------------------------------------------------------------------
class _UnusedEmbeddingModel implements EmbeddingModel {
  @override
  int get dimension => throw StateError('EmbeddingModel must not be used');
  @override
  String get modelId => throw StateError('EmbeddingModel must not be used');
  @override
  Future<void> load() async => throw StateError('unused');
  @override
  Future<List<double>> embed(String text) async => throw StateError('unused');
  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async =>
      throw StateError('unused');
  @override
  Future<void> dispose() async => throw StateError('unused');
}

class _UnusedDocumentRepository implements DocumentRepository {
  @override
  Future<List<Document>> getByProject(String projectId) async =>
      throw StateError('unused');
  @override
  Future<List<Document>> getByContainer(
          String projectId, String? folderId) async =>
      throw StateError('unused');
  @override
  Future<Document?> getById(String id) async => throw StateError('unused');
  @override
  Future<Document> create(Document doc) async => throw StateError('unused');
  @override
  Future<void> update(Document doc) async => throw StateError('unused');
  @override
  Future<void> updatePositions(List<Document> documents) async =>
      throw StateError('unused');
  @override
  Future<void> delete(String id) async => throw StateError('unused');
}

class _UnusedCharacterRepository implements CharacterRepository {
  @override
  Future<List<Character>> getAllForProject(String projectId) async =>
      throw StateError('unused');
  @override
  Future<Character?> getById(String id) async => throw StateError('unused');
  @override
  Future<Character> create(Character character) async =>
      throw StateError('unused');
  @override
  Future<void> update(Character character) async => throw StateError('unused');
  @override
  Future<void> delete(String id) async => throw StateError('unused');
}

/// An inert ChunkEmbeddingRepository handed to the fake indexer's super
/// constructor. ChunkEmbeddingRepository only stores its [Database] in a
/// (private) field and never touches it at construction, and the fake indexer
/// overrides every method that would use it, so the [_NeverDatabase] placeholder
/// below is stored but never dereferenced. It satisfies the `Database` type via
/// `implements`, and throws through `noSuchMethod` if any method is ever called
/// (which would flag a bug in the fake rather than pass silently).
ChunkEmbeddingRepository _inertEmbeddings() =>
    ChunkEmbeddingRepository(_NeverDatabase());

/// A `Database` that throws on any use — see [_inertEmbeddings]. Implementing
/// the interface (rather than a bare stub) makes it assignable to
/// ChunkEmbeddingRepository's typed field without a runtime type error.
class _NeverDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Database must not be used');
}

// ---------------------------------------------------------------------------
// Fake ProjectIndexer.
//
// Subclasses the real ProjectIndexer (its methods are not final) and overrides
// exactly the members IndexingState drives: reindexProject (with progress),
// onSourceAdded, onSourceRemoved, and onDocumentRenamed. Every override
// short-circuits before any base behavior, so the inert collaborators handed to
// super are never touched.
//
// reindexProject replays a scripted list of (done, total) steps through the
// onProgress callback, then either completes or throws [failWith], letting a
// test observe the forwarded progress and the success/error settle. The
// incremental methods record their arguments so a test can assert forwarding.
// ---------------------------------------------------------------------------
class _FakeProjectIndexer extends ProjectIndexer {
  _FakeProjectIndexer({
    this.progressSteps = const <(int, int)>[],
    this.failWith,
  }) : super(
          embeddingModel: _UnusedEmbeddingModel(),
          embeddings: _inertEmbeddings(),
          documents: _UnusedDocumentRepository(),
          characters: _UnusedCharacterRepository(),
        );

  /// (done, total) steps replayed through onProgress before completing/failing.
  List<(int, int)> progressSteps;

  /// When non-null, reindexProject throws this after replaying [progressSteps],
  /// exercising the recoverable-error path (Req 7.4).
  Object? failWith;

  /// The projectIds reindexProject was called with, in order.
  final List<String> reindexCalls = <String>[];

  /// Sources forwarded to onSourceAdded, in order.
  final List<Object> addedSources = <Object>[];

  /// (projectId, sourceId) pairs forwarded to onSourceRemoved, in order.
  final List<(String, String)> removedSources = <(String, String)>[];

  /// Documents forwarded to onDocumentRenamed, in order.
  final List<Document> renamedDocuments = <Document>[];

  /// When set, reindexProject awaits this before completing, so a test can hold
  /// a build "in flight" (e.g. to observe the building status) and release it.
  Completer<void>? gate;

  @override
  Future<void> reindexProject(
    String projectId, {
    IndexProgress? onProgress,
  }) async {
    reindexCalls.add(projectId);
    for (final (int, int) step in progressSteps) {
      onProgress?.call(step.$1, step.$2);
    }
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    final Object? failure = failWith;
    if (failure != null) throw failure;
  }

  @override
  Future<void> onSourceAdded(Object source) async {
    addedSources.add(source);
  }

  @override
  Future<void> onSourceRemoved(String projectId, String sourceId) async {
    removedSources.add((projectId, sourceId));
  }

  @override
  Future<void> onDocumentRenamed(Document document) async {
    renamedDocuments.add(document);
  }
}

// ---------------------------------------------------------------------------
// Fake ModelDownloader.
//
// Subclasses the real ModelDownloader (methods are not final) and overrides the
// two members IndexingState uses: isModelPresent() and download(). The base
// constructor runs with a directoryResolver that is never invoked because both
// overrides short-circuit. Mirrors the fake in the AiAssistantState tests.
// ---------------------------------------------------------------------------
class _FakeModelDownloader extends ModelDownloader {
  _FakeModelDownloader({
    this.present = false,
    this.failWith,
    this.progressSteps = const <(int, int?)>[],
  }) : super(directoryResolver: _neverResolve);

  /// What isModelPresent() reports.
  bool present;

  /// When non-null, download() drives [progressSteps] then throws this.
  ModelDownloadException? failWith;

  /// Progress callbacks download() emits before completing/failing.
  List<(int, int?)> progressSteps;

  int isPresentCount = 0;
  int downloadCount = 0;

  static Future<Directory> _neverResolve() async =>
      throw StateError('directoryResolver must not be called by the fake');

  @override
  Future<bool> isModelPresent(ModelMetadata model) async {
    isPresentCount += 1;
    return present;
  }

  @override
  Future<String> download(
    ModelMetadata model, {
    DownloadProgressCallback? onProgress,
  }) async {
    downloadCount += 1;
    for (final (int, int?) step in progressSteps) {
      onProgress?.call(step.$1, step.$2);
    }
    final ModelDownloadException? failure = failWith;
    if (failure != null) throw failure;
    present = true;
    return 'fake/cache/${model.id}.gguf';
  }
}

// ---------------------------------------------------------------------------
// Fake ConnectivityProbe.
//
// Extends ChangeNotifier and implements ConnectivityProbe so a test can set a
// value that notifies listeners. start()/dispose() are recorded.
// ---------------------------------------------------------------------------
class _FakeConnectivityProbe extends ChangeNotifier
    implements ConnectivityProbe {
  _FakeConnectivityProbe([this._value = ConnectivityStatus.unknown]);

  ConnectivityStatus _value;
  int startCount = 0;
  bool disposed = false;

  @override
  ConnectivityStatus get value => _value;

  set value(ConnectivityStatus next) {
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }

  @override
  void start() {
    startCount += 1;
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

/// Counts notifyListeners calls on the state under test.
class _NotifyCounter {
  int count = 0;
  void call() => count += 1;
}

/// A minimal document for the rename-forwarding test.
Document _doc({
  String id = 'doc-1',
  String projectId = 'project-1',
  String title = 'A Title',
  String content = 'Body.',
}) {
  final DateTime now = DateTime.utc(2024, 1, 1);
  return Document(
    id: id,
    title: title,
    content: content,
    projectId: projectId,
    createdAt: now,
    modifiedAt: now,
  );
}

void main() {
  // Build an IndexingState over the given fakes, registering a tearDown to
  // dispose it.
  IndexingState build({
    String projectId = 'project-1',
    required _FakeProjectIndexer indexer,
    required _FakeModelDownloader downloader,
    _FakeConnectivityProbe? probe,
  }) {
    final IndexingState state = IndexingState(
      projectId,
      indexer: indexer,
      downloader: downloader,
      connectivityProbe: probe,
    );
    addTearDown(state.dispose);
    return state;
  }

  group('reindex(): idle -> building -> ready with forwarded progress '
      '(Req 9.1, 9.2, 9.6)', () {
    test('drives the indexer and forwards (done, total) into observable fields',
        () async {
      final _FakeProjectIndexer indexer = _FakeProjectIndexer(
        progressSteps: const <(int, int)>[(0, 3), (1, 3), (2, 3), (3, 3)],
      );
      final IndexingState state = build(
        indexer: indexer,
        downloader: _FakeModelDownloader(present: true),
      );

      expect(state.status, IndexStatus.idle);

      state.reindex();
      // Let the background build run to completion.
      await pumpEventQueue();

      // The indexer was driven, scoped to this project.
      expect(indexer.reindexCalls, <String>['project-1']);

      // Settled ready with progress pinned to complete and the final X-of-Y.
      expect(state.status, IndexStatus.ready);
      expect(state.progress, 1.0);
      expect(state.indexedSources, 3);
      expect(state.totalSources, 3);
      expect(state.transientError, isNull);
    });

    test('is observably `building` mid-flight, then settles ready', () async {
      final Completer<void> gate = Completer<void>();
      final _FakeProjectIndexer indexer = _FakeProjectIndexer(
        progressSteps: const <(int, int)>[(1, 4)],
      )..gate = gate;
      final IndexingState state = build(
        indexer: indexer,
        downloader: _FakeModelDownloader(present: true),
      );

      state.reindex();
      await pumpEventQueue();

      // The build is held open on the gate: we are mid-flight.
      expect(state.status, IndexStatus.building);
      expect(state.isBuilding, isTrue);
      expect(state.indexedSources, 1);
      expect(state.totalSources, 4);
      expect(state.progress, closeTo(0.25, 1e-9));

      // Release the gate: the build completes and settles ready.
      gate.complete();
      await pumpEventQueue();

      expect(state.status, IndexStatus.ready);
      expect(state.progress, 1.0);
    });

    test('a zero-source build still settles ready at progress 1.0', () async {
      final _FakeProjectIndexer indexer = _FakeProjectIndexer(
        progressSteps: const <(int, int)>[(0, 0)],
      );
      final IndexingState state = build(
        indexer: indexer,
        downloader: _FakeModelDownloader(present: true),
      );

      state.reindex();
      await pumpEventQueue();

      expect(state.status, IndexStatus.ready);
      expect(state.progress, 1.0);
      expect(state.totalSources, 0);
    });
  });

  test(
    'a build failure settles status == error with a transientError and never '
    'throws (Req 7.4)',
    () async {
      final _FakeProjectIndexer indexer = _FakeProjectIndexer(
        progressSteps: const <(int, int)>[(0, 2)],
        failWith: StateError('embedding runtime blew up'),
      );
      final IndexingState state = build(
        indexer: indexer,
        downloader: _FakeModelDownloader(present: true),
      );

      // reindex() is fire-and-forget; the failure must be swallowed into state,
      // never surfaced as an unhandled error.
      state.reindex();
      await pumpEventQueue();

      expect(state.status, IndexStatus.error);
      expect(state.transientError, isNotNull);
      // The build was actually attempted.
      expect(indexer.reindexCalls, <String>['project-1']);
    },
  );

  group('isSemanticReady(): embeddingModelReady AND not-error (Req 7.1)', () {
    test('false while the embedding model is absent', () async {
      final IndexingState state = build(
        indexer: _FakeProjectIndexer(),
        downloader: _FakeModelDownloader(present: false),
      );

      await state.prepareEmbeddingModel();

      expect(state.embeddingModelReady, isFalse);
      expect(state.isSemanticReady(), isFalse);
    });

    test('true once the model is ready and the index is not in error',
        () async {
      final IndexingState state = build(
        indexer: _FakeProjectIndexer(),
        downloader: _FakeModelDownloader(present: true),
      );

      await state.prepareEmbeddingModel();

      expect(state.embeddingModelReady, isTrue);
      expect(state.isSemanticReady(), isTrue);
    });

    test('false again after a build error even when the model is ready',
        () async {
      final _FakeProjectIndexer indexer = _FakeProjectIndexer(
        failWith: StateError('boom'),
      );
      final IndexingState state = build(
        indexer: indexer,
        downloader: _FakeModelDownloader(present: true),
      );

      await state.prepareEmbeddingModel();
      expect(state.isSemanticReady(), isTrue);

      state.reindex();
      await pumpEventQueue();

      expect(state.status, IndexStatus.error);
      expect(state.embeddingModelReady, isTrue);
      // Ready model but an errored index -> semantic tier must not be attempted.
      expect(state.isSemanticReady(), isFalse);
    });
  });

  group('prepareEmbeddingModel(): present -> ready, missing -> absent, no '
      'download (Req 3.2, 3.7)', () {
    test('sets ready when the model is already present, without downloading',
        () async {
      final _FakeModelDownloader downloader = _FakeModelDownloader(
        present: true,
      );
      final IndexingState state = build(
        indexer: _FakeProjectIndexer(),
        downloader: downloader,
      );

      await state.prepareEmbeddingModel();

      expect(state.embeddingModelStatus, EmbeddingModelStatus.ready);
      expect(downloader.isPresentCount, 1);
      // Presence is probed, never a download started (that waits for confirm).
      expect(downloader.downloadCount, 0);
    });

    test('surfaces absent when the model is missing, without downloading',
        () async {
      final _FakeModelDownloader downloader = _FakeModelDownloader(
        present: false,
      );
      final IndexingState state = build(
        indexer: _FakeProjectIndexer(),
        downloader: downloader,
      );

      await state.prepareEmbeddingModel();

      expect(state.embeddingModelStatus, EmbeddingModelStatus.absent);
      expect(downloader.isPresentCount, 1);
      expect(downloader.downloadCount, 0);
    });
  });

  group('downloadEmbeddingModel(): downloading -> ready / failed (Req 3.2, '
      '3.4, 3.5)', () {
    test('drives progress to ready with downloadProgress == 1.0 on success',
        () async {
      final _FakeModelDownloader downloader = _FakeModelDownloader(
        present: false,
        progressSteps: const <(int, int?)>[(50, 100)],
      );
      final IndexingState state = build(
        indexer: _FakeProjectIndexer(),
        downloader: downloader,
      );

      await state.downloadEmbeddingModel();

      expect(downloader.downloadCount, 1);
      expect(state.embeddingModelStatus, EmbeddingModelStatus.ready);
      expect(state.downloadProgress, 1.0);
      expect(state.transientError, isNull);
    });

    test(
      'settles failed with a transientError on ModelDownloadException, no throw',
      () async {
        final _FakeModelDownloader downloader = _FakeModelDownloader(
          present: false,
          failWith: const ModelDownloadException.offline(),
        );
        final IndexingState state = build(
          indexer: _FakeProjectIndexer(),
          downloader: downloader,
        );

        // Must not throw out of downloadEmbeddingModel — the app stays usable.
        await state.downloadEmbeddingModel();

        expect(state.embeddingModelStatus, EmbeddingModelStatus.failed);
        expect(state.downloadProgress, 0.0);
        expect(state.transientError, isNotNull);
        expect(state.transientError, contains('internet connection'));
      },
    );

    test('records received/total bytes as progress arrives', () async {
      final _FakeModelDownloader downloader = _FakeModelDownloader(
        present: false,
        progressSteps: const <(int, int?)>[(500, 1000)],
      );
      final IndexingState state = build(
        indexer: _FakeProjectIndexer(),
        downloader: downloader,
      );

      await state.downloadEmbeddingModel();

      expect(state.downloadReceivedBytes, 500);
      expect(state.downloadTotalBytes, 1000);
    });
  });

  group('onStaleIndexDetected(): rebuild for matching project, ignore others '
      '(Req 7.4)', () {
    test('schedules a rebuild when the stale project matches this one',
        () async {
      final _FakeProjectIndexer indexer = _FakeProjectIndexer(
        progressSteps: const <(int, int)>[(1, 1)],
      );
      final IndexingState state = build(
        projectId: 'project-1',
        indexer: indexer,
        downloader: _FakeModelDownloader(present: true),
      );

      state.onStaleIndexDetected('project-1');
      await pumpEventQueue();

      // A rebuild was driven for this project.
      expect(indexer.reindexCalls, <String>['project-1']);
      expect(state.status, IndexStatus.ready);
    });

    test('ignores a stale signal for a different project', () async {
      final _FakeProjectIndexer indexer = _FakeProjectIndexer();
      final IndexingState state = build(
        projectId: 'project-1',
        indexer: indexer,
        downloader: _FakeModelDownloader(present: true),
      );

      state.onStaleIndexDetected('some-other-project');
      await pumpEventQueue();

      // No rebuild for this project; status untouched.
      expect(indexer.reindexCalls, isEmpty);
      expect(state.status, IndexStatus.idle);
    });
  });

  group('incremental signals forward to the indexer (Req 4.3, 4.4, 4.5)', () {
    test('onDocumentSaved forwards the document to onSourceAdded', () async {
      final _FakeProjectIndexer indexer = _FakeProjectIndexer();
      final IndexingState state = build(
        indexer: indexer,
        downloader: _FakeModelDownloader(present: true),
      );

      final Document doc = _doc(id: 'doc-42');
      state.onDocumentSaved(doc);
      await pumpEventQueue();

      expect(indexer.addedSources, <Object>[doc]);
    });

    test('onSourceAdded forwards the source to the indexer', () async {
      final _FakeProjectIndexer indexer = _FakeProjectIndexer();
      final IndexingState state = build(
        indexer: indexer,
        downloader: _FakeModelDownloader(present: true),
      );

      final Document doc = _doc(id: 'doc-new');
      state.onSourceAdded(doc);
      await pumpEventQueue();

      expect(indexer.addedSources, <Object>[doc]);
    });

    test('onSourceRemoved forwards (projectId, sourceId) to the indexer',
        () async {
      final _FakeProjectIndexer indexer = _FakeProjectIndexer();
      final IndexingState state = build(
        projectId: 'project-1',
        indexer: indexer,
        downloader: _FakeModelDownloader(present: true),
      );

      state.onSourceRemoved('doc-gone');
      await pumpEventQueue();

      expect(indexer.removedSources, <(String, String)>[
        ('project-1', 'doc-gone'),
      ]);
    });

    test('onDocumentRenamed forwards the renamed document to the indexer',
        () async {
      final _FakeProjectIndexer indexer = _FakeProjectIndexer();
      final IndexingState state = build(
        indexer: indexer,
        downloader: _FakeModelDownloader(present: true),
      );

      final Document renamed = _doc(id: 'doc-r', title: 'New Title');
      state.onDocumentRenamed(renamed);
      await pumpEventQueue();

      expect(indexer.renamedDocuments, <Document>[renamed]);
    });
  });

  group('dispose() prevents further notifications', () {
    test('a settling build after dispose does not notify or mutate', () async {
      final Completer<void> gate = Completer<void>();
      final _FakeProjectIndexer indexer = _FakeProjectIndexer(
        progressSteps: const <(int, int)>[(1, 2)],
      )..gate = gate;
      final IndexingState state = IndexingState(
        'project-1',
        indexer: indexer,
        downloader: _FakeModelDownloader(present: true),
      );

      final _NotifyCounter notified = _NotifyCounter();
      state.addListener(notified.call);

      state.reindex();
      await pumpEventQueue();
      final int beforeDispose = notified.count;

      // Dispose while the build is still held open on the gate.
      state.dispose();

      // Releasing the gate lets the build try to settle; a disposed notifier
      // must neither notify nor advance to ready.
      gate.complete();
      await pumpEventQueue();

      expect(notified.count, beforeDispose);
      // Never advanced past building (the settle was suppressed by _disposed).
      expect(state.status, IndexStatus.building);
    });

    test('reindex() after dispose is a no-op (does not touch the indexer)',
        () async {
      final _FakeProjectIndexer indexer = _FakeProjectIndexer();
      final IndexingState state = IndexingState(
        'project-1',
        indexer: indexer,
        downloader: _FakeModelDownloader(present: true),
      );

      state.dispose();
      state.reindex();
      await pumpEventQueue();

      expect(indexer.reindexCalls, isEmpty);
    });
  });

  group('connectivity mirroring (Req 3.4)', () {
    test('constructor mirrors the initial probe value and starts the probe',
        () {
      final _FakeConnectivityProbe probe =
          _FakeConnectivityProbe(ConnectivityStatus.online);
      final IndexingState state = build(
        indexer: _FakeProjectIndexer(),
        downloader: _FakeModelDownloader(present: true),
        probe: probe,
      );

      expect(state.connectivity, ConnectivityStatus.online);
      expect(probe.startCount, 1);
    });

    test('driving the probe offline updates connectivity and notifies',
        () async {
      final _FakeConnectivityProbe probe =
          _FakeConnectivityProbe(ConnectivityStatus.online);
      final IndexingState state = build(
        indexer: _FakeProjectIndexer(),
        downloader: _FakeModelDownloader(present: true),
        probe: probe,
      );

      final _NotifyCounter notified = _NotifyCounter();
      state.addListener(notified.call);

      probe.value = ConnectivityStatus.offline;

      expect(state.connectivity, ConnectivityStatus.offline);
      expect(notified.count, 1);
    });
  });
}
