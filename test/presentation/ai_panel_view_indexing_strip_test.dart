// Widget tests for the AI Panel's indexing/semantic status strip (task 14.2).
//
// Validates: Requirements 9.1, 10.1
//
// These tests drive the real AiPanelView over BOTH a real AiAssistantState (as
// the existing ai_panel_view_test.dart does) AND a real IndexingState, wired
// side by side via `provider` exactly as the composition root will (task 16).
// The strip observes IndexingState through `context.watch<IndexingState?>()`,
// so the panel is exercised through genuine state transitions rather than a
// hand-rolled stub of the strip.
//
// IndexingState is a real ChangeNotifier driven by the same lightweight fakes
// its own unit tests use for its collaborators (ProjectIndexer, ModelDownloader,
// ConnectivityProbe). We steer it into each surfaced state by calling its public
// methods (prepareEmbeddingModel / downloadEmbeddingModel / reindex /
// onStaleIndexDetected) with fakes scripted to land the state where the test
// wants it — so no real embedding runtime, database, network, or timers run.
//
// Covered surfaces (priority order, from _IndexingStatusStrip):
//   1. Embedding model absent -> a one-time download prompt with a Download
//      action (Req 3.2 surfaced in the strip, Req 10.1).
//   2. Embedding model downloading -> the slim progress line with an "X of Y"
//      byte hint (Req 3.2).
//   3. Index building -> the "X of Y sources" reindex progress line (Req 9.2,
//      9.6).
//   4. Index ready / idle -> the low-emphasis ready confirmation (or nothing
//      when idle with nothing to say) (Req 9.6).
//   5. A transient error -> the recoverable, non-blocking notice (Req 7.4).
//   6. In every one of the above, the chat input row is still present and
//      usable — the strip never blocks the conversation (Req 9.1, 10.1).
//
// Test-double strategy mirrors the existing state/presentation tests: both
// ProjectIndexer and ModelDownloader are concrete classes IndexingState takes by
// type with non-final methods, so each fake subclasses the real class and
// overrides only the members the state touches, short-circuiting before any base
// behavior. The inert collaborators handed to ProjectIndexer's super constructor
// throw if touched, flagging a mistake in the fake rather than passing silently.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spwrite/data/ai/chunk_embedding_repository.dart';
import 'package:spwrite/data/ai/model_downloader.dart';
import 'package:spwrite/data/ai/project_indexer.dart';
import 'package:spwrite/domain/ai/chat_message.dart';
import 'package:spwrite/domain/ai/connectivity_probe.dart';
import 'package:spwrite/domain/ai/context_retriever.dart';
import 'package:spwrite/domain/ai/embedding_model.dart';
import 'package:spwrite/domain/ai/llm_engine.dart';
import 'package:spwrite/domain/ai/model_catalog.dart';
import 'package:spwrite/domain/character.dart';
import 'package:spwrite/domain/character_repository.dart';
import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';
import 'package:spwrite/presentation/ai_panel_view.dart';
import 'package:spwrite/state/ai_assistant_state.dart';
import 'package:spwrite/state/indexing_state.dart';

// ---------------------------------------------------------------------------
// AiAssistantState fakes — mirror the existing ai_panel_view_test.dart so the
// panel is driven by a real, ready AiAssistantState with no external effects.
// ---------------------------------------------------------------------------

/// A minimal ready [LlmEngine]: load() succeeds, generate() replays a canned
/// (possibly empty) stream. The chat side is incidental to these tests — we only
/// need the model to probe ready so the panel shows its normal chat surface with
/// the input row enabled.
class _ReadyLlmEngine implements LlmEngine {
  @override
  Future<void> load() async {}

  @override
  Stream<String> generate({
    required String prompt,
    List<ChatMessage> history = const <ChatMessage>[],
    int? maxTokens,
    double? temperature,
  }) => const Stream<String>.empty();

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

/// A no-op [ContextRetriever]; the chat retrieval path is not under test here.
class _NoopContextRetriever implements ContextRetriever {
  @override
  Future<List<RetrievedPassage>> retrieve(String query) async =>
      const <RetrievedPassage>[];

  @override
  Future<bool> hasProjectMaterial() async => false;
}

/// A [ModelDownloader] for AiAssistantState that reports the chat model present,
/// so the state probes to `ready` and the input row is enabled.
class _PresentModelDownloader extends ModelDownloader {
  _PresentModelDownloader() : super(directoryResolver: _neverResolve);

  static Future<Directory> _neverResolve() async =>
      throw StateError('directoryResolver must not be called by the fake');

  @override
  Future<bool> isModelPresent(ModelMetadata model) async => true;

  @override
  Future<String> download(
    ModelMetadata model, {
    DownloadProgressCallback? onProgress,
  }) async =>
      'fake/cache/${model.id}.gguf';
}

/// A [ConnectivityProbe] fixed online so no offline banner appears — keeps the
/// tests focused on the indexing strip.
class _OnlineConnectivityProbe extends ChangeNotifier
    implements ConnectivityProbe {
  @override
  ConnectivityStatus get value => ConnectivityStatus.online;

  @override
  void start() {}
}

// ---------------------------------------------------------------------------
// Inert collaborators for the fake ProjectIndexer's super constructor. None are
// ever invoked (the fake overrides every method IndexingState drives); they
// throw if touched, surfacing a mistake in the fake rather than passing.
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

ChunkEmbeddingRepository _inertEmbeddings() =>
    ChunkEmbeddingRepository(_NeverDatabase());

class _NeverDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Database must not be used');
}

// ---------------------------------------------------------------------------
// Fake ProjectIndexer — subclasses the real one and overrides reindexProject.
// It replays scripted (done, total) steps through onProgress, then optionally
// awaits a [gate] (to hold a build mid-flight so `building` is observable) and
// optionally throws [failWith] (to exercise the recoverable-error path).
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

  List<(int, int)> progressSteps;
  Object? failWith;
  Completer<void>? gate;

  @override
  Future<void> reindexProject(
    String projectId, {
    IndexProgress? onProgress,
  }) async {
    for (final (int, int) step in progressSteps) {
      onProgress?.call(step.$1, step.$2);
    }
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    final Object? failure = failWith;
    if (failure != null) throw failure;
  }
}

// ---------------------------------------------------------------------------
// Fake ModelDownloader for the embedding model — subclasses the real one and
// overrides the two members IndexingState uses. A [gate] holds download() in
// flight so the `downloading` surface is observable; [progressSteps] feed the
// byte hint.
// ---------------------------------------------------------------------------
class _FakeEmbeddingDownloader extends ModelDownloader {
  _FakeEmbeddingDownloader({
    this.present = false,
    this.progressSteps = const <(int, int?)>[],
  }) : super(directoryResolver: _neverResolve);

  bool present;
  List<(int, int?)> progressSteps;
  Completer<void>? gate;

  static Future<Directory> _neverResolve() async =>
      throw StateError('directoryResolver must not be called by the fake');

  @override
  Future<bool> isModelPresent(ModelMetadata model) async => present;

  @override
  Future<String> download(
    ModelMetadata model, {
    DownloadProgressCallback? onProgress,
  }) async {
    for (final (int, int?) step in progressSteps) {
      onProgress?.call(step.$1, step.$2);
    }
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    present = true;
    return 'fake/cache/${model.id}.gguf';
  }
}

void main() {
  // Builds a ready AiAssistantState over inert chat collaborators.
  AiAssistantState buildChatState() {
    final AiAssistantState state = AiAssistantState(
      'project-1',
      engine: _ReadyLlmEngine(),
      retriever: _NoopContextRetriever(),
      downloader: _PresentModelDownloader(),
      connectivityProbe: _OnlineConnectivityProbe(),
    );
    addTearDown(state.dispose);
    return state;
  }

  // Builds a real IndexingState over the given fakes.
  IndexingState buildIndexingState({
    required _FakeProjectIndexer indexer,
    required _FakeEmbeddingDownloader downloader,
  }) {
    final IndexingState state = IndexingState(
      'project-1',
      indexer: indexer,
      downloader: downloader,
    );
    addTearDown(state.dispose);
    return state;
  }

  // Pumps the panel with BOTH states provided side by side, exactly as the
  // composition root will wire them. IndexingState is provided as its own type,
  // which satisfies the panel's `context.watch<IndexingState?>()` lookup.
  Future<void> pumpPanel(
    WidgetTester tester, {
    required AiAssistantState chat,
    required IndexingState indexing,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<AiAssistantState>.value(value: chat),
              ChangeNotifierProvider<IndexingState>.value(value: indexing),
            ],
            child: SizedBox(
              width: 320,
              height: 720,
              child: AiPanelView(onClose: () {}),
            ),
          ),
        ),
      ),
    );
    // Let the one-shot post-frame ensureModelReady probe run and settle.
    await tester.pumpAndSettle();
  }

  // The chat input row must remain present and usable in every strip state —
  // the strip never blocks the conversation (Req 9.1, 10.1).
  void expectInputUsable(WidgetTester tester) {
    final Finder input = find.byType(TextField);
    expect(input, findsOneWidget);
    expect(
      tester.widget<TextField>(input).enabled,
      isNot(false),
      reason: 'the chat input must stay usable behind the status strip',
    );
    // The send control is present (idle chat), confirming the input row renders.
    expect(find.byIcon(Icons.send), findsOneWidget);
  }

  testWidgets(
    'embedding model absent: shows the one-time download prompt/action, chat '
    'input still usable (Req 3.2, 9.1, 10.1)',
    (WidgetTester tester) async {
      final IndexingState indexing = buildIndexingState(
        indexer: _FakeProjectIndexer(),
        downloader: _FakeEmbeddingDownloader(present: false),
      );
      // Probe the (absent) embedding model so the strip shows the prompt.
      await indexing.prepareEmbeddingModel();

      await pumpPanel(tester, chat: buildChatState(), indexing: indexing);

      expect(indexing.embeddingModelStatus, EmbeddingModelStatus.absent);
      expect(
        find.textContaining('Enable semantic search across your whole project'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Download'), findsOneWidget);

      expectInputUsable(tester);
    },
  );

  testWidgets(
    'embedding model downloading: shows progress with an "X of Y" byte hint, '
    'chat input still usable (Req 3.2, 9.1)',
    (WidgetTester tester) async {
      final Completer<void> gate = Completer<void>();
      final _FakeEmbeddingDownloader downloader = _FakeEmbeddingDownloader(
        present: false,
        progressSteps: const <(int, int?)>[(500000000, 1000000000)],
      )..gate = gate;
      final IndexingState indexing = buildIndexingState(
        indexer: _FakeProjectIndexer(),
        downloader: downloader,
      );

      // Kick off the gated download so the strip sits in the downloading state.
      unawaited(indexing.downloadEmbeddingModel());
      await pumpPanel(tester, chat: buildChatState(), indexing: indexing);

      expect(indexing.embeddingModelStatus, EmbeddingModelStatus.downloading);
      expect(
        find.text('Downloading the semantic-search model'),
        findsOneWidget,
      );
      // The byte hint reads "X of Y · NN%".
      expect(find.textContaining('of'), findsWidgets);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      expectInputUsable(tester);

      // Release the gate so no pending future is left dangling.
      gate.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'index building: shows the "X of Y sources" reindex progress, chat input '
    'still usable (Req 9.2, 9.6, 9.1)',
    (WidgetTester tester) async {
      final Completer<void> gate = Completer<void>();
      final _FakeProjectIndexer indexer = _FakeProjectIndexer(
        progressSteps: const <(int, int)>[(1, 4)],
      )..gate = gate;
      // Model present so the strip falls through to the index-status branch.
      final IndexingState indexing = buildIndexingState(
        indexer: indexer,
        downloader: _FakeEmbeddingDownloader(present: true),
      );
      await indexing.prepareEmbeddingModel();

      // Start a build and hold it mid-flight on the gate.
      indexing.reindex();
      await pumpPanel(tester, chat: buildChatState(), indexing: indexing);

      expect(indexing.status, IndexStatus.building);
      expect(
        find.text('Indexing your project for semantic search'),
        findsOneWidget,
      );
      expect(find.textContaining('1 of 4 sources'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      expectInputUsable(tester);

      // Release the gate so the build settles and no future dangles.
      gate.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'index ready: shows the ready confirmation, chat input still usable '
    '(Req 9.6, 9.1)',
    (WidgetTester tester) async {
      final IndexingState indexing = buildIndexingState(
        indexer: _FakeProjectIndexer(
          progressSteps: const <(int, int)>[(2, 2)],
        ),
        downloader: _FakeEmbeddingDownloader(present: true),
      );
      await indexing.prepareEmbeddingModel();

      // Run a build to completion so the index settles ready. `tester.pump()`
      // flushes the fake indexer's microtasks inside the fake-async zone
      // (`pumpEventQueue()` would wait on real timers and hang here).
      indexing.reindex();
      await tester.pump();

      await pumpPanel(tester, chat: buildChatState(), indexing: indexing);

      expect(indexing.status, IndexStatus.ready);
      expect(
        find.textContaining('Semantic search ready'),
        findsOneWidget,
      );

      expectInputUsable(tester);
    },
  );

  testWidgets(
    'index idle with a ready model: strip collapses to nothing, chat input '
    'still usable (Req 9.1)',
    (WidgetTester tester) async {
      final IndexingState indexing = buildIndexingState(
        indexer: _FakeProjectIndexer(),
        downloader: _FakeEmbeddingDownloader(present: true),
      );
      // Model ready, index idle, no error -> the strip has nothing to say.
      await indexing.prepareEmbeddingModel();

      await pumpPanel(tester, chat: buildChatState(), indexing: indexing);

      expect(indexing.status, IndexStatus.idle);
      // None of the strip variants render.
      expect(
        find.textContaining('Enable semantic search across your whole project'),
        findsNothing,
      );
      expect(find.text('Downloading the semantic-search model'), findsNothing);
      expect(
        find.text('Indexing your project for semantic search'),
        findsNothing,
      );
      expect(find.textContaining('Semantic search ready'), findsNothing);

      expectInputUsable(tester);
    },
  );

  testWidgets(
    'transient error: shows the recoverable, non-blocking notice, chat input '
    'still usable (Req 7.4, 9.1)',
    (WidgetTester tester) async {
      final _FakeProjectIndexer indexer = _FakeProjectIndexer(
        progressSteps: const <(int, int)>[(0, 2)],
        failWith: StateError('embedding runtime blew up'),
      );
      final IndexingState indexing = buildIndexingState(
        indexer: indexer,
        downloader: _FakeEmbeddingDownloader(present: true),
      );
      await indexing.prepareEmbeddingModel();

      // A build that fails settles status == error with a recoverable message.
      indexing.reindex();
      await tester.pump();

      await pumpPanel(tester, chat: buildChatState(), indexing: indexing);

      expect(indexing.status, IndexStatus.error);
      expect(indexing.transientError, isNotNull);
      // The strip surfaces the state's own recoverable message verbatim.
      expect(find.text(indexing.transientError!), findsOneWidget);

      expectInputUsable(tester);
    },
  );
}
