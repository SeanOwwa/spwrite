// Widget tests for AiPanelView (task 7.6).
//
// Validates: Requirements 2, 4, 6
//
// These tests drive the real AiPanelView over a real AiAssistantState, with the
// same lightweight fakes the state's unit tests use for its four collaborators
// (LlmEngine, ContextRetriever, ModelDownloader, ConnectivityProbe). No real
// model, network, retrieval, or timers are involved — the panel is exercised
// deterministically through the state it observes via `provider`:
//
//   1. Conversation renders: with a ready model, a completed send shows both the
//      user turn and the assistant turn's text in the scrollable list (Req 2.2).
//   2. Send disabled while generating: mid-stream, the send control is replaced
//      by a stop control, so a new message cannot be sent until the reply
//      settles (Req 2.3, 2.6).
//   3. Offline banner: it shows only when connectivity is offline, and is absent
//      when online or unknown (Req 4.2, 4.4).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:spwrite/data/ai/model_downloader.dart';
import 'package:spwrite/domain/ai/chat_message.dart';
import 'package:spwrite/domain/ai/connectivity_probe.dart';
import 'package:spwrite/domain/ai/context_retriever.dart';
import 'package:spwrite/domain/ai/llm_engine.dart';
import 'package:spwrite/domain/ai/model_catalog.dart';
import 'package:spwrite/presentation/ai_panel_view.dart';
import 'package:spwrite/state/ai_assistant_state.dart';

// ---------------------------------------------------------------------------
// Fakes — mirror the collaborators used by the state's own unit tests so the
// panel is driven by real AiAssistantState behaviour with no external effects.
// ---------------------------------------------------------------------------

/// A fake [LlmEngine]. When [useController] is true, generate() returns a
/// test-driven stream so a test can observe the mid-stream `generating` state;
/// otherwise it replays [cannedDeltas] and closes on its own. It records how
/// many times generate()/cancel() were called.
class _FakeLlmEngine implements LlmEngine {
  List<String> cannedDeltas = const <String>[];
  bool useController = false;
  final StreamController<String> controller =
      StreamController<String>.broadcast();

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
    if (useController) return controller.stream;
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

/// A fake [ContextRetriever] returning canned passages; records queries so a
/// test can assert whether retrieval ran.
class _FakeContextRetriever implements ContextRetriever {
  List<RetrievedPassage> passages = const <RetrievedPassage>[];
  bool hasMaterial = true;
  final List<String> queries = <String>[];

  @override
  Future<List<RetrievedPassage>> retrieve(String query) async {
    queries.add(query);
    return passages;
  }

  @override
  Future<bool> hasProjectMaterial() async => hasMaterial;
}

/// A fake [ModelDownloader] — the state takes it by concrete type, so subclass
/// it and override only the two members the panel path touches. Its base
/// resolver is never invoked because both overrides short-circuit.
class _FakeModelDownloader extends ModelDownloader {
  _FakeModelDownloader({this.present = true})
      : super(directoryResolver: _neverResolve);

  bool present;
  int isPresentCount = 0;
  int downloadCount = 0;

  /// When set, download() awaits this before completing, so a test can hold the
  /// transfer "in flight" (e.g. to drive the stall UI) and finish it on demand.
  Completer<void>? gate;

  /// Progress steps emitted synchronously at the start of download().
  List<(int, int?)> progressSteps = const <(int, int?)>[];

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
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    present = true;
    return 'fake/cache/${model.id}.gguf';
  }
}

/// A fake [ConnectivityProbe] whose value can be set (notifying listeners) to
/// drive the offline banner on/off.
class _FakeConnectivityProbe extends ChangeNotifier
    implements ConnectivityProbe {
  _FakeConnectivityProbe([this._value = ConnectivityStatus.unknown]);

  ConnectivityStatus _value;
  int startCount = 0;

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
}

void main() {
  // Builds an AiAssistantState over the given fakes, registering disposal.
  AiAssistantState buildState({
    required _FakeLlmEngine engine,
    _FakeContextRetriever? retriever,
    _FakeModelDownloader? downloader,
    _FakeConnectivityProbe? probe,
  }) {
    final AiAssistantState state = AiAssistantState(
      'project-1',
      engine: engine,
      retriever: retriever ?? _FakeContextRetriever(),
      downloader: downloader ?? _FakeModelDownloader(present: true),
      connectivityProbe: probe ?? _FakeConnectivityProbe(),
    );
    addTearDown(state.dispose);
    return state;
  }

  // Pumps the panel wrapped in the minimal MaterialApp scaffolding it needs,
  // providing the state via provider exactly as the editor host does.
  Future<void> pumpPanel(
    WidgetTester tester,
    AiAssistantState state, {
    VoidCallback? onClose,
  }) async {
    // Use a realistically tall surface so the modal bottom sheet (which the app
    // shows over a full-height window) has room to lay out its content; the
    // panel itself is width-constrained to its hosted 320px below.
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider<AiAssistantState>.value(
            value: state,
            child: SizedBox(
              // The panel is hosted at a fixed 320px in the editor
              // (_characterPanelWidth), so exercise it at that real width.
              width: 320,
              height: 720,
              child: AiPanelView(onClose: onClose ?? () {}),
            ),
          ),
        ),
      ),
    );
    // Let the one-shot post-frame ensureModelReady probe run and settle.
    await tester.pumpAndSettle();
  }

  testWidgets(
    'conversation renders: user and assistant turns appear (Req 2.2)',
    (WidgetTester tester) async {
      final _FakeLlmEngine engine = _FakeLlmEngine()
        ..cannedDeltas = const <String>['Hello ', 'there'];
      final AiAssistantState state = buildState(engine: engine);
      await pumpPanel(tester, state);

      // The model probes to ready, so the empty-state prompt is shown first.
      expect(state.modelStatus, ModelStatus.ready);

      // Send a message; the canned stream completes on its own.
      await state.sendMessage('Tell me about Aria');
      await tester.pumpAndSettle();

      // Both turns render in the conversation list.
      expect(find.text('Tell me about Aria'), findsOneWidget);
      expect(find.text('Hello there'), findsOneWidget);
      expect(state.generationStatus, GenerationStatus.idle);
    },
  );

  testWidgets(
    'send is disabled (replaced by stop) while generating (Req 2.3, 2.6)',
    (WidgetTester tester) async {
      final _FakeLlmEngine engine = _FakeLlmEngine()..useController = true;
      final AiAssistantState state = buildState(engine: engine);
      await pumpPanel(tester, state);

      // Idle: the send control is present, the stop control is not.
      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsNothing);

      // Start a generation and drive it into the streaming state.
      final Future<void> pending = state.sendMessage('stream please');
      await tester.pump(); // process the state's async prelude + notify
      await tester.pump();

      expect(state.generationStatus, GenerationStatus.generating);

      // While generating the send control is gone and a stop control shows —
      // so a new message cannot be sent until the reply settles (Req 2.3).
      expect(find.byIcon(Icons.send), findsNothing);
      expect(find.byIcon(Icons.stop), findsOneWidget);

      // Settle the stream so the pending send completes and input re-enables.
      await engine.controller.close();
      await pending;
      await tester.pumpAndSettle();

      expect(state.generationStatus, GenerationStatus.idle);
      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsNothing);
    },
  );

  group('"New chat" control', () {
    Finder newChatButton() => find.widgetWithIcon(
          IconButton,
          Icons.add_comment_outlined,
        );

    testWidgets('is disabled while the conversation is empty', (
      WidgetTester tester,
    ) async {
      final AiAssistantState state = buildState(engine: _FakeLlmEngine());
      await pumpPanel(tester, state);

      expect(find.byTooltip('New chat'), findsOneWidget);
      expect(tester.widget<IconButton>(newChatButton()).onPressed, isNull);
    });

    testWidgets('confirming the dialog clears the conversation', (
      WidgetTester tester,
    ) async {
      final _FakeLlmEngine engine = _FakeLlmEngine()
        ..cannedDeltas = const <String>['Hi there'];
      final AiAssistantState state = buildState(engine: engine);
      await pumpPanel(tester, state);
      await state.sendMessage('hello');
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(newChatButton()).onPressed, isNotNull);

      await tester.tap(newChatButton());
      await tester.pumpAndSettle();
      expect(find.text('Start a new chat?'), findsOneWidget);
      expect(find.text('This clears the current conversation.'),
          findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Clear'));
      await tester.pumpAndSettle();

      expect(find.text('Start a new chat?'), findsNothing);
      expect(state.messages, isEmpty);
      expect(find.text('hello'), findsNothing);
      expect(find.text('Hi there'), findsNothing);
      expect(tester.widget<IconButton>(newChatButton()).onPressed, isNull);
    });

    testWidgets('cancelling the dialog keeps the conversation', (
      WidgetTester tester,
    ) async {
      final _FakeLlmEngine engine = _FakeLlmEngine()
        ..cannedDeltas = const <String>['Hi there'];
      final AiAssistantState state = buildState(engine: engine);
      await pumpPanel(tester, state);
      await state.sendMessage('hello');
      await tester.pumpAndSettle();

      await tester.tap(newChatButton());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Start a new chat?'), findsNothing);
      expect(state.messages.length, 2);
      expect(find.text('hello'), findsOneWidget);
      expect(find.text('Hi there'), findsOneWidget);
    });
  });

  group('offline banner (Req 4.2, 4.4)', () {
    const String bannerText =
        "You're offline — internet search is unavailable. Chat and "
        'project search still work.';

    testWidgets('shows when connectivity is offline', (
      WidgetTester tester,
    ) async {
      final AiAssistantState state = buildState(
        engine: _FakeLlmEngine(),
        probe: _FakeConnectivityProbe(ConnectivityStatus.offline),
      );
      await pumpPanel(tester, state);

      expect(find.text(bannerText), findsOneWidget);
    });

    testWidgets('is absent when online', (WidgetTester tester) async {
      final AiAssistantState state = buildState(
        engine: _FakeLlmEngine(),
        probe: _FakeConnectivityProbe(ConnectivityStatus.online),
      );
      await pumpPanel(tester, state);

      expect(find.text(bannerText), findsNothing);
    });

    testWidgets('is absent when connectivity is unknown', (
      WidgetTester tester,
    ) async {
      final AiAssistantState state = buildState(
        engine: _FakeLlmEngine(),
        probe: _FakeConnectivityProbe(ConnectivityStatus.unknown),
      );
      await pumpPanel(tester, state);

      expect(find.text(bannerText), findsNothing);
    });

    testWidgets('appears live when the probe transitions to offline', (
      WidgetTester tester,
    ) async {
      final _FakeConnectivityProbe probe =
          _FakeConnectivityProbe(ConnectivityStatus.online);
      final AiAssistantState state =
          buildState(engine: _FakeLlmEngine(), probe: probe);
      await pumpPanel(tester, state);

      expect(find.text(bannerText), findsNothing);

      probe.value = ConnectivityStatus.offline;
      await tester.pumpAndSettle();

      expect(find.text(bannerText), findsOneWidget);
    });
  });

  group('download surface (Req 3.2, 3.4)', () {
    testWidgets(
      'shows the byte-count progress label while downloading',
      (WidgetTester tester) async {
        final Completer<void> gate = Completer<void>();
        final _FakeModelDownloader downloader = _FakeModelDownloader(
          present: false,
        )
          ..gate = gate
          ..progressSteps = const <(int, int?)>[(500000000, 1000000000)];
        final AiAssistantState state = buildState(
          engine: _FakeLlmEngine(),
          downloader: downloader,
        );
        // The model probes to absent (download prompt); start the download.
        await pumpPanel(tester, state);
        expect(state.modelStatus, ModelStatus.absent);

        // Kick off the (gated) download and let the initial progress step flow.
        unawaited(state.downloadModel());
        await tester.pump();
        await tester.pump();

        // The downloading surface shows a human-readable "X of Y" byte hint.
        expect(state.modelStatus, ModelStatus.downloading);
        expect(
          find.textContaining('of', findRichText: true),
          findsWidgets,
        );
        expect(find.textContaining('Receiving data'), findsOneWidget);

        // Release the gate so no pending timer/future is left dangling.
        gate.complete();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'surfaces a stalled warning and Retry once the stall threshold elapses '
      '(Req 3.4)',
      (WidgetTester tester) async {
        final Completer<void> gate = Completer<void>();
        final _FakeModelDownloader downloader = _FakeModelDownloader(
          present: false,
        )
          ..gate = gate
          ..progressSteps = const <(int, int?)>[(100, 1000)];
        final AiAssistantState state = buildState(
          engine: _FakeLlmEngine(),
          downloader: downloader,
        );
        await pumpPanel(tester, state);

        unawaited(state.downloadModel());
        await tester.pump();
        await tester.pump();
        expect(state.downloadActivity, DownloadActivity.active);

        // Advance the (widget-test fake) clock past the stall threshold so the
        // stall ticker fires and the surface flips to the warning.
        await tester.pump(
          AiAssistantState.stallThreshold + const Duration(seconds: 2),
        );

        expect(state.downloadActivity, DownloadActivity.stalled);
        expect(find.text('Retry download'), findsOneWidget);
        expect(
          find.textContaining('stuck', findRichText: true),
          findsWidgets,
        );

        // Finish the download to clear timers/futures.
        gate.complete();
        await tester.pumpAndSettle();
      },
    );
  });
}
