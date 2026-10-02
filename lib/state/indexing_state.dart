/// State layer: [IndexingState], the project-scoped source of truth for the AI
/// Panel's *indexing* surface — the observable status of the on-device semantic
/// (RAG) index for one open project (design §6 "IndexingState", Req 9, 3, 7).
///
/// Where [AiAssistantState] owns the conversation and the *chat* Model Asset's
/// readiness, this notifier owns the parallel-but-separate concern of the
/// **embedding** model + vector index: whether the embedding model is
/// downloaded/ready, how far a background reindex has progressed, and whether
/// semantic search can be attempted at all. It deliberately does **not** modify
/// or replace [AiAssistantState]; the two live side by side and are both
/// observed by the panel via `provider`. Keeping them separate honours the
/// design's "AiAssistantState is UNCHANGED" constraint and the single
/// `ContextRetriever` seam (design §"Overview", Req 10.3).
///
/// Like the other notifiers it is **project-scoped** (constructed with the
/// Active_Project's id when a project opens, disposed when it closes) and depends
/// only on injected collaborators — the data-layer [ProjectIndexer] and
/// [ModelDownloader], and (optionally) a [ConnectivityProbe] — never on the
/// concrete embedding runtime, SQLite, or the network directly. It mirrors
/// [AiAssistantState]'s conventions throughout: ChangeNotifier, private fields
/// with read-only getters, a flat status enum plus a progress fraction, a
/// recoverable [transientError] instead of thrown failures, and disposal that
/// tears down its own listeners/timers.
///
/// **What it drives.** The heavy work — chunking + embedding the whole project —
/// lives in [ProjectIndexer] (which runs the embedding call on a background
/// isolate). This state merely *drives* it: [reindex] kicks a full build off the
/// UI thread and forwards the indexer's `(done, total)` progress into observable
/// [progress] / [indexedSources] / [totalSources] fields (Req 9.1, 9.2, 9.6),
/// while editing/scrolling/saving stay responsive because nothing here blocks
/// (Req 9.4). It also forwards the editor's save/add/remove/rename signals to the
/// indexer as fire-and-forget background work ([onDocumentSaved],
/// [onSourceAdded], [onSourceRemoved], [onDocumentRenamed]) so the editor never
/// couples to the AI feature (Req 4.6) — the composition root wires those calls
/// (task 16.3).
///
/// **Semantic readiness gate.** [isSemanticReady] is the boolean the
/// `CompositeContextRetriever`'s `isSemanticReady` gate reads to decide whether
/// to attempt the semantic tier at all (Req 7.1): it is `true` once the embedding
/// model is ready and the index is not in a hard error/rebuild state. When it is
/// `false`, the composite silently falls back to keyword / chat-only, so the
/// writer is never blocked while the model downloads or an index rebuilds
/// (Req 7.1, 7.2).
///
/// **Stale-index rebuild.** [onStaleIndexDetected] is the sink for the
/// `SemanticContextRetriever`'s stale-model signal (its `onStaleIndexDetected`
/// callback): when a query discovers vectors produced by a *different* embedding
/// model, this state schedules a background rebuild for the project (dropping the
/// semantic gate until it finishes) and surfaces a recoverable, non-blocking
/// status — it never throws or blocks the query (Req 7.4, design §"Error
/// Handling" — Dimension mismatch).
///
/// **Embedding-model download.** The one-time embedding-model download reuses the
/// existing [ModelDownloader] and a [ModelCatalog] entry
/// ([ModelCatalog.defaultEmbeddingModel]) exactly as 3.5's chat model did —
/// prompt / progress / offline / stall / verify — so the panel can present the
/// same familiar surface (Req 3.1–3.5). Presence is probed without touching the
/// network ([prepareEmbeddingModel]); the confirm-gated download
/// ([downloadEmbeddingModel]) drives progress and settles into a recoverable
/// failed state (never throwing) if it can't complete (Req 3.4, 3.5, 3.7).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/ai/model_downloader.dart';
import '../data/ai/project_indexer.dart';
import '../domain/ai/connectivity_probe.dart';
import '../domain/ai/model_catalog.dart';
import '../domain/document.dart';

/// Lifecycle of a project's on-device vector index, driving the AI Panel's
/// indexing/semantic status strip (design §6, Req 9.1, 9.6).
///
/// A flat enum (mirroring [AiAssistantState]'s `ModelStatus`) keeps the value
/// observable without a payload-carrying variant; the `[0,1]` progress fraction
/// and the "X of Y" counts are carried alongside as separate observable fields.
enum IndexStatus {
  /// No build has run yet, or the project has nothing to index. Semantic
  /// retrieval simply finds no material and the composite falls back — nothing
  /// is wrong (Req 7.2).
  idle,

  /// A background (re)build is in flight; [IndexingState.progress] and the
  /// "X of Y" counts advance as sources complete (Req 9.2, 9.6). Querying stays
  /// responsive and uses whatever grounding already exists (Req 9.5).
  building,

  /// The index is fully built and up to date; semantic retrieval can run
  /// against it (Req 9.6).
  ready,

  /// The most recent build failed with a recoverable error (surfaced in
  /// [IndexingState.transientError]); the app stays usable and the assistant
  /// falls back to keyword / chat-only grounding (Req 7.4).
  error,
}

/// Readiness of the Embedding Model that backs semantic retrieval, mirroring
/// [AiAssistantState]'s `ModelStatus` for the chat model (Req 3).
///
/// The conceptual `absent | downloading(progress) | ready | failed` is flattened
/// to an enum, with the download progress carried alongside as
/// [IndexingState.downloadProgress].
enum EmbeddingModelStatus {
  /// The embedding model has not been probed for yet.
  unknown,

  /// The embedding GGUF is not cached on disk; the panel surfaces the one-time
  /// download prompt (Req 3.2).
  absent,

  /// The embedding GGUF is being downloaded;
  /// [IndexingState.downloadProgress] reports how far along it is (Req 3.2).
  downloading,

  /// The embedding GGUF is cached and verified, ready to embed fully offline
  /// (Req 3.3, 3.7).
  ready,

  /// The one-time download failed; a recoverable error is surfaced and the app
  /// stays usable without semantic search (Req 3.4, 3.5).
  failed,
}

/// The project-scoped source of truth the AI Panel observes for the state of the
/// semantic index: the embedding model's readiness (plus one-time download
/// progress), the background reindex status/progress, the semantic-readiness
/// gate, and a recoverable transient error.
///
/// Drives [ProjectIndexer] in the background and never blocks the UI thread: the
/// heavy embedding work runs inside the indexer's background isolate, and every
/// method here is fire-and-forget or cheap async bookkeeping. Failures are
/// surfaced as [transientError] / [IndexStatus.error] rather than thrown, so a
/// problem indexing never breaks the editor or the chat surface (Req 7.4, 9.4).
class IndexingState extends ChangeNotifier {
  /// The id of the project whose vector index this manages. All indexer calls
  /// are scoped to it so one project's build can never touch another's rows
  /// (Req 1.5, 4.7, 8.4).
  final String projectId;

  /// The data-layer indexer that chunks + embeds the project's sources into the
  /// vector store. This state drives it in the background and forwards progress;
  /// the indexer owns no UI dependency (Req 4.6, 9.4). Its embedding-model
  /// lifecycle is loaded lazily inside the indexer on first embed.
  final ProjectIndexer _indexer;

  /// The one-time embedding-model downloader — the same [ModelDownloader]
  /// abstraction 3.5 used for the chat model, reused here rather than a parallel
  /// mechanism (Req 3.1, 10.3). Its lifecycle (e.g. `close()`) is owned by
  /// whoever constructed it, not by this state.
  final ModelDownloader _downloader;

  /// Optional live connectivity hint, mirrored from the probe so the panel can
  /// explain that the *initial* embedding-model download needs a connection
  /// (Req 3.4). When `null`, connectivity is simply not surfaced; everything
  /// else works unchanged. The probe may be shared app-wide, so this state only
  /// adds/removes its own listener and never disposes it.
  final ConnectivityProbe? _connectivityProbe;

  /// The Embedding Model Asset this state downloads / gates on. Defaults to
  /// [ModelCatalog.defaultEmbeddingModel]; injectable for tests.
  final ModelMetadata _model;

  /// The current index lifecycle status (Req 9.1, 9.6). Reassigned as a build
  /// runs and as stale-index rebuilds are scheduled.
  IndexStatus _status = IndexStatus.idle;

  /// The embedding model's readiness (Req 3). Gates [isSemanticReady] together
  /// with the index status.
  EmbeddingModelStatus _embeddingModelStatus = EmbeddingModelStatus.unknown;

  /// Reindex progress as a fraction in `[0, 1]`; meaningful while
  /// [status] is [IndexStatus.building], `1.0` once ready, `0.0` when idle
  /// (Req 9.2, 9.6).
  double _progress = 0.0;

  /// Number of sources fully indexed so far in the current/last build, for the
  /// "X of Y" hint (Req 9.6).
  int _indexedSources = 0;

  /// Total number of sources in the current/last build, for the "X of Y" hint
  /// (Req 9.6).
  int _totalSources = 0;

  /// One-time embedding-model download progress as a fraction in `[0, 1]`,
  /// meaningful while [embeddingModelStatus] is
  /// [EmbeddingModelStatus.downloading]; `0.0` otherwise (Req 3.2).
  double _downloadProgress = 0.0;

  /// Bytes received so far in the in-flight embedding-model download, for a
  /// human-readable "X of Y" hint (Req 3.2).
  int _downloadReceivedBytes = 0;

  /// Expected total bytes for the in-flight download, or `null` when the server
  /// did not report a size (Req 3.2).
  int? _downloadTotalBytes;

  /// The latest connectivity hint, mirrored from [_connectivityProbe]
  /// (Req 3.4). [ConnectivityStatus.unknown] until the probe reports.
  ConnectivityStatus _connectivity = ConnectivityStatus.unknown;

  /// A recoverable message surfaced to the user, or `null` when there is
  /// nothing to show. Set on a build/download failure and cleared on a fresh
  /// attempt; it is never thrown, so the app stays usable (Req 7.4, 3.4, 3.5).
  String? _transientError;

  /// Whether a background reindex is currently running, so overlapping triggers
  /// (a save that lands mid-build, a stale-index signal) coalesce into a single
  /// pending rebuild rather than starting concurrent builds that would race on
  /// the same rows.
  bool _reindexRunning = false;

  /// Set while [_reindexRunning] if another trigger asked for a rebuild, so the
  /// in-flight build re-runs once when it finishes and always converges on the
  /// latest content (Req 4.2 idempotence backs this — a re-run over unchanged
  /// content is a no-op).
  bool _rebuildRequested = false;

  /// Whether the connectivity listener is still registered, so [dispose] removes
  /// it exactly once.
  bool _connectivitySubscribed = false;

  /// Set once [dispose] runs, so late progress callbacks or a settling
  /// background build never mutate a disposed notifier.
  bool _disposed = false;

  /// Creates the indexing state for [projectId] over the injected collaborators.
  ///
  /// [model] defaults to [ModelCatalog.defaultEmbeddingModel]; inject a different
  /// [ModelMetadata] in tests. When a [connectivityProbe] is supplied its value
  /// is mirrored into [connectivity] and this state subscribes to it (so the
  /// panel can explain an offline-only download failure, Req 3.4); when omitted,
  /// connectivity is simply not surfaced. Construction stays cheap — no build is
  /// started and the embedding model is not probed here; call
  /// [prepareEmbeddingModel] and [reindex] when the panel opens.
  IndexingState(
    this.projectId, {
    required ProjectIndexer indexer,
    required ModelDownloader downloader,
    ConnectivityProbe? connectivityProbe,
    ModelMetadata model = ModelCatalog.defaultEmbeddingModel,
  })  : _indexer = indexer,
        _downloader = downloader,
        _connectivityProbe = connectivityProbe,
        _model = model {
    final ConnectivityProbe? probe = _connectivityProbe;
    if (probe != null) {
      _connectivity = probe.value;
      probe.addListener(_onConnectivityChanged);
      _connectivitySubscribed = true;
      probe.start();
    }
  }

  /// The current index lifecycle status (Req 9.1, 9.6).
  IndexStatus get status => _status;

  /// The embedding model's readiness (Req 3).
  EmbeddingModelStatus get embeddingModelStatus => _embeddingModelStatus;

  /// Whether the embedding model is ready to embed (Req 3.3, 7.1). Convenience
  /// over [embeddingModelStatus] for the panel and the readiness gate.
  bool get embeddingModelReady =>
      _embeddingModelStatus == EmbeddingModelStatus.ready;

  /// Reindex progress as a fraction in `[0, 1]` (Req 9.2, 9.6).
  double get progress => _progress;

  /// Number of sources indexed so far in the current/last build (Req 9.6).
  int get indexedSources => _indexedSources;

  /// Total number of sources in the current/last build (Req 9.6).
  int get totalSources => _totalSources;

  /// One-time embedding-model download progress as a fraction in `[0, 1]`
  /// (Req 3.2).
  double get downloadProgress => _downloadProgress;

  /// Bytes received so far in the in-flight embedding-model download (Req 3.2).
  int get downloadReceivedBytes => _downloadReceivedBytes;

  /// Expected total bytes for the in-flight download, or `null` when unknown
  /// (the server omitted a size) (Req 3.2).
  int? get downloadTotalBytes => _downloadTotalBytes;

  /// The latest connectivity hint (Req 3.4).
  ConnectivityStatus get connectivity => _connectivity;

  /// The pending recoverable error message, or `null` (Req 7.4, 3.4, 3.5).
  String? get transientError => _transientError;

  /// The Embedding Model Asset this state manages.
  ModelMetadata get model => _model;

  /// Whether a background reindex is currently running (Req 9.2).
  bool get isBuilding => _status == IndexStatus.building;

  /// Whether the semantic tier should be attempted for a query — the boolean the
  /// `CompositeContextRetriever`'s `isSemanticReady` gate reads (Req 7.1).
  ///
  /// It is `true` once the embedding model is ready and the index is not in a
  /// hard error or model-download-failed state. A *building* index still returns
  /// `true` because a partial index holds usable vectors and the composite tries
  /// semantic then falls back per query (Req 7.2). When it is `false`, the
  /// composite silently uses keyword / chat-only, so the writer is never blocked
  /// while the model downloads or a rebuild runs (Req 7.1). Pass this method as
  /// the composite's `isSemanticReady` callback in the wiring layer (task 16.2).
  bool isSemanticReady() {
    if (!embeddingModelReady) return false;
    return _status != IndexStatus.error;
  }

  /// Clears the transient error so it is not shown again on the next rebuild.
  void clearTransientError() {
    if (_transientError == null) return;
    _transientError = null;
    notifyListeners();
  }

  /// Brings the embedding model to a known readiness **without touching the
  /// network**, so the AI Panel can decide what to show (Req 3.2, 3.7).
  ///
  /// Mirrors [AiAssistantState.ensureModelReady]: it resolves
  /// [embeddingModelStatus] to [EmbeddingModelStatus.ready] when the GGUF is
  /// already cached (semantic search starts fully offline, Req 3.7) or
  /// [EmbeddingModelStatus.absent] when it is missing (surfacing the one-time
  /// download prompt, Req 3.2). It deliberately does **not** start the download
  /// — that waits for the user's confirmation via [downloadEmbeddingModel]
  /// (Req 3.2). Idempotent: returns immediately when already ready, and re-probes
  /// a prior failure so an out-of-band fix recovers.
  Future<void> prepareEmbeddingModel() async {
    if (_embeddingModelStatus == EmbeddingModelStatus.ready) return;

    bool present;
    try {
      present = await _downloader.isModelPresent(_model);
    } catch (_) {
      // A presence probe should never fail hard, but if it does, treat the
      // model as absent so the panel offers the download rather than crashing.
      present = false;
    }
    if (_disposed) return;

    if (present) {
      _embeddingModelStatus = EmbeddingModelStatus.ready;
      _transientError = null;
      notifyListeners();
      return;
    }

    if (_embeddingModelStatus != EmbeddingModelStatus.absent) {
      _embeddingModelStatus = EmbeddingModelStatus.absent;
      _downloadProgress = 0.0;
      notifyListeners();
    }
  }

  /// Performs the one-time, confirm-gated download of the Embedding Model with
  /// progress, verifying integrity before marking it ready and keeping the app
  /// usable if the device is offline (Req 3.2–3.5, 3.7).
  ///
  /// Mirrors [AiAssistantState.downloadModel]: call this only after the user
  /// confirms the prompt surfaced by [prepareEmbeddingModel]. It moves
  /// [embeddingModelStatus] to [EmbeddingModelStatus.downloading] and drives
  /// [downloadProgress] from the downloader's byte callback; on success the
  /// downloader has already verified the sha256 (Req 3.5) so a returned path
  /// means a complete asset and it settles [EmbeddingModelStatus.ready] — after
  /// which embedding never needs the network again (Req 3.3). On failure it
  /// settles [EmbeddingModelStatus.failed] with a [transientError] and **never
  /// throws**, so the rest of the app stays usable and the assistant falls back
  /// (Req 3.4, 7.4). A concurrent call while already downloading is ignored, and
  /// a call once ready returns immediately, so a double confirm cannot start two
  /// downloads.
  Future<void> downloadEmbeddingModel() async {
    if (_embeddingModelStatus == EmbeddingModelStatus.ready) return;
    if (_embeddingModelStatus == EmbeddingModelStatus.downloading) return;

    _embeddingModelStatus = EmbeddingModelStatus.downloading;
    _downloadProgress = 0.0;
    _downloadReceivedBytes = 0;
    _downloadTotalBytes = null;
    _transientError = null;
    notifyListeners();

    try {
      await _downloader.download(
        _model,
        onProgress: (int received, int? total) {
          if (_disposed) return;
          _downloadReceivedBytes = received;
          if (total != null && total > 0) {
            _downloadTotalBytes = total;
            final double fraction = (received / total).clamp(0.0, 1.0);
            // Monotonic + throttled: only notify on a meaningful advance so a
            // flood of byte callbacks doesn't rebuild the panel per chunk
            // (Req 3.2); still record sub-threshold advances so the next notify
            // reflects true progress, and never regress the bar.
            if (fraction <= _downloadProgress) return;
            if ((fraction - _downloadProgress) >= 0.01 || fraction >= 1.0) {
              _downloadProgress = fraction;
              notifyListeners();
            } else {
              _downloadProgress = fraction;
            }
          }
        },
      );

      if (_disposed) return;
      // The downloader verified the sha256 before accepting the file (Req 3.5),
      // so a returned path means a complete, integrity-checked asset.
      _embeddingModelStatus = EmbeddingModelStatus.ready;
      _downloadProgress = 1.0;
      _transientError = null;
      notifyListeners();
    } on ModelDownloadException catch (error) {
      if (_disposed) return;
      // A failed download must not tear down the app: settle into `failed` with
      // the downloader's message (offline vs. other failures are worded there)
      // and keep everything else usable (Req 3.4, 3.5). No partial asset remains
      // — the downloader cleaned up its temp file.
      _embeddingModelStatus = EmbeddingModelStatus.failed;
      _downloadProgress = 0.0;
      _transientError = error.message;
      notifyListeners();
    } catch (error) {
      if (_disposed) return;
      // Any other failure (unexpected I/O, etc.): a plain, recoverable retry
      // message; the model is not marked ready, so nothing embeds with a bad
      // asset (Req 3.5).
      _embeddingModelStatus = EmbeddingModelStatus.failed;
      _downloadProgress = 0.0;
      _transientError = 'The one-time embedding-model download did not '
          'complete. Please try again.';
      notifyListeners();
    }
  }

  /// Kicks off a **non-blocking** background (re)build of the whole project
  /// index and returns immediately — the heavy embedding work runs off the UI
  /// thread inside the indexer, and this method never blocks the caller (Req 9.1,
  /// 9.2, 9.4).
  ///
  /// The panel calls this when it opens (and the wiring layer may call it when
  /// the project is first opened with no index). It moves [status] to
  /// [IndexStatus.building], resets progress, and drives the indexer's
  /// [ProjectIndexer.reindexProject], forwarding its `(done, total)` progress
  /// into the observable fields as each source completes (Req 9.6). On success it
  /// settles [IndexStatus.ready]; on failure it settles [IndexStatus.error] with
  /// a recoverable [transientError] — it never throws, so a build problem falls
  /// back to keyword grounding rather than breaking the app (Req 7.4).
  ///
  /// Concurrency-safe: if a build is already running, the request is remembered
  /// and the in-flight build re-runs once when it finishes (a re-index over
  /// unchanged content is idempotent, so this converges on the latest content
  /// without racing concurrent builds on the same rows, Req 4.2).
  void reindex() {
    if (_disposed) return;
    if (_reindexRunning) {
      // Coalesce: let the running build finish, then run once more so the index
      // converges on the latest content (Req 4.2).
      _rebuildRequested = true;
      return;
    }
    unawaited(_runReindex());
  }

  /// The actual background build loop backing [reindex]: runs one full reindex,
  /// then repeats while another rebuild was requested mid-build, so overlapping
  /// triggers coalesce into a convergent sequence rather than concurrent races.
  Future<void> _runReindex() async {
    _reindexRunning = true;
    try {
      do {
        _rebuildRequested = false;

        if (_disposed) return;
        _status = IndexStatus.building;
        _progress = 0.0;
        _indexedSources = 0;
        _totalSources = 0;
        _transientError = null;
        notifyListeners();

        try {
          await _indexer.reindexProject(
            projectId,
            onProgress: (int done, int total) {
              if (_disposed) return;
              _indexedSources = done;
              _totalSources = total;
              _progress = total <= 0 ? 1.0 : (done / total).clamp(0.0, 1.0);
              notifyListeners();
            },
          );
          if (_disposed) return;
          // Build finished: mark ready and pin progress to complete (Req 9.6).
          _status = IndexStatus.ready;
          _progress = 1.0;
          notifyListeners();
        } catch (error) {
          if (_disposed) return;
          // A build failure is recoverable and non-blocking: surface a status
          // rather than throw, so the assistant falls back to keyword grounding
          // and the editor stays fully usable (Req 7.4, 9.4).
          _status = IndexStatus.error;
          _transientError = 'Indexing your project ran into a problem. '
              'Semantic search is temporarily unavailable; the assistant will '
              'keep working. It will retry automatically.';
          notifyListeners();
        }
        // Loop again only if a rebuild was requested while this one ran.
      } while (_rebuildRequested && !_disposed);
    } finally {
      _reindexRunning = false;
    }
  }

  /// Forwards a document save to the indexer as background, incremental work so
  /// the index stays current without re-embedding unchanged passages (Req 4.2).
  ///
  /// Fire-and-forget and non-blocking: the editor calls this via the composition
  /// root's save wiring (task 16.3) and never awaits it, so saving stays
  /// responsive (Req 4.6, 9.4). A failure is swallowed into a recoverable
  /// [transientError] rather than thrown, so a hiccup indexing one save never
  /// interrupts the editor (Req 7.4). The [document] is passed as [Object] to
  /// keep this state decoupled from the concrete `Document` type; the indexer
  /// resolves it.
  void onDocumentSaved(Object document) {
    _runIncremental(() => _indexer.onSourceAdded(document));
  }

  /// Forwards a newly added source (a document or character) to the indexer as
  /// background work, embedding and indexing all of its chunks (Req 4.3).
  ///
  /// Fire-and-forget and non-blocking, like [onDocumentSaved].
  void onSourceAdded(Object source) {
    _runIncremental(() => _indexer.onSourceAdded(source));
  }

  /// Forwards a source removal to the indexer as background work, deleting all
  /// of that source's rows from the index (Req 4.4).
  ///
  /// Fire-and-forget and non-blocking, scoped to [projectId] so it can never
  /// remove another project's rows.
  void onSourceRemoved(String sourceId) {
    _runIncremental(() => _indexer.onSourceRemoved(projectId, sourceId));
  }

  /// Forwards a document rename to the indexer as background work: the body
  /// chunks are unchanged, so only the stored `source_title` (and the small
  /// title chunk, if titles are embedded) is refreshed (Req 4.5).
  ///
  /// Fire-and-forget and non-blocking. The already-renamed [document] carries
  /// the new title; the indexer refreshes every stored row's `source_title` and
  /// re-embeds only the title chunk.
  void onDocumentRenamed(Document document) {
    _runIncremental(() => _indexer.onDocumentRenamed(document));
  }

  /// Handles the `SemanticContextRetriever`'s stale-model signal by scheduling a
  /// background rebuild for [staleProjectId] and surfacing a recoverable,
  /// non-blocking status (Req 7.4, design §"Error Handling" — Dimension
  /// mismatch).
  ///
  /// Pass this method as the `SemanticContextRetriever`'s `onStaleIndexDetected`
  /// callback in the wiring layer (task 16.2). When a query discovers vectors
  /// produced by a *different* embedding model, the retriever skips those rows,
  /// falls back to keyword for that query, and fires this once; here we schedule
  /// a rebuild (which replaces the stale rows with vectors from the current
  /// model) without blocking or throwing. Signals for a *different* project than
  /// this state manages are ignored, since each project has its own
  /// [IndexingState]. A duplicate signal while a rebuild is already running
  /// coalesces via [reindex].
  void onStaleIndexDetected(String staleProjectId) {
    if (_disposed) return;
    if (staleProjectId != projectId) return;
    reindex();
  }

  /// Runs an incremental indexer [action] as fire-and-forget background work,
  /// swallowing any failure into a recoverable [transientError] rather than
  /// throwing (Req 7.4).
  ///
  /// Incremental work never flips the overall [status] to `building` — that is
  /// reserved for a full [reindex] the panel shows progress for; a single save
  /// is a lightweight background touch-up. A failure here is surfaced as a
  /// transient error but leaves the prior status intact so one bad save doesn't
  /// mark the whole index broken.
  void _runIncremental(Future<void> Function() action) {
    if (_disposed) return;
    unawaited(() async {
      try {
        await action();
      } catch (_) {
        if (_disposed) return;
        // Recoverable, non-blocking: the editor keeps working and the next full
        // reindex (or the next save) will reconcile the index (Req 7.4, 9.4).
        _transientError = 'Updating the semantic index for a recent change ran '
            'into a problem. The assistant will keep working and retry.';
        notifyListeners();
      }
    }());
  }

  /// Mirrors the probe's latest [ConnectivityStatus] into [connectivity],
  /// notifying observers only when it actually changes (Req 3.4).
  void _onConnectivityChanged() {
    final ConnectivityProbe? probe = _connectivityProbe;
    if (probe == null) return;
    final ConnectivityStatus next = probe.value;
    if (next == _connectivity) return;
    _connectivity = next;
    notifyListeners();
  }

  /// Releases resources when the project closes.
  ///
  /// Removes the connectivity listener (but does not dispose the possibly-shared
  /// [ConnectivityProbe], whose lifecycle its owner controls) and marks the
  /// state disposed so a settling background build or a late download/progress
  /// callback never mutates a disposed notifier. It does **not** own or dispose
  /// the [ProjectIndexer]'s embedding model or the [ModelDownloader] — those are
  /// app-lifetime collaborators owned by the composition root.
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
    final ConnectivityProbe? probe = _connectivityProbe;
    if (_connectivitySubscribed && probe != null) {
      probe.removeListener(_onConnectivityChanged);
      _connectivitySubscribed = false;
    }
    super.dispose();
  }
}
