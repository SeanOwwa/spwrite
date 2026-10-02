/// State layer: [AiAssistantState], the single source of truth for the AI Panel
/// of an open project.
///
/// It owns the open project's in-memory conversation (the ordered list of
/// [ChatMessage]s), the generation lifecycle ([GenerationStatus]), the Local
/// Model's readiness ([ModelStatus] plus a download-progress fraction), and a
/// live connectivity hint ([ConnectivityStatus]) — everything the AI Panel and
/// its download / offline surfaces observe via `provider` (Req 2, 3, 4). Like
/// the other notifiers, it depends only on domain abstractions ([LlmEngine],
/// [ContextRetriever], [ConnectivityProbe]) and the data-layer [ModelDownloader]
/// — never on the concrete on-device runtime or the network directly.
///
/// It is scoped to one project, mirroring [CharacterPanelState]: constructed
/// with the Active_Project's id when a project is opened, and disposed when the
/// project is closed. The conversation lives for the project session (Req 9.1)
/// and is cleared on dispose (Req 9.2). Model loading and generation run off the
/// UI thread inside the injected [LlmEngine] (Req 8.1), the model loads lazily on
/// first use rather than at startup (Req 8.2), and it is released on dispose
/// (Req 8.3).
///
/// This file (task 6.1) establishes the class shape — the status enums, the
/// observable fields with unmodifiable/read-only getters, the injected
/// collaborators, the connectivity subscription, and disposal. The behavioural
/// methods ([ensureModelReady], [sendMessage], [cancelGeneration]) are declared
/// as stubs here and implemented in tasks 6.2–6.4.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/ai/model_downloader.dart';
import '../domain/ai/ai_conversation_repository.dart';
import '../domain/ai/chat_message.dart';
import '../domain/ai/connectivity_probe.dart';
import '../domain/ai/context_retriever.dart';
import '../domain/ai/llm_engine.dart';
import '../domain/ai/model_catalog.dart';

/// Lifecycle of an assistant reply generation, driving the typing indicator and
/// the input enable/disable in the AI Panel (Req 2.3, 2.5).
enum GenerationStatus {
  /// No generation is in flight; the input is enabled and ready for a new
  /// message.
  idle,

  /// A reply is currently streaming from the Local Model; the panel shows a
  /// typing indicator and disables send (Req 2.3, 2.4).
  generating,

  /// The most recent generation failed; a recoverable error is surfaced while
  /// the prior conversation is retained (Req 2.5).
  error,
}

/// Readiness of the Local Model (the GGUF Model Asset) that backs the assistant
/// (Req 3).
///
/// The design describes this conceptually as `absent | downloading(progress) |
/// ready | failed`; the progress fraction is carried alongside as
/// [AiAssistantState.downloadProgress] (mirroring the flat-enum style of
/// [LoadStatus] and keeping the value observable without a payload-carrying
/// enum).
enum ModelStatus {
  /// The Model Asset is not cached on disk; the panel surfaces the one-time
  /// download prompt (Req 3.1).
  absent,

  /// The Model Asset is being downloaded; [AiAssistantState.downloadProgress]
  /// reports how far along it is (Req 3.2).
  downloading,

  /// The Model Asset is cached, verified, and ready to load / generate
  /// (Req 3.5, 3.6).
  ready,

  /// The one-time download (or a load) failed; a recoverable error is surfaced
  /// and the app stays usable without the assistant (Req 3.4, 3.5).
  failed,
}

/// Whether an in-flight one-time download currently looks like it is making
/// progress, so the panel can reassure the writer it is still working — or warn
/// that it appears stuck (Req 3.2, 3.4).
///
/// This is derived from how recently the downloader reported new bytes: if
/// bytes have arrived within [AiAssistantState.stallThreshold] the download is
/// [active]; once that long passes with no new bytes it is [stalled] and the
/// panel surfaces a "seems stuck — check your connection" hint with a retry.
enum DownloadActivity {
  /// No download is in flight (or it has not started reporting yet).
  idle,

  /// Bytes arrived recently — the download is visibly progressing.
  active,

  /// No new bytes for a while — the download appears stuck (e.g. the
  /// connection dropped mid-transfer). Purely informational; the transfer is
  /// not aborted, but the panel offers a retry (Req 3.4).
  stalled,
}

/// The single source of truth the AI Panel observes while a project is open.
/// Owns the project's conversation, the generation and model-readiness status
/// (plus download progress), a connectivity hint, and a transient error.
class AiAssistantState extends ChangeNotifier {
  /// The id of the project whose assistant conversation this manages.
  final String projectId;

  /// The Local Model runtime abstraction. The state layer talks only to this
  /// interface, keeping it decoupled from the embedded inference engine
  /// (Req 8.1). Its lifecycle is owned here: it is disposed when this state is
  /// disposed (Req 8.3).
  final LlmEngine _engine;

  /// Offline Project-Context retrieval abstraction, used to ground replies in
  /// the writer's own material (Req 5.1, 5.2). Consumed by [sendMessage].
  final ContextRetriever _retriever;

  /// The one-time Model Asset downloader (a concrete data-layer collaborator; it
  /// has no domain abstraction). Drives the download-with-progress flow and the
  /// "already present" fast-path (Req 3). Consumed by [ensureModelReady] /
  /// [downloadModel] (task 6.2).
  final ModelDownloader _downloader;

  /// Live connectivity detection. Exposed as a [ValueListenable]; this state
  /// mirrors its [ConnectivityProbe.value] into [connectivity] via a listener
  /// (Req 4.1, 4.5).
  final ConnectivityProbe _connectivityProbe;

  /// The Model Asset this assistant downloads / loads. Defaults to
  /// [ModelCatalog.defaultModel]; injectable for tests.
  final ModelMetadata _model;

  /// OPTIONAL project-scoped conversation persistence (Req 9.3). When `null`
  /// (the default), cross-launch persistence is disabled and the conversation
  /// lives only in memory — behaviour is exactly as before this was added, so
  /// callers and tests that don't supply a repository are unaffected.
  ///
  /// When present, [loadPersistedConversation] replays the stored turns on
  /// panel open, and each completed turn (the user turn and the finished
  /// assistant reply) is appended best-effort. A persistence failure never
  /// breaks the conversation or generation — Req 9.3 makes this feature
  /// optional, so persistence is swallowed on error to keep chat functional.
  final AiConversationRepository? _conversationRepository;

  /// Guards [loadPersistedConversation] so the one-time replay runs at most
  /// once per state, even if the panel's init fires more than once.
  bool _persistedLoadStarted = false;

  /// Bumped by [clearConversation]. Async work that started before a clear
  /// (the persisted-history replay, a send still in its prelude, a queued
  /// persistence append) captures the epoch and bails if it changed, so a
  /// cleared conversation is never re-populated by late results.
  int _conversationEpoch = 0;

  /// Tail of the serialized persistence queue. Appends are chained onto it so
  /// [clearConversation] can wait for already-queued writes to land before it
  /// clears the store — otherwise a late append could resurrect a cleared turn.
  Future<void> _pendingPersist = Future<void>.value();

  /// The conversation, oldest first (Req 2.2, 2.7).
  List<ChatMessage> _messages = <ChatMessage>[];

  /// The current generation lifecycle status. Reassigned as generation runs
  /// (tasks 6.3/6.4).
  GenerationStatus _generationStatus = GenerationStatus.idle;

  /// The current Local Model readiness. Reassigned by [ensureModelReady] /
  /// [downloadModel] (task 6.2).
  ModelStatus _modelStatus = ModelStatus.absent;

  /// One-time download progress as a fraction in `[0, 1]`, meaningful while
  /// [modelStatus] is [ModelStatus.downloading]; `0.0` otherwise (Req 3.2).
  /// Updated during the download (task 6.2).
  double _downloadProgress = 0.0;

  /// Bytes received so far in the in-flight download, for a human-readable
  /// "X of Y" hint (Req 3.2). Meaningful only while [ModelStatus.downloading].
  int _downloadReceivedBytes = 0;

  /// Expected total bytes for the in-flight download, or `null` when the server
  /// did not report a size. Backs the "X of Y" hint (Req 3.2).
  int? _downloadTotalBytes;

  /// How many stall-ticks have elapsed since the downloader last reported new
  /// bytes. Reset to 0 on every byte callback and incremented on each
  /// [_stallTick]; once it reaches [_stallTicksToStall] the download is treated
  /// as stalled (Req 3.2, 3.4). Counting ticks (rather than diffing the wall
  /// clock) keeps the behaviour deterministic and testable under fake timers.
  int _ticksSinceProgress = 0;

  /// Whether the in-flight download currently looks stalled (no new bytes for
  /// [stallThreshold]). Recomputed by [_stallTicker]. Mirrored to observers via
  /// [downloadActivity].
  bool _downloadStalled = false;

  /// Periodic ticker that re-evaluates the stall state while downloading, so
  /// the "seems stuck" hint can appear even though — by definition — no new
  /// byte callback is arriving to trigger a rebuild. `null` when not downloading.
  Timer? _stallTicker;

  /// The latest connectivity hint, mirrored from [_connectivityProbe] (Req 4.1).
  ConnectivityStatus _connectivity = ConnectivityStatus.unknown;

  /// A recoverable message surfaced to the user, or `null` when there is
  /// nothing to show (Req 2.5, 3.5).
  String? _transientError;

  /// Whether the connectivity listener is still registered on the probe, so
  /// [dispose] removes it exactly once.
  bool _connectivitySubscribed = false;

  /// The subscription to the in-flight [LlmEngine.generate] stream, or `null`
  /// when no generation is running. Held so [cancelGeneration] (task 6.4) can
  /// tear down the active stream, and so [sendMessage] can guard against deltas
  /// arriving after cancellation/disposal.
  StreamSubscription<String>? _generationSub;

  /// Index into [_messages] of the assistant turn currently being streamed
  /// into, or `null` when no reply is streaming. Deltas from [_generationSub]
  /// accumulate into this message.
  int? _streamingIndex;

  /// Completes when the in-flight [sendMessage] settles (stream done/error), or
  /// `null` when no generation is running. Held so [cancelGeneration] and
  /// [dispose] can complete the awaiting [sendMessage] future when they tear
  /// down the subscription — cancelling a subscription suppresses its
  /// `onDone`/`onError`, so without this the [sendMessage] future would hang.
  Completer<void>? _generationDone;

  /// Set once [dispose] runs, so any late deltas from an outstanding
  /// generation stream are ignored rather than mutating a disposed notifier.
  bool _disposed = false;

  /// How many recent conversation turns (excluding the just-appended user turn)
  /// to pass to the engine as history, keeping the prompt within the model's
  /// context window. The engine truncates further if needed.
  static const int _historyWindow = 10;

  /// Caps the streamed reply length so a runaway generation cannot grow the
  /// conversation without bound; the engine applies its own default otherwise.
  static const int _maxReplyTokens = 4096;

  /// Creates the assistant state for [projectId] over the injected
  /// collaborators. [model] defaults to [ModelCatalog.defaultModel]; inject a
  /// different [ModelMetadata] in tests.
  ///
  /// Subscribes to [connectivityProbe] to mirror its value into [connectivity]
  /// and starts the probe (Req 4.5). Construction stays cheap — the model is
  /// loaded lazily on first use, not here (Req 8.2).
  AiAssistantState(
    this.projectId, {
    required LlmEngine engine,
    required ContextRetriever retriever,
    required ModelDownloader downloader,
    required ConnectivityProbe connectivityProbe,
    ModelMetadata model = ModelCatalog.defaultModel,
    AiConversationRepository? conversationRepository,
  })  : _engine = engine,
        _retriever = retriever,
        _downloader = downloader,
        _connectivityProbe = connectivityProbe,
        _model = model,
        _conversationRepository = conversationRepository {
    _connectivity = _connectivityProbe.value;
    _connectivityProbe.addListener(_onConnectivityChanged);
    _connectivitySubscribed = true;
    _connectivityProbe.start();
  }

  /// The conversation in order (oldest first), as an unmodifiable view
  /// (Req 2.2, 2.7).
  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);

  /// The current generation lifecycle status (Req 2.3, 2.5).
  GenerationStatus get generationStatus => _generationStatus;

  /// The current Local Model readiness (Req 3).
  ModelStatus get modelStatus => _modelStatus;

  /// One-time download progress as a fraction in `[0, 1]` (Req 3.2).
  double get downloadProgress => _downloadProgress;

  /// How long the download may go without any new bytes before it is treated
  /// as [DownloadActivity.stalled] (Req 3.2, 3.4).
  static const Duration stallThreshold = Duration(seconds: 15);

  /// How often the stall state is re-evaluated while a download is in flight.
  static const Duration _stallTick = Duration(seconds: 1);

  /// Number of [_stallTick]s with no new bytes before the download is treated
  /// as stalled ([stallThreshold] expressed in ticks).
  static int get _stallTicksToStall =>
      stallThreshold.inMilliseconds ~/ _stallTick.inMilliseconds;

  /// Bytes received so far in the in-flight download (Req 3.2).
  int get downloadReceivedBytes => _downloadReceivedBytes;

  /// Expected total bytes for the in-flight download, or `null` when unknown
  /// (the server omitted a size) (Req 3.2).
  int? get downloadTotalBytes => _downloadTotalBytes;

  /// Whether the in-flight download is idle, actively progressing, or appears
  /// stalled, so the panel can reassure the writer or warn that it looks stuck
  /// (Req 3.2, 3.4). Only meaningful while [modelStatus] is
  /// [ModelStatus.downloading]; reports [DownloadActivity.idle] otherwise.
  DownloadActivity get downloadActivity {
    if (_modelStatus != ModelStatus.downloading) return DownloadActivity.idle;
    return _downloadStalled ? DownloadActivity.stalled : DownloadActivity.active;
  }

  /// The latest connectivity hint (Req 4.1).
  ConnectivityStatus get connectivity => _connectivity;

  /// The pending transient error message, or `null` (Req 2.5, 3.5).
  String? get transientError => _transientError;

  /// The Model Asset this assistant manages.
  ModelMetadata get model => _model;

  /// Whether the conversation currently has no messages.
  bool get isEmpty => _messages.isEmpty;

  /// Clears the transient error so it is not shown again on the next rebuild.
  void clearTransientError() {
    if (_transientError == null) return;
    _transientError = null;
    notifyListeners();
  }

  /// OPTIONALLY replays the project's persisted conversation into [messages]
  /// when a [AiConversationRepository] was injected (Req 9.3).
  ///
  /// The AI Panel calls this once when it first opens (alongside its one-shot
  /// [ensureModelReady] probe). When no repository is present this is a no-op,
  /// so persistence stays entirely opt-in and in-memory-only behaviour is
  /// preserved. It runs at most once per state (guarded by
  /// [_persistedLoadStarted]) and only loads into an empty conversation, so a
  /// late replay can never clobber turns the writer has already produced this
  /// session.
  ///
  /// Loading is best-effort: a repository failure is swallowed (the panel keeps
  /// its in-memory conversation and stays fully usable), consistent with Req
  /// 9.3 making cross-launch persistence optional.
  Future<void> loadPersistedConversation() async {
    final AiConversationRepository? repo = _conversationRepository;
    if (repo == null) return; // Persistence disabled: in-memory only.
    if (_persistedLoadStarted) return; // Replay once per state.
    _persistedLoadStarted = true;
    final int epoch = _conversationEpoch;

    try {
      final List<ChatMessage> stored = await repo.getAllForProject(projectId);
      if (_disposed) return;
      // The writer started a new chat while the load was in flight: the
      // replayed history is stale and must not re-populate the cleared list.
      if (epoch != _conversationEpoch) return;
      // Only seed an empty conversation; never overwrite turns already produced
      // this session (e.g. if the writer sent a message before the load
      // resolved).
      if (stored.isEmpty || _messages.isNotEmpty) return;
      _messages = List<ChatMessage>.of(stored);
      notifyListeners();
    } catch (_) {
      // Swallow: persistence is optional and must never break the panel.
    }
  }

  /// Best-effort append of [message] to the persisted conversation, when a
  /// repository is present (Req 9.3). A failure is swallowed so a persistence
  /// error never interrupts the live conversation or generation.
  ///
  /// Appends are serialized through [_pendingPersist] so [clearConversation]
  /// can await outstanding writes, and an append queued before a clear is
  /// skipped if the conversation was cleared before it ran.
  Future<void> _persistTurn(ChatMessage message) {
    final AiConversationRepository? repo = _conversationRepository;
    if (repo == null) return Future<void>.value();
    final int epoch = _conversationEpoch;
    final Future<void> next = _pendingPersist.then((_) async {
      if (epoch != _conversationEpoch) return; // Cleared since enqueue.
      try {
        await repo.append(projectId, message);
      } catch (_) {
        // Swallow: optional persistence, keep chat functional (Req 9.3).
      }
    });
    _pendingPersist = next;
    return next;
  }

  /// Clears the current conversation so the assistant starts fresh ("New
  /// chat").
  ///
  /// Cancels any in-flight generation first (via [cancelGeneration]) so no
  /// late tokens land in the cleared list, then empties [messages], clears
  /// [transientError], and settles [generationStatus] to idle. When a
  /// conversation repository is present, the persisted history is also cleared
  /// so a relaunch does not replay the old conversation; if that fails, the
  /// in-memory clear stands and a non-blocking [transientError] is surfaced.
  ///
  /// A no-op when the conversation is already empty (and nothing is
  /// generating) or the state has been disposed.
  Future<void> clearConversation() async {
    if (_disposed) return;
    final bool inFlight = _generationStatus == GenerationStatus.generating ||
        _generationSub != null;
    if (_messages.isEmpty && !inFlight) return;

    if (inFlight) cancelGeneration();

    // Invalidate any async work started against the old conversation (the
    // initial history replay, a send still in its prelude, queued appends),
    // and make sure a not-yet-started replay never runs afterwards.
    _conversationEpoch += 1;
    _persistedLoadStarted = true;

    _messages = <ChatMessage>[];
    _streamingIndex = null;
    _transientError = null;
    _generationStatus = GenerationStatus.idle;
    notifyListeners();

    final AiConversationRepository? repo = _conversationRepository;
    if (repo == null) return; // In-memory only: nothing persisted to clear.
    try {
      // Let already-queued appends land first so they are cleared too.
      await _pendingPersist;
      await repo.clearForProject(projectId);
    } catch (_) {
      if (_disposed) return;
      _transientError =
          "The chat was cleared, but its saved history couldn't be removed. "
          'It may reappear the next time you open this project.';
      notifyListeners();
    }
  }

  /// Mirrors the probe's latest [ConnectivityStatus] into [connectivity],
  /// notifying observers only when it actually changes (Req 4.5).
  void _onConnectivityChanged() {
    final ConnectivityStatus next = _connectivityProbe.value;
    if (next == _connectivity) return;
    _connectivity = next;
    notifyListeners();
  }

  /// Brings the Local Model to a known readiness **without touching the
  /// network**, so the AI Panel can decide what to show (Req 3.1, 3.6).
  ///
  /// This is the fast, side-effect-light half of the download flow. It resolves
  /// [modelStatus] to one of two terminal-for-now states:
  /// - [ModelStatus.ready] when the asset is already cached on disk — the
  ///   assistant starts fully offline, no prompt, no download (Req 3.6); or
  /// - [ModelStatus.absent] when the asset is not present — surfacing the
  ///   one-time download prompt that Req 3.1 calls for.
  ///
  /// It deliberately does **not** start the download itself: Req 3.1 says to
  /// *prompt* the user, and Req 3.2 only downloads *WHEN the user confirms*. The
  /// actual confirm-then-download-with-progress step lives in [downloadModel],
  /// which the AI Panel (task 7.3) calls after the user accepts the prompt.
  /// [sendMessage] (task 6.3) calls this first and reacts to [modelStatus]:
  /// generate when `ready`, otherwise surface the prompt rather than block.
  ///
  /// Idempotent: if the model is already [ModelStatus.ready] this returns
  /// immediately. A prior [ModelStatus.failed] is re-probed here, so a fixed
  /// environment (e.g. the file was placed on disk out-of-band) recovers.
  Future<void> ensureModelReady() async {
    if (_modelStatus == ModelStatus.ready) return;

    // Fast-path (Req 3.6): a cached, previously-verified asset means the
    // assistant can start with no network access. The final file only ever
    // appears via the downloader's verified atomic rename, so presence implies
    // a good asset — we trust it rather than re-hash a ~1 GB file on each use.
    final bool present = await _downloader.isModelPresent(_model);
    if (present) {
      _modelStatus = ModelStatus.ready;
      _transientError = null;
      notifyListeners();
      return;
    }

    // Absent: surface the one-time download prompt (Req 3.1). The download
    // itself waits for the user's confirmation via [downloadModel] (Req 3.2).
    if (_modelStatus != ModelStatus.absent) {
      _modelStatus = ModelStatus.absent;
      _downloadProgress = 0.0;
      notifyListeners();
    }
  }

  /// Performs the one-time, confirm-gated download of the Model Asset with
  /// progress, verifying integrity before marking the model ready and keeping
  /// the app usable if the device is offline (Req 3.2–3.5, 3.7).
  ///
  /// Call this only after the user has confirmed the prompt surfaced by
  /// [ensureModelReady] (Req 3.1 → 3.2). It:
  /// - moves [modelStatus] to [ModelStatus.downloading] and drives
  ///   [downloadProgress] from the downloader's byte-level callback (Req 3.2);
  /// - on success, relies on the downloader having verified the sha256 before
  ///   accepting the file (Req 3.5) and marks the model [ModelStatus.ready] —
  ///   after which chat/retrieval never need the network again (Req 3.3);
  /// - on failure, settles into [ModelStatus.failed] with a [transientError]
  ///   message and **never throws out of this method**, so the rest of the app
  ///   stays usable without the assistant (Req 3.4). An offline failure gets the
  ///   downloader's "needs an internet connection" wording; other failures get a
  ///   plain retry message (Req 3.4 vs 3.5). No partial asset is left behind —
  ///   the downloader cleans up its temp file — so a later retry is safe
  ///   (Req 3.5, 3.7).
  ///
  /// A concurrent call while already [ModelStatus.downloading] is ignored, and a
  /// call once [ModelStatus.ready] returns immediately, so an accidental double
  /// confirm cannot start two downloads.
  Future<void> downloadModel() async {
    if (_modelStatus == ModelStatus.ready) return;
    if (_modelStatus == ModelStatus.downloading) return;

    _modelStatus = ModelStatus.downloading;
    _downloadProgress = 0.0;
    _downloadReceivedBytes = 0;
    _downloadTotalBytes = null;
    _downloadStalled = false;
    // Reset the activity counter so a download that never reports a byte still
    // trips the stall detector after [stallThreshold] (Req 3.4).
    _ticksSinceProgress = 0;
    _transientError = null;
    _startStallTicker();
    notifyListeners();

    try {
      await _downloader.download(
        _model,
        onProgress: (int received, int? total) {
          // Any byte callback — even one below the notify threshold, or with an
          // unknown total — is evidence the transfer is alive, so record the
          // activity time and clear a prior stall so the "seems stuck" hint
          // clears the moment bytes resume (Req 3.2, 3.4).
          _downloadReceivedBytes = received;
          if (total != null && total > 0) _downloadTotalBytes = total;
          _ticksSinceProgress = 0;
          final bool wasStalled = _downloadStalled;
          _downloadStalled = false;

          // When the total is unknown for a callback (the server omitted a
          // Content-Length), keep the last known fraction rather than snapping
          // the bar back to 0 — otherwise the indicator would flip between a
          // determinate position and the indeterminate sweep, reading as the
          // bar going "back and forth" (Req 3.2).
          if (total == null || total <= 0) {
            // No fraction to advance, but if we just recovered from a stall the
            // panel should update to drop the warning.
            if (wasStalled) notifyListeners();
            return;
          }

          // Progress is monotonic: never let a late/out-of-order callback move
          // the bar backwards. Clamp to [0, 1] and only ever advance.
          final double fraction = (received / total).clamp(0.0, 1.0);
          if (fraction <= _downloadProgress) {
            // Fraction didn't advance, but recovering from a stall still merits
            // a rebuild to clear the warning.
            if (wasStalled) notifyListeners();
            return;
          }

          // Only notify on a meaningful advance so a flood of byte-level
          // callbacks doesn't rebuild the panel on every chunk (Req 3.2); a
          // sub-threshold advance still updates the stored value so the next
          // notify reflects true progress, but never regresses it. Recovering
          // from a stall forces a notify regardless so the warning clears.
          if ((fraction - _downloadProgress) >= 0.01 ||
              fraction >= 1.0 ||
              wasStalled) {
            _downloadProgress = fraction;
            notifyListeners();
          } else {
            _downloadProgress = fraction;
          }
        },
      );

      // The downloader verified the sha256 before accepting the file (Req 3.5),
      // so a returned path means a complete, integrity-checked asset.
      _stopStallTicker();
      _downloadStalled = false;
      _modelStatus = ModelStatus.ready;
      _downloadProgress = 1.0;
      _transientError = null;
      notifyListeners();
    } on ModelDownloadException catch (error) {
      // A failed download must not tear down the app: settle into `failed` with
      // a message and keep everything else usable (Req 3.4). Offline vs. other
      // failures are already worded differently by the downloader; surface its
      // message verbatim so the panel can offer the right affordance (Req 3.4,
      // 3.5). No partial asset remains — the downloader removed its temp file.
      _stopStallTicker();
      _downloadStalled = false;
      _modelStatus = ModelStatus.failed;
      _downloadProgress = 0.0;
      _transientError = error.message;
      notifyListeners();
    } catch (error) {
      // Any other failure (unexpected I/O, etc.): a plain, recoverable retry
      // message; the asset is not marked ready, so nothing loads a bad file
      // (Req 3.5).
      _stopStallTicker();
      _downloadStalled = false;
      _modelStatus = ModelStatus.failed;
      _downloadProgress = 0.0;
      _transientError =
          'The one-time model download did not complete. Please try again.';
      notifyListeners();
    }
  }

  /// Starts the periodic stall ticker that flips [downloadActivity] to
  /// [DownloadActivity.stalled] once no new bytes have arrived for
  /// [stallThreshold] (Req 3.2, 3.4). Idempotent — a running ticker is reused.
  void _startStallTicker() {
    _stallTicker ??= Timer.periodic(_stallTick, (_) => _evaluateStall());
  }

  /// Cancels the stall ticker, if any. Safe to call when none is running.
  void _stopStallTicker() {
    _stallTicker?.cancel();
    _stallTicker = null;
  }

  /// Re-evaluates whether the in-flight download looks stalled and notifies
  /// observers only when the stall state actually flips, so the panel can show
  /// or clear its "seems stuck" hint without a byte callback (Req 3.4).
  void _evaluateStall() {
    if (_disposed) return;
    if (_modelStatus != ModelStatus.downloading) {
      _stopStallTicker();
      return;
    }
    _ticksSinceProgress += 1;
    final bool stalled = _ticksSinceProgress >= _stallTicksToStall;
    if (stalled != _downloadStalled) {
      _downloadStalled = stalled;
      notifyListeners();
    }
  }

  /// Sends [text] as a user turn: trims and rejects empty input (Req 2.8),
  /// ensures the model is ready, runs retrieval, assembles a grounded prompt,
  /// streams the assistant reply, attaches source hints, and moves
  /// [generationStatus] through generating → idle/error (Req 2.2–2.5, 5.2, 5.4).
  ///
  /// Flow:
  /// 1. Trim [text]; a blank message is dropped without touching the
  ///    conversation (Req 2.8).
  /// 2. Ignore the call while a reply is already generating, so overlapping
  ///    sends can't interleave two streams (Req 2.3).
  /// 3. Append the user turn immediately and notify, so it renders before the
  ///    reply arrives (Req 2.2).
  /// 4. [ensureModelReady] without touching the network. If the asset isn't
  ///    ready, leave the user turn in place and return — the panel surfaces the
  ///    one-time download prompt via [modelStatus] (Req 3.1); no assistant turn
  ///    is appended and generation stays [GenerationStatus.idle].
  /// 5. Move to [GenerationStatus.generating], clear any prior error, and
  ///    notify so the panel shows the typing indicator and disables send
  ///    (Req 2.3).
  /// 6. Retrieve the most relevant Project-Context passages for the message and
  ///    assemble the grounded prompt (Req 5.2); attach the de-duplicated source
  ///    hints to the assistant turn (Req 5.4).
  /// 7. Stream the reply, accumulating deltas into the assistant turn and
  ///    notifying on each so the panel reveals it progressively (Req 2.4). On
  ///    completion settle to [GenerationStatus.idle]; on error settle to
  ///    [GenerationStatus.error] with a recoverable message while retaining the
  ///    conversation and any partial text (Req 2.5).
  Future<void> sendMessage(String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return; // Req 2.8: drop empty/whitespace-only input.

    // Req 2.3: one generation at a time — ignore sends while a reply streams.
    if (_generationStatus == GenerationStatus.generating) return;

    // Req 2.2: the user turn appears immediately, before the reply is produced.
    final ChatMessage userTurn = ChatMessage.user(
      text: trimmed,
      timestamp: DateTime.now().toUtc(),
    );
    _messages = <ChatMessage>[..._messages, userTurn];
    notifyListeners();
    // A [clearConversation] during any await below bumps the epoch; the send
    // then abandons its turn rather than streaming into the cleared list.
    final int epoch = _conversationEpoch;

    // Req 9.3 (optional): persist the user turn as soon as it's added. Best-
    // effort and fire-and-forget — a persistence failure must not delay or
    // break the reply, so we don't await it here.
    unawaited(_persistTurn(userTurn));

    // Bring the model to a known readiness without any network access. If it's
    // not ready, keep the user turn and let the panel surface the download
    // prompt via [modelStatus] (Req 3.1) — we neither generate nor append an
    // assistant turn here.
    await ensureModelReady();
    if (_disposed) return;
    if (epoch != _conversationEpoch) return;
    if (_modelStatus != ModelStatus.ready) return;

    // Req 2.3: enter generating and clear any prior error before we stream.
    _generationStatus = GenerationStatus.generating;
    _transientError = null;
    notifyListeners();

    // Snapshot the prior turns (before the assistant placeholder) for history.
    final List<ChatMessage> history = _recentHistory();

    // Req 5.2: retrieve grounding passages for the message. Retrieval is fully
    // offline; a failure here shouldn't sink the reply, so fall back to an
    // ungrounded chat rather than erroring the whole turn (Req 5.5).
    List<RetrievedPassage> passages;
    try {
      passages = await _retriever.retrieve(trimmed);
    } catch (_) {
      passages = const <RetrievedPassage>[];
    }
    if (_disposed) return;
    if (epoch != _conversationEpoch) return;

    // Req 5.5: only note "no project material" when the project is genuinely
    // empty, not merely when this query matched nothing.
    bool projectHasMaterial = true;
    if (passages.isEmpty) {
      try {
        projectHasMaterial = await _retriever.hasProjectMaterial();
      } catch (_) {
        projectHasMaterial = true;
      }
      if (_disposed) return;
      if (epoch != _conversationEpoch) return;
    }

    final String prompt = _assembleGroundedPrompt(
      userMessage: trimmed,
      passages: passages,
      projectHasMaterial: projectHasMaterial,
    );

    // Req 5.4: attach de-duplicated source hints — only when we actually have
    // grounding passages.
    final List<ChatMessageSource> sources = _dedupedSources(passages);

    // Append the assistant placeholder we stream into, and remember its index.
    final ChatMessage assistantTurn = ChatMessage.assistant(
      text: '',
      timestamp: DateTime.now().toUtc(),
      sources: sources.isEmpty ? null : sources,
    );
    _messages = <ChatMessage>[..._messages, assistantTurn];
    _streamingIndex = _messages.length - 1;
    notifyListeners();

    // Stream the reply. The engine loads lazily on first generate (Req 8.2) and
    // runs off the UI thread (Req 8.1). Deltas concatenate into the full reply.
    final Completer<void> done = Completer<void>();
    _generationDone = done;
    final StringBuffer reply = StringBuffer();

    _generationSub = _engine
        .generate(
          prompt: prompt,
          history: history,
          maxTokens: _maxReplyTokens,
        )
        .listen(
      (String delta) {
        if (_disposed) return;
        reply.write(delta);
        _updateStreamingMessage(reply.toString());
      },
      onError: (Object error) {
        if (_disposed) {
          if (!done.isCompleted) done.complete();
          return;
        }
        // Req 2.5: a recoverable error — retain the conversation and any partial
        // text, surface a message, and re-enable input.
        _generationStatus = GenerationStatus.error;
        _transientError =
            'The assistant ran into a problem generating a reply. Please try '
            'again.';
        _generationSub = null;
        _streamingIndex = null;
        _generationDone = null;
        notifyListeners();
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (_disposed) {
          if (!done.isCompleted) done.complete();
          return;
        }
        // Req 2.3: settle back to idle so the panel re-enables send. Preserve an
        // error already set by onError (onDone still fires after cancel).
        if (_generationStatus == GenerationStatus.generating) {
          _generationStatus = GenerationStatus.idle;
        }
        // Req 9.3 (optional): persist the completed assistant turn — its final
        // text and source hints — now that generation finished. We persist the
        // settled message from [_messages] (not the empty placeholder), and
        // only when it actually has text, so a reply that produced nothing
        // isn't stored as a blank turn. Best-effort and fire-and-forget.
        //
        // Cancellation does not reach here: [cancelGeneration] cancels the
        // subscription, which suppresses this onDone — so a cancelled partial
        // reply is intentionally NOT persisted (the user turn was already
        // stored; the abandoned partial assistant turn is left in memory only).
        final int? doneIndex = _streamingIndex;
        if (doneIndex != null &&
            doneIndex >= 0 &&
            doneIndex < _messages.length &&
            _messages[doneIndex].text.isNotEmpty) {
          unawaited(_persistTurn(_messages[doneIndex]));
        }
        _generationSub = null;
        _streamingIndex = null;
        _generationDone = null;
        notifyListeners();
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    await done.future;
  }

  /// The recent conversation turns to hand the engine as history, oldest first,
  /// truncated to [_historyWindow]. The just-appended user turn is included so
  /// the engine sees the full exchange; the assistant placeholder is not yet in
  /// [_messages] when this is called.
  List<ChatMessage> _recentHistory() {
    if (_messages.length <= _historyWindow) {
      return List<ChatMessage>.of(_messages);
    }
    return _messages.sublist(_messages.length - _historyWindow);
  }

  /// Builds the grounded prompt: system framing, then any retrieved passages
  /// tagged with their source titles, then the user's message (design §4).
  String _assembleGroundedPrompt({
    required String userMessage,
    required List<RetrievedPassage> passages,
    required bool projectHasMaterial,
  }) {
    final StringBuffer buffer = StringBuffer()
      ..writeln(
        'You are SpwriteBot, a writing assistant embedded in Spwrite. Answer using the '
        "writer's project material when relevant. You are offline and cannot "
        'browse the internet.',
      )
      // Req 6.2: be honest about scope. The passages below are a limited set
      // retrieved for this question, not the whole project — never claim to
      // have read the entire book/corpus. Req 6.5: if the retrieved material
      // does not contain the answer, say it was not found rather than inventing
      // details. Req 6.4/1.4: cite the source titles shown in brackets.
      ..writeln(
        'The material below is a limited set of passages retrieved for this '
        "question, not the writer's entire project. Do not claim to have read "
        'the whole book or project. Base your answer on this retrieved material, '
        'cite the source titles it comes from, and if it does not contain the '
        'answer, say the material was not found rather than inventing details.',
      );

    if (passages.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Relevant material from the project:');
      for (final RetrievedPassage passage in passages) {
        buffer.writeln('[${passage.sourceTitle}] ${passage.text}');
      }
    } else if (!projectHasMaterial) {
      // Req 5.5: honestly note the empty project so the model doesn't invent
      // sources; it still answers as a general chat assistant.
      buffer
        ..writeln()
        ..writeln(
          'This project has no documents or characters to search yet, so no '
          'project material is available for grounding.',
        );
    }

    buffer
      ..writeln()
      ..write('User: ')
      ..write(userMessage);

    return buffer.toString();
  }

  /// Maps [passages] to source hints, preserving order and dropping duplicates
  /// by source id (Req 5.4). Returns empty when there is nothing to cite.
  List<ChatMessageSource> _dedupedSources(List<RetrievedPassage> passages) {
    if (passages.isEmpty) return const <ChatMessageSource>[];
    final Set<String> seen = <String>{};
    final List<ChatMessageSource> sources = <ChatMessageSource>[];
    for (final RetrievedPassage passage in passages) {
      if (seen.add(passage.sourceId)) {
        sources.add(
          ChatMessageSource(id: passage.sourceId, title: passage.sourceTitle),
        );
      }
    }
    return sources;
  }

  /// Replaces the streaming assistant turn's text with [text] (keeping its
  /// role, timestamp, and sources) and notifies, so the panel reveals the reply
  /// as it grows (Req 2.4). A no-op if the streaming target is gone.
  void _updateStreamingMessage(String text) {
    final int? index = _streamingIndex;
    if (index == null || index < 0 || index >= _messages.length) return;
    final List<ChatMessage> next = List<ChatMessage>.of(_messages);
    next[index] = next[index].copyWith(text: text);
    _messages = next;
    notifyListeners();
  }

  /// Cancels the in-flight generation, if any, re-enabling input (Req 2.6).
  ///
  /// Aborts the running [LlmEngine.generate] stream and settles
  /// [generationStatus] back to [GenerationStatus.idle] so the panel re-enables
  /// its send control. Partial reply text that has already streamed is **kept**
  /// (Req 2.6's "kept or discarded consistently") — except a still-empty
  /// assistant placeholder, which is removed so the UI doesn't show a blank
  /// bubble after a cancel that landed before any token arrived.
  ///
  /// A no-op when no generation is in flight (idle/error with no live
  /// subscription), and safe against a double cancel: cancelling the
  /// subscription means its `onDone`/`onError` never fire, so they cannot
  /// clobber the idle state set here.
  void cancelGeneration() {
    // Nothing to cancel: not generating and no live stream held.
    if (_generationStatus != GenerationStatus.generating &&
        _generationSub == null) {
      return;
    }

    // Stop native inference (async) and tear down the stream (async). Both are
    // fire-and-forget: the public API is synchronous, and cancelling the
    // subscription suppresses its terminal callbacks so no late state change
    // races this one.
    unawaited(_engine.cancel());
    unawaited(_generationSub?.cancel());
    _generationSub = null;

    // Cancelling the subscription suppresses its `onDone`/`onError`, so complete
    // the outstanding [sendMessage] future here — otherwise an awaited
    // `sendMessage` would hang forever after a cancel.
    final Completer<void>? done = _generationDone;
    _generationDone = null;
    if (done != null && !done.isCompleted) done.complete();

    // Drop a still-empty assistant placeholder so the panel doesn't render a
    // blank turn; keep any partial text already streamed into it.
    final int? index = _streamingIndex;
    if (index != null &&
        index >= 0 &&
        index < _messages.length &&
        _messages[index].text.isEmpty) {
      final List<ChatMessage> next = List<ChatMessage>.of(_messages)
        ..removeAt(index);
      _messages = next;
    }
    _streamingIndex = null;

    // Re-enable input (Req 2.6).
    _generationStatus = GenerationStatus.idle;
    notifyListeners();
  }

  /// Releases resources when the project closes (Req 9.2, 8.3).
  ///
  /// Removes the connectivity listener, disposes the [LlmEngine] whose lifecycle
  /// this state owns (Req 8.3), and clears the **in-memory** conversation so it
  /// does not outlive the project session (Req 9.2). It deliberately does NOT
  /// touch any persisted conversation store — cross-launch persistence (Req
  /// 9.3, when enabled) is meant to survive project close and app relaunch, so
  /// [loadPersistedConversation] can replay it next time the panel opens. The [ConnectivityProbe] may be
  /// shared across the app, so this state only removes its own listener and does
  /// **not** dispose the probe — whoever constructed the probe owns its
  /// lifecycle. The `ModelDownloader.close()` is likewise left to its owner.
  /// Async work (a download, a generation stream, a retrieval) can finish
  /// after the project closes and this state is disposed. Ignore those late
  /// notifications instead of throwing "used after being disposed".
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // Stop the download stall ticker so no timer outlives this notifier.
    _stopStallTicker();
    if (_connectivitySubscribed) {
      _connectivityProbe.removeListener(_onConnectivityChanged);
      _connectivitySubscribed = false;
    }
    // Tear down any in-flight generation stream so late deltas don't fire on a
    // disposed notifier; [_disposed] also guards the stream callbacks.
    unawaited(_generationSub?.cancel());
    _generationSub = null;
    _streamingIndex = null;
    // Complete any outstanding [sendMessage] future: cancelling the
    // subscription above suppresses its terminal callbacks, so without this an
    // awaited `sendMessage` in flight at dispose would never complete.
    final Completer<void>? done = _generationDone;
    _generationDone = null;
    if (done != null && !done.isCompleted) done.complete();
    // Fire-and-forget: releasing native model resources is async, but dispose()
    // is synchronous. The engine is not used after dispose (Req 8.3).
    unawaited(_engine.dispose());
    _messages = <ChatMessage>[];
    super.dispose();
  }
}
