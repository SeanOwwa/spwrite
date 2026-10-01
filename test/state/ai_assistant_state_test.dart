// Unit tests for AiAssistantState with fakes for every collaborator (task 6.5).
//
// Validates: Requirements 2, 3, 4, 5
//
// These tests drive AiAssistantState through its public surface with
// lightweight fakes for its four collaborators (LlmEngine, ContextRetriever,
// ModelDownloader, ConnectivityProbe), so the state layer is exercised
// deterministically with no real model, network, retrieval, or timers:
//
//   1. Empty/whitespace input is rejected: sendMessage('') and sendMessage('  ')
//      append nothing and leave generationStatus idle (Req 2.8).
//   2. Happy path generating -> idle: with a ready model and canned passages, a
//      streamed reply appends a user turn then an assistant turn, is `generating`
//      mid-stream and `idle` once done, the assistant text is the concatenated
//      deltas, its sources reflect the de-duped passages, and the prompt handed
//      to the engine CONTAINS the passage text/source titles — proving retrieval
//      was passed into the prompt (Req 2.2-2.4, 5.2, 5.4).
//   3. Error path retains history: an error on the engine stream lands
//      generationStatus == error, sets transientError, and keeps the user turn
//      and any partial assistant text (Req 2.5).
//   4. Cancel re-enables input: cancelGeneration() while streaming calls
//      engine.cancel(), returns to idle, drops an empty assistant placeholder,
//      and keeps partial text once some has arrived (Req 2.6).
//   5. Download flow: an absent model surfaces modelStatus == absent; a
//      progress-driving download reaches modelStatus == ready with progress 1.0;
//      a failing download lands modelStatus == failed + transientError without
//      throwing (Req 3.1, 3.2, 3.5).
//   6. Offline hinting: driving the fake probe to offline updates
//      state.connectivity and notifies; chat still works offline when the model
//      is ready (Req 4.2, 4.5).
//   7. sendMessage when the model is not ready: the user turn stays, no
//      assistant turn is appended, and no generation runs (Req 3.1).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';

import 'package:spwrite/data/ai/model_downloader.dart';
import 'package:spwrite/domain/ai/ai_conversation_repository.dart';
import 'package:spwrite/domain/ai/chat_message.dart';
import 'package:spwrite/domain/ai/connectivity_probe.dart';
import 'package:spwrite/domain/ai/context_retriever.dart';
import 'package:spwrite/domain/ai/llm_engine.dart';
import 'package:spwrite/domain/ai/model_catalog.dart';
import 'package:spwrite/state/ai_assistant_state.dart';

// ---------------------------------------------------------------------------
// Fake LlmEngine.
//
// generate() returns a stream the test drives via a StreamController the fake
// exposes (emit / emitError / done), so a test can observe the `generating`
// state mid-stream, then close or error the stream. It captures the last
// `prompt` and `history` so a test can assert retrieval passages made it into
// the prompt (Req 5.2/5.4). cancel()/dispose()/load() record whether they were
// called. If no test-supplied controller is used, generate() can also replay a
// canned list of deltas that closes on its own.
// ---------------------------------------------------------------------------
class _FakeLlmEngine implements LlmEngine {
  /// Deltas replayed by generate() when [useController] is false; the stream
  /// closes after emitting them.
  List<String> cannedDeltas = const <String>[];

  /// When true, generate() returns the test-driven [controller]'s stream
  /// instead of replaying [cannedDeltas], so the test controls timing.
  bool useController = false;

  /// The controller backing a test-driven generation stream.
  final StreamController<String> controller =
      StreamController<String>.broadcast();

  /// The prompt handed to the most recent generate() call (Req 5.2/5.4 assert).
  String? capturedPrompt;

  /// The history handed to the most recent generate() call.
  List<ChatMessage>? capturedHistory;

  /// The maxTokens handed to the most recent generate() call.
  int? capturedMaxTokens;

  int loadCount = 0;
  int cancelCount = 0;
  int disposeCount = 0;
  int generateCount = 0;

  @override
  Future<void> load() async {
    loadCount += 1;
  }

  @override
  Stream<String> generate({
    required String prompt,
    List<ChatMessage> history = const <ChatMessage>[],
    int? maxTokens,
    double? temperature,
  }) {
    generateCount += 1;
    capturedPrompt = prompt;
    capturedHistory = history;
    capturedMaxTokens = maxTokens;
    if (useController) {
      return controller.stream;
    }
    return Stream<String>.fromIterable(cannedDeltas);
  }

  @override
  Future<void> cancel() async {
    cancelCount += 1;
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
  }
}

// ---------------------------------------------------------------------------
// Fake ContextRetriever.
//
// retrieve() returns a canned list of passages and records the query so a test
// can assert the user's message was used. hasProjectMaterial() returns a canned
// bool. Either can be made to throw to exercise the state's tolerant fallback.
// ---------------------------------------------------------------------------
class _FakeContextRetriever implements ContextRetriever {
  _FakeContextRetriever({this.passages = const <RetrievedPassage>[]});

  List<RetrievedPassage> passages;
  bool hasMaterial = true;
  bool retrieveThrows = false;
  bool hasMaterialThrows = false;

  /// The queries passed to retrieve(), in order.
  final List<String> queries = <String>[];

  @override
  Future<List<RetrievedPassage>> retrieve(String query) async {
    queries.add(query);
    if (retrieveThrows) throw StateError('retrieve failed');
    return passages;
  }

  @override
  Future<bool> hasProjectMaterial() async {
    if (hasMaterialThrows) throw StateError('hasProjectMaterial failed');
    return hasMaterial;
  }
}

// ---------------------------------------------------------------------------
// Fake ModelDownloader.
//
// ModelDownloader is a concrete class taken by AiAssistantState by type, so we
// subclass it (its methods are not final) and override the two members the
// state uses: isModelPresent() and download(). The real base constructor runs
// with a never-called client and a resolver that is never invoked, because both
// overridden methods short-circuit before touching any base behavior.
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

  /// When set, download() awaits this before completing, so a test can hold the
  /// transfer "in flight" (e.g. to drive the stall detector) and finish it on
  /// demand. The captured [onProgress] is exposed so the test can emit bytes.
  Completer<void>? gate;
  DownloadProgressCallback? capturedOnProgress;

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
    capturedOnProgress = onProgress;
    for (final (int, int?) step in progressSteps) {
      onProgress?.call(step.$1, step.$2);
    }
    // Optionally hold the transfer open so a test can exercise the in-flight
    // stall detector, then release it via [gate].
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    final ModelDownloadException? failure = failWith;
    if (failure != null) throw failure;
    // Success: the model is now present, mirroring the real atomic rename.
    present = true;
    return 'fake/cache/${model.id}.gguf';
  }
}

// ---------------------------------------------------------------------------
// Fake ConnectivityProbe.
//
// Extends ChangeNotifier and implements ConnectivityProbe so the test can set a
// value that notifies listeners, driving connectivity transitions and proving
// state.connectivity mirrors them (Req 4.5). start() and dispose() are recorded.
// ---------------------------------------------------------------------------
class _FakeConnectivityProbe extends ChangeNotifier
    implements ConnectivityProbe {
  _FakeConnectivityProbe([this._value = ConnectivityStatus.unknown]);

  ConnectivityStatus _value;
  int startCount = 0;
  bool disposed = false;

  @override
  ConnectivityStatus get value => _value;

  /// Test hook: set the current status and notify listeners, as a real probe
  /// would when connectivity changes.
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

// ---------------------------------------------------------------------------
// Fake AiConversationRepository: an in-memory store per project that records
// clearForProject calls. [clearThrows] exercises the clear failure path and
// [loadGate] holds getAllForProject open to race a load against a clear.
// ---------------------------------------------------------------------------
class _FakeConversationRepository implements AiConversationRepository {
  final Map<String, List<ChatMessage>> store = <String, List<ChatMessage>>{};
  final List<String> clearedProjects = <String>[];
  bool clearThrows = false;
  Completer<void>? loadGate;

  @override
  Future<List<ChatMessage>> getAllForProject(String projectId) async {
    final Completer<void>? gate = loadGate;
    if (gate != null) await gate.future;
    return List<ChatMessage>.of(store[projectId] ?? const <ChatMessage>[]);
  }

  @override
  Future<void> append(String projectId, ChatMessage message) async {
    (store[projectId] ??= <ChatMessage>[]).add(message);
  }

  @override
  Future<void> clearForProject(String projectId) async {
    clearedProjects.add(projectId);
    if (clearThrows) throw StateError('clear failed');
    store.remove(projectId);
  }
}

/// Counts notifyListeners calls on the state under test.
class _NotifyCounter {
  int count = 0;
  void call() => count += 1;
}

void main() {
  // Convenience: build an AiAssistantState over the given fakes, registering a
  // tearDown to dispose it.
  AiAssistantState build({
    required _FakeLlmEngine engine,
    required _FakeContextRetriever retriever,
    required _FakeModelDownloader downloader,
    required _FakeConnectivityProbe probe,
  }) {
    final AiAssistantState state = AiAssistantState(
      'project-1',
      engine: engine,
      retriever: retriever,
      downloader: downloader,
      connectivityProbe: probe,
    );
    addTearDown(state.dispose);
    return state;
  }

  group('empty / whitespace input rejected (Req 2.8)', () {
    test('sendMessage("") appends nothing and stays idle', () async {
      final _FakeLlmEngine engine = _FakeLlmEngine();
      final AiAssistantState state = build(
        engine: engine,
        retriever: _FakeContextRetriever(),
        downloader: _FakeModelDownloader(present: true),
        probe: _FakeConnectivityProbe(),
      );

      await state.sendMessage('');

      expect(state.messages, isEmpty);
      expect(state.isEmpty, isTrue);
      expect(state.generationStatus, GenerationStatus.idle);
      expect(engine.generateCount, 0);
    });

    test('sendMessage("   ") appends nothing and stays idle', () async {
      final _FakeLlmEngine engine = _FakeLlmEngine();
      final AiAssistantState state = build(
        engine: engine,
        retriever: _FakeContextRetriever(),
        downloader: _FakeModelDownloader(present: true),
        probe: _FakeConnectivityProbe(),
      );

      await state.sendMessage('   ');

      expect(state.messages, isEmpty);
      expect(state.generationStatus, GenerationStatus.idle);
      expect(engine.generateCount, 0);
    });
  });

  test(
    'happy path: generating -> idle, retrieval flows into the prompt, sources '
    'de-duped (Req 2.2-2.4, 5.2, 5.4)',
    () async {
      final _FakeLlmEngine engine = _FakeLlmEngine()..useController = true;
      final _FakeContextRetriever retriever = _FakeContextRetriever(
        passages: const <RetrievedPassage>[
          RetrievedPassage(
            text: 'Aria wields a silver blade.',
            sourceId: 'char-aria',
            sourceTitle: 'Aria',
            score: 3.0,
          ),
          // Duplicate source id: must be de-duped in the assistant's sources.
          RetrievedPassage(
            text: 'Aria distrusts the council.',
            sourceId: 'char-aria',
            sourceTitle: 'Aria',
            score: 2.0,
          ),
          RetrievedPassage(
            text: 'The council meets at dawn.',
            sourceId: 'doc-council',
            sourceTitle: 'The Council',
            score: 1.0,
          ),
        ],
      );
      final AiAssistantState state = build(
        engine: engine,
        retriever: retriever,
        downloader: _FakeModelDownloader(present: true),
        probe: _FakeConnectivityProbe(),
      );

      // Start the send but DON'T await it — sendMessage awaits stream
      // completion, so we drive the controller while it is in flight to observe
      // the mid-stream `generating` state.
      final Future<void> pending = state.sendMessage('Tell me about Aria');
      // Let the async prelude run (ensureModelReady, retrieval, placeholder).
      await pumpEventQueue();

      // Mid-stream: a user turn and an assistant placeholder exist, and we are
      // generating.
      expect(state.generationStatus, GenerationStatus.generating);
      expect(state.messages.length, 2);
      expect(state.messages[0].role, ChatRole.user);
      expect(state.messages[0].text, 'Tell me about Aria');
      expect(state.messages[1].role, ChatRole.assistant);

      // Retrieval used the user's message as the query.
      expect(retriever.queries, contains('Tell me about Aria'));

      // The prompt handed to the engine contains the passage text and titles —
      // retrieval was passed into the prompt (Req 5.2/5.4).
      final String prompt = engine.capturedPrompt!;
      expect(prompt, contains('Aria wields a silver blade.'));
      expect(prompt, contains('The council meets at dawn.'));
      expect(prompt, contains('[Aria]'));
      expect(prompt, contains('[The Council]'));
      // The just-typed user message is in the prompt too.
      expect(prompt, contains('Tell me about Aria'));

      // Stream the reply in two deltas.
      engine.controller.add('Hel');
      await pumpEventQueue();
      expect(state.messages[1].text, 'Hel');
      expect(state.generationStatus, GenerationStatus.generating);

      engine.controller.add('lo');
      await pumpEventQueue();
      expect(state.messages[1].text, 'Hello');

      // Close the stream: generation settles to idle.
      await engine.controller.close();
      await pending;

      expect(state.generationStatus, GenerationStatus.idle);
      expect(state.messages.length, 2);
      expect(state.messages[1].text, 'Hello');

      // Sources reflect the de-duped passages, in order: Aria then The Council.
      final List<ChatMessageSource> sources = state.messages[1].sources;
      expect(sources.length, 2);
      expect(sources[0].id, 'char-aria');
      expect(sources[0].title, 'Aria');
      expect(sources[1].id, 'doc-council');
      expect(sources[1].title, 'The Council');

      // maxTokens was passed through.
      expect(engine.capturedMaxTokens, isNotNull);
    },
  );

  test(
    'error path: stream error lands in error state, retains history and '
    'partial text (Req 2.5)',
    () async {
      final _FakeLlmEngine engine = _FakeLlmEngine()..useController = true;
      final AiAssistantState state = build(
        engine: engine,
        retriever: _FakeContextRetriever(),
        downloader: _FakeModelDownloader(present: true),
        probe: _FakeConnectivityProbe(),
      );

      final Future<void> pending = state.sendMessage('cause an error');
      await pumpEventQueue();

      // A partial delta arrives before the error.
      engine.controller.add('partial ');
      await pumpEventQueue();
      expect(state.messages[1].text, 'partial ');

      // The engine stream errors out.
      engine.controller.addError(StateError('boom'));
      await pending;

      expect(state.generationStatus, GenerationStatus.error);
      expect(state.transientError, isNotNull);
      // Conversation retained: user turn + assistant turn with partial text.
      expect(state.messages.length, 2);
      expect(state.messages[0].role, ChatRole.user);
      expect(state.messages[0].text, 'cause an error');
      expect(state.messages[1].role, ChatRole.assistant);
      expect(state.messages[1].text, 'partial ');
    },
  );

  test(
    'cancel: re-enables input, calls engine.cancel(), keeps partial text '
    '(Req 2.6)',
    () async {
      final _FakeLlmEngine engine = _FakeLlmEngine()..useController = true;
      final AiAssistantState state = build(
        engine: engine,
        retriever: _FakeContextRetriever(),
        downloader: _FakeModelDownloader(present: true),
        probe: _FakeConnectivityProbe(),
      );

      final Future<void> pending = state.sendMessage('stream then cancel');
      await pumpEventQueue();

      // Some text has streamed before we cancel.
      engine.controller.add('half a reply');
      await pumpEventQueue();
      expect(state.generationStatus, GenerationStatus.generating);

      state.cancelGeneration();

      expect(state.generationStatus, GenerationStatus.idle);
      expect(engine.cancelCount, 1);
      // Partial text is kept (assistant turn not empty).
      expect(state.messages.length, 2);
      expect(state.messages[1].role, ChatRole.assistant);
      expect(state.messages[1].text, 'half a reply');

      // The sendMessage future settles once the controller closes; closing a
      // cancelled subscription's source shouldn't reopen generation.
      await engine.controller.close();
      await pending;
      expect(state.generationStatus, GenerationStatus.idle);
    },
  );

  test(
    'cancel before any delta removes the empty assistant placeholder (Req 2.6)',
    () async {
      final _FakeLlmEngine engine = _FakeLlmEngine()..useController = true;
      final AiAssistantState state = build(
        engine: engine,
        retriever: _FakeContextRetriever(),
        downloader: _FakeModelDownloader(present: true),
        probe: _FakeConnectivityProbe(),
      );

      final Future<void> pending = state.sendMessage('cancel immediately');
      await pumpEventQueue();

      // Placeholder present but empty.
      expect(state.messages.length, 2);
      expect(state.messages[1].text, isEmpty);

      state.cancelGeneration();

      // The empty placeholder is removed; only the user turn remains.
      expect(state.generationStatus, GenerationStatus.idle);
      expect(state.messages.length, 1);
      expect(state.messages[0].role, ChatRole.user);
      expect(engine.cancelCount, 1);

      await engine.controller.close();
      await pending;
    },
  );

  group('download flow (Req 3.1, 3.2, 3.5)', () {
    test('absent model: ensureModelReady surfaces modelStatus == absent',
        () async {
      final _FakeModelDownloader downloader =
          _FakeModelDownloader(present: false);
      final AiAssistantState state = build(
        engine: _FakeLlmEngine(),
        retriever: _FakeContextRetriever(),
        downloader: downloader,
        probe: _FakeConnectivityProbe(),
      );

      await state.ensureModelReady();

      expect(state.modelStatus, ModelStatus.absent);
      expect(downloader.isPresentCount, 1);
    });

    test(
      'downloadModel drives progress to ready with downloadProgress == 1.0',
      () async {
        final _FakeModelDownloader downloader = _FakeModelDownloader(
          present: false,
          progressSteps: const <(int, int?)>[(50, 100)],
        );
        final AiAssistantState state = build(
          engine: _FakeLlmEngine(),
          retriever: _FakeContextRetriever(),
          downloader: downloader,
          probe: _FakeConnectivityProbe(),
        );

        await state.downloadModel();

        expect(downloader.downloadCount, 1);
        expect(state.modelStatus, ModelStatus.ready);
        expect(state.downloadProgress, 1.0);
        expect(state.transientError, isNull);
      },
    );

    test(
      'downloadModel progress never goes backwards despite unknown-total and '
      'out-of-order callbacks (Req 3.2)',
      () async {
        // A messy progress stream: a first known step, then a callback with an
        // unknown total (total == null), then an out-of-order/backwards step,
        // then forward again. The bar must never regress or reset to 0 — that
        // stutter is what read as "back and forth".
        final _FakeModelDownloader downloader = _FakeModelDownloader(
          present: false,
          progressSteps: const <(int, int?)>[
            (40, 100), // 0.40
            (55, null), // unknown total: must be ignored, not reset to 0
            (30, 100), // backwards: must be ignored
            (70, 100), // 0.70
            (100, 100), // 1.0
          ],
        );
        final AiAssistantState state = build(
          engine: _FakeLlmEngine(),
          retriever: _FakeContextRetriever(),
          downloader: downloader,
          probe: _FakeConnectivityProbe(),
        );

        // Record every observed downloadProgress while downloading, so we can
        // assert the sequence is monotonic non-decreasing.
        final List<double> observed = <double>[];
        state.addListener(() {
          if (state.modelStatus == ModelStatus.downloading) {
            observed.add(state.downloadProgress);
          }
        });

        await state.downloadModel();

        // Never regressed at any observed point.
        for (int i = 1; i < observed.length; i++) {
          expect(
            observed[i],
            greaterThanOrEqualTo(observed[i - 1]),
            reason: 'progress went backwards: $observed',
          );
        }
        // Never reset to 0 mid-download after making progress.
        expect(
          observed.skip(1).every((double p) => p > 0.0),
          isTrue,
          reason: 'progress reset to 0 mid-download: $observed',
        );
        expect(state.modelStatus, ModelStatus.ready);
        expect(state.downloadProgress, 1.0);
      },
    );

    test(
      'failing download lands modelStatus == failed + transientError, no throw',
      () async {
        final _FakeModelDownloader downloader = _FakeModelDownloader(
          present: false,
          failWith: const ModelDownloadException.offline(),
        );
        final AiAssistantState state = build(
          engine: _FakeLlmEngine(),
          retriever: _FakeContextRetriever(),
          downloader: downloader,
          probe: _FakeConnectivityProbe(),
        );

        // Must not throw out of downloadModel — the app stays usable (Req 3.4).
        await state.downloadModel();

        expect(state.modelStatus, ModelStatus.failed);
        expect(state.transientError, isNotNull);
        expect(state.transientError, contains('internet connection'));
      },
    );
  });

  group('download activity / stall detection (Req 3.2, 3.4)', () {
    test('exposes received/total byte counts as progress arrives', () async {
      final _FakeModelDownloader downloader = _FakeModelDownloader(
        present: false,
        progressSteps: const <(int, int?)>[(500, 1000)],
      );
      final AiAssistantState state = build(
        engine: _FakeLlmEngine(),
        retriever: _FakeContextRetriever(),
        downloader: downloader,
        probe: _FakeConnectivityProbe(),
      );

      await state.downloadModel();

      // After completion the byte counters reflect the last reported step.
      expect(state.downloadReceivedBytes, 500);
      expect(state.downloadTotalBytes, 1000);
    });

    test('reports idle activity when not downloading', () {
      final AiAssistantState state = build(
        engine: _FakeLlmEngine(),
        retriever: _FakeContextRetriever(),
        downloader: _FakeModelDownloader(present: true),
        probe: _FakeConnectivityProbe(),
      );
      expect(state.downloadActivity, DownloadActivity.idle);
    });

    test(
        'transitions active -> stalled after the threshold with no new bytes, '
        'then recovers when bytes resume (Req 3.4)', () {
      fakeAsync((FakeAsync async) {
        final Completer<void> gate = Completer<void>();
        final _FakeModelDownloader downloader = _FakeModelDownloader(
          present: false,
          progressSteps: const <(int, int?)>[(100, 1000)],
        )..gate = gate;
        final AiAssistantState state = build(
          engine: _FakeLlmEngine(),
          retriever: _FakeContextRetriever(),
          downloader: downloader,
          probe: _FakeConnectivityProbe(),
        );

        // Kick off the download; it emits one progress step then holds open on
        // the gate, so the transfer stays "in flight".
        state.downloadModel();
        async.flushMicrotasks();

        // Immediately after a byte, the download reads as active.
        expect(state.downloadActivity, DownloadActivity.active);

        // Advance past the stall threshold with no new bytes -> stalled.
        async.elapse(AiAssistantState.stallThreshold + const Duration(seconds: 1));
        expect(state.downloadActivity, DownloadActivity.stalled);

        // Bytes resume -> back to active, and the stall clears.
        downloader.capturedOnProgress?.call(600, 1000);
        expect(state.downloadActivity, DownloadActivity.active);

        // Finish the download so the timer is torn down and no pending timers
        // remain in the fake zone.
        gate.complete();
        async.flushMicrotasks();
        expect(state.modelStatus, ModelStatus.ready);
        expect(state.downloadActivity, DownloadActivity.idle);
      });
    });

    test('a download that never reports bytes still trips the stall detector',
        () {
      fakeAsync((FakeAsync async) {
        final Completer<void> gate = Completer<void>();
        final _FakeModelDownloader downloader =
            _FakeModelDownloader(present: false)..gate = gate;
        final AiAssistantState state = build(
          engine: _FakeLlmEngine(),
          retriever: _FakeContextRetriever(),
          downloader: downloader,
          probe: _FakeConnectivityProbe(),
        );

        state.downloadModel();
        async.flushMicrotasks();

        // No progress step was emitted, but the ticker still marks it stalled
        // once the threshold elapses.
        async.elapse(AiAssistantState.stallThreshold + const Duration(seconds: 1));
        expect(state.downloadActivity, DownloadActivity.stalled);

        gate.complete();
        async.flushMicrotasks();
      });
    });
  });

  group('offline hinting (Req 4.2, 4.5)', () {
    test('constructor mirrors initial probe value and starts the probe', () {
      final _FakeConnectivityProbe probe =
          _FakeConnectivityProbe(ConnectivityStatus.online);
      final AiAssistantState state = build(
        engine: _FakeLlmEngine(),
        retriever: _FakeContextRetriever(),
        downloader: _FakeModelDownloader(present: true),
        probe: probe,
      );

      expect(state.connectivity, ConnectivityStatus.online);
      expect(probe.startCount, 1);
    });

    test('driving the probe to offline updates connectivity and notifies',
        () async {
      final _FakeConnectivityProbe probe =
          _FakeConnectivityProbe(ConnectivityStatus.online);
      final AiAssistantState state = build(
        engine: _FakeLlmEngine(),
        retriever: _FakeContextRetriever(),
        downloader: _FakeModelDownloader(present: true),
        probe: probe,
      );

      final _NotifyCounter notified = _NotifyCounter();
      state.addListener(notified.call);

      probe.value = ConnectivityStatus.offline;

      expect(state.connectivity, ConnectivityStatus.offline);
      expect(notified.count, 1);
    });

    test('chat still works offline when the model is ready', () async {
      final _FakeLlmEngine engine = _FakeLlmEngine()
        ..cannedDeltas = const <String>['ok'];
      final _FakeConnectivityProbe probe =
          _FakeConnectivityProbe(ConnectivityStatus.offline);
      final AiAssistantState state = build(
        engine: engine,
        retriever: _FakeContextRetriever(),
        downloader: _FakeModelDownloader(present: true),
        probe: probe,
      );

      await state.sendMessage('offline hello');

      expect(state.connectivity, ConnectivityStatus.offline);
      expect(state.generationStatus, GenerationStatus.idle);
      expect(state.messages.length, 2);
      expect(state.messages[1].role, ChatRole.assistant);
      expect(state.messages[1].text, 'ok');
    });
  });

  test(
    'sendMessage when model not ready: user turn stays, no assistant turn, no '
    'generation (Req 3.1)',
    () async {
      final _FakeLlmEngine engine = _FakeLlmEngine();
      final AiAssistantState state = build(
        engine: engine,
        retriever: _FakeContextRetriever(),
        downloader: _FakeModelDownloader(present: false),
        probe: _FakeConnectivityProbe(),
      );

      await state.sendMessage('will not generate');

      // The user turn is retained; no assistant turn was appended.
      expect(state.messages.length, 1);
      expect(state.messages[0].role, ChatRole.user);
      expect(state.messages[0].text, 'will not generate');
      // Model surfaced as absent (download prompt territory), no generation.
      expect(state.modelStatus, ModelStatus.absent);
      expect(state.generationStatus, GenerationStatus.idle);
      expect(engine.generateCount, 0);
    },
  );

  test('dispose disposes the engine and clears the conversation (Req 9.2, 8.3)',
      () async {
    final _FakeLlmEngine engine = _FakeLlmEngine()
      ..cannedDeltas = const <String>['hi'];
    final _FakeConnectivityProbe probe = _FakeConnectivityProbe();
    final AiAssistantState state = AiAssistantState(
      'project-1',
      engine: engine,
      retriever: _FakeContextRetriever(),
      downloader: _FakeModelDownloader(present: true),
      connectivityProbe: probe,
    );

    await state.sendMessage('hello');
    expect(state.messages, isNotEmpty);

    state.dispose();

    expect(engine.disposeCount, 1);
    expect(state.messages, isEmpty);
  });

  group('clearConversation ("New chat")', () {
    AiAssistantState buildWithRepo({
      required _FakeLlmEngine engine,
      required _FakeConversationRepository repo,
      bool modelPresent = true,
    }) {
      final AiAssistantState state = AiAssistantState(
        'project-1',
        engine: engine,
        retriever: _FakeContextRetriever(),
        downloader: _FakeModelDownloader(present: modelPresent),
        connectivityProbe: _FakeConnectivityProbe(),
        conversationRepository: repo,
      );
      addTearDown(state.dispose);
      return state;
    }

    test('clears messages and the persisted history', () async {
      final _FakeLlmEngine engine = _FakeLlmEngine()
        ..cannedDeltas = const <String>['hi ', 'there'];
      final _FakeConversationRepository repo = _FakeConversationRepository();
      final AiAssistantState state =
          buildWithRepo(engine: engine, repo: repo);

      await state.sendMessage('hello');
      await pumpEventQueue();
      expect(state.messages.length, 2);
      expect(repo.store['project-1'], hasLength(2));

      final _NotifyCounter counter = _NotifyCounter();
      state.addListener(counter.call);
      await state.clearConversation();

      expect(state.messages, isEmpty);
      expect(state.generationStatus, GenerationStatus.idle);
      expect(state.transientError, isNull);
      expect(counter.count, greaterThan(0));
      expect(repo.clearedProjects, <String>['project-1']);
      expect(repo.store['project-1'], isNull);
    });

    test('cancels an in-flight generation; late tokens are dropped', () async {
      final _FakeLlmEngine engine = _FakeLlmEngine()..useController = true;
      final _FakeConversationRepository repo = _FakeConversationRepository();
      final AiAssistantState state =
          buildWithRepo(engine: engine, repo: repo);

      final Future<void> pending = state.sendMessage('stream please');
      await pumpEventQueue();
      engine.controller.add('partial');
      await pumpEventQueue();
      expect(state.generationStatus, GenerationStatus.generating);

      await state.clearConversation();

      expect(engine.cancelCount, 1);
      expect(state.generationStatus, GenerationStatus.idle);
      expect(state.messages, isEmpty);

      // A late delta after the clear must not resurrect a turn.
      engine.controller.add(' late');
      await pumpEventQueue();
      expect(state.messages, isEmpty);

      await engine.controller.close();
      await pending;
      expect(repo.store['project-1'], isNull);
    });

    test('a repository failure keeps the in-memory clear and surfaces a '
        'non-blocking error', () async {
      final _FakeLlmEngine engine = _FakeLlmEngine()
        ..cannedDeltas = const <String>['ok'];
      final _FakeConversationRepository repo = _FakeConversationRepository()
        ..clearThrows = true;
      final AiAssistantState state =
          buildWithRepo(engine: engine, repo: repo);

      await state.sendMessage('hello');
      await state.clearConversation();

      expect(state.messages, isEmpty);
      expect(state.generationStatus, GenerationStatus.idle);
      expect(state.transientError, isNotNull);
      expect(repo.clearedProjects, <String>['project-1']);
    });

    test('an in-flight history load does not re-populate after a clear',
        () async {
      final _FakeConversationRepository repo = _FakeConversationRepository()
        ..store['project-1'] = <ChatMessage>[
          ChatMessage.user(text: 'old turn', timestamp: DateTime.utc(2024)),
        ]
        ..loadGate = Completer<void>();
      final AiAssistantState state = buildWithRepo(
        engine: _FakeLlmEngine(),
        repo: repo,
        modelPresent: false, // keep the send from generating
      );

      final Future<void> load = state.loadPersistedConversation();
      await state.sendMessage('new turn');
      await state.clearConversation();
      // The persisted turns were cleared; re-seed to prove the stale load
      // result itself is ignored, not merely empty.
      repo.store['project-1'] = <ChatMessage>[
        ChatMessage.user(text: 'old turn', timestamp: DateTime.utc(2024)),
      ];
      repo.loadGate!.complete();
      await load;

      expect(state.messages, isEmpty);
    });

    test('is a no-op when the conversation is already empty', () async {
      final _FakeConversationRepository repo = _FakeConversationRepository();
      final AiAssistantState state =
          buildWithRepo(engine: _FakeLlmEngine(), repo: repo);
      final _NotifyCounter counter = _NotifyCounter();
      state.addListener(counter.call);

      await state.clearConversation();

      expect(counter.count, 0);
      expect(repo.clearedProjects, isEmpty);
    });

    test('works without a repository (in-memory only)', () async {
      final AiAssistantState state = build(
        engine: _FakeLlmEngine()..cannedDeltas = const <String>['hi'],
        retriever: _FakeContextRetriever(),
        downloader: _FakeModelDownloader(present: true),
        probe: _FakeConnectivityProbe(),
      );
      await state.sendMessage('hello');
      await state.clearConversation();
      expect(state.messages, isEmpty);
      expect(state.transientError, isNull);
    });
  });
}
