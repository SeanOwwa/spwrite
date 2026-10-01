/// Data layer: [FllamaLlmEngine], the concrete [LlmEngine] backed by the
/// embedded llama.cpp runtime via the `fllama` package (design §2, Req 2.2,
/// 2.4, 2.6, 7.5, 8.1, 8.3, 8.4).
///
/// This is the only place that touches the on-device inference runtime; the
/// state layer depends solely on the [LlmEngine] abstraction, so the runtime
/// stays swappable (design §2).
///
/// ## How it maps onto the fllama API
/// `fllama` exposes an OpenAI-style chat entry point:
///
///   `Future<int> fllamaChat(OpenAiRequest request, FllamaInferenceCallback cb)`
///
/// where the returned `int` is a **request id** used to cancel, and
///
///   `typedef FllamaInferenceCallback =
///        void Function(String response, String openaiResponseJson, bool done);`
///
/// The `response` argument is the **cumulative** text generated so far (fllama
/// hands back the whole accumulated reply on every token, not just the new
/// piece), and `done` flips to `true` on the final call. Cancellation is
/// `fllamaCancelInference(int requestId)`, after which the callback still fires
/// once more with `done: true`.
///
/// ### Off the UI thread (Req 8.1)
/// fllama runs llama.cpp on a dedicated **helper isolate** and its native code
/// on background threads, so both model loading and token generation happen off
/// the UI thread. This engine only assembles requests, forwards deltas onto a
/// [StreamController], and never does blocking work on the caller's isolate,
/// keeping the app responsive while the assistant works.
///
/// ### Streaming deltas (LlmEngine contract)
/// The [LlmEngine.generate] contract says concatenating the emitted fragments
/// yields the full reply, so this engine converts fllama's cumulative text into
/// **incremental deltas**: on each callback it emits only the suffix that is new
/// relative to the text emitted so far.
///
/// ### Resident model (Req 8.3)
/// fllama loads the GGUF per inference call (there is no separate persistent
/// "load" handle in this binding), but it keeps native context/weights warm
/// across calls internally. [load] therefore validates that the cached GGUF is
/// present and readable and that the runtime is available; the weights are
/// brought resident on the first [generate] and reused for subsequent messages
/// within the session. [dispose] cancels any in-flight work and releases this
/// engine's stream resources.
///
/// ### Clear failure when the host can't load the model (Req 7.5, 8.4)
/// If the cached file is missing/unreadable, [load] throws [LlmEngineException]
/// so the state layer can present a recoverable message rather than crash. When
/// the runtime itself cannot load the weights (out of memory, unsupported host,
/// corrupt file), fllama reports it through the callback text; this engine
/// detects that via `fllamaOutputIndicatesLoadError` and turns it into a stream
/// error (Req 2.5, 8.4).
library;

import 'dart:async';
import 'dart:io';

import 'package:fllama/fllama.dart';

import '../../domain/ai/chat_message.dart';
import '../../domain/ai/llm_engine.dart';

/// Signature for invoking fllama's chat entry point. Injected so the engine can
/// be unit-tested without the native runtime; defaults to the real
/// [fllamaChat]. Returns the request id used for cancellation.
typedef FllamaChatRunner = Future<int> Function(
  OpenAiRequest request,
  FllamaInferenceCallback callback,
);

/// Signature for cancelling an in-flight fllama inference by request id.
/// Injected for testability; defaults to the real [fllamaCancelInference].
typedef FllamaCancelRunner = void Function(int requestId);

/// Classifies output text from the runtime as a model-load failure. Injected
/// for testability; defaults to fllama's [fllamaOutputIndicatesLoadError].
typedef FllamaLoadErrorDetector = bool Function(String output);

/// Raised when the Local Model cannot be loaded or run. Carries a
/// human-readable [message] the state/presentation layer can surface, and an
/// optional [cause] with the underlying error (Req 7.5, 8.4).
class LlmEngineException implements Exception {
  /// A human-readable description of what went wrong.
  final String message;

  /// The underlying error, when this exception wraps another failure.
  final Object? cause;

  const LlmEngineException(this.message, [this.cause]);

  @override
  String toString() => cause == null
      ? 'LlmEngineException: $message'
      : 'LlmEngineException: $message ($cause)';
}

/// The embedded-runtime [LlmEngine]: loads the cached GGUF and streams chat
/// generation via `fllama`, off the UI thread, with cancel and dispose support.
class FllamaLlmEngine implements LlmEngine {
  /// Absolute path to the cached GGUF Model Asset this engine runs. Provided by
  /// the wiring layer from `ModelDownloader.resolveCachedPath` /
  /// `cachedModelPathIfPresent` (task 3.2), so the engine never touches the
  /// network — it only loads a file already verified and cached on disk.
  final String modelPath;

  /// llama.cpp context window (tokens) available to a single request. The
  /// caller truncates history to fit; this bounds the prompt + reply the
  /// runtime will consider.
  ///
  /// fllama runs llama.cpp's server core with [fllamaParallelSlots] parallel
  /// slots and divides the configured `n_ctx` evenly between them, so the
  /// window actually requested from the runtime is
  /// `contextSize * fllamaParallelSlots` (see [nativeContextSize]). Without
  /// that scaling a 2048 window leaves each request only 512 tokens, and any
  /// grounded prompt fails with "request exceeds the available context size".
  final int contextSize;

  /// Number of parallel slots fllama's native server allocates
  /// (`ServerManager::DEFAULT_N_PARALLEL` in fllama's `fllama_inference_queue.h`).
  static const int fllamaParallelSlots = 4;

  /// The `n_ctx` handed to the runtime so that each slot gets [contextSize].
  int get nativeContextSize => contextSize * fllamaParallelSlots;

  /// Number of model layers to offload to the GPU. `0` keeps everything on the
  /// CPU — the safe, portable default across desktop hosts; the wiring layer
  /// can raise it where a capable GPU is known to be present.
  final int numGpuLayers;

  /// Default reply length cap (tokens) when a call omits `maxTokens`.
  final int defaultMaxTokens;

  /// Default sampling temperature when a call omits `temperature`.
  final double defaultTemperature;

  final FllamaChatRunner _chat;
  final FllamaCancelRunner _cancel;
  final FllamaLoadErrorDetector _isLoadError;

  /// Whether [load] has completed successfully (the cached file validated).
  bool _loaded = false;

  /// Whether [dispose] has been called; further use is rejected.
  bool _disposed = false;

  /// The controller backing the current [generate] stream, or `null` when no
  /// generation is in flight.
  StreamController<String>? _activeController;

  /// The fllama request id of the in-flight inference, or `null` when idle.
  /// Used by [cancel] to abort the current generation (Req 2.6).
  int? _activeRequestId;

  /// The cumulative text last delivered by the runtime for the in-flight
  /// generation, so each callback can emit only the newly-appended delta.
  String _emittedSoFar = '';

  /// Creates an engine bound to the GGUF at [modelPath].
  ///
  /// The fllama entry points are injected ([chatRunner], [cancelRunner],
  /// [loadErrorDetector]) and default to the real runtime, so tests can drive
  /// the engine with fakes without the native binding.
  FllamaLlmEngine({
    required this.modelPath,
    this.contextSize = 2048,
    this.numGpuLayers = 0,
    this.defaultMaxTokens = 512,
    this.defaultTemperature = 0.7,
    FllamaChatRunner? chatRunner,
    FllamaCancelRunner? cancelRunner,
    FllamaLoadErrorDetector? loadErrorDetector,
  })  : _chat = chatRunner ?? fllamaChat,
        _cancel = cancelRunner ?? fllamaCancelInference,
        _isLoadError = loadErrorDetector ?? fllamaOutputIndicatesLoadError;

  @override
  Future<void> load() async {
    if (_disposed) {
      throw const LlmEngineException(
        'The assistant engine has been disposed and cannot be loaded again.',
      );
    }
    if (_loaded) return; // Already resident: no-op (per the LlmEngine contract).

    // fllama loads the weights per inference, so "load" here validates that the
    // cached GGUF is actually present and readable. A missing/unreadable file
    // is the common way a host "can't load the model", and we surface it as a
    // clear, recoverable error rather than letting inference fail opaquely
    // later (Req 7.5, 8.4).
    final File file = File(modelPath);
    bool exists;
    try {
      exists = await file.exists();
    } catch (error) {
      throw LlmEngineException(
        'Could not access the local model file at "$modelPath".',
        error,
      );
    }
    if (!exists) {
      throw LlmEngineException(
        'The local model file is missing at "$modelPath". Download the model '
        'and try again.',
      );
    }
    try {
      // A zero-length file is never a valid GGUF; catch it up front so the
      // failure is clear instead of surfacing deep in the runtime.
      final int length = await file.length();
      if (length <= 0) {
        throw LlmEngineException(
          'The local model file at "$modelPath" is empty or corrupt. '
          'Re-download the model and try again.',
        );
      }
    } on LlmEngineException {
      rethrow;
    } catch (error) {
      throw LlmEngineException(
        'Could not read the local model file at "$modelPath".',
        error,
      );
    }

    _loaded = true;
  }

  @override
  Stream<String> generate({
    required String prompt,
    List<ChatMessage> history = const <ChatMessage>[],
    int? maxTokens,
    double? temperature,
  }) {
    // Surface lifecycle misuse as a stream error so the state layer can present
    // a recoverable error turn and retain the conversation (Req 2.5).
    if (_disposed) {
      return Stream<String>.error(
        const LlmEngineException(
          'The assistant engine has been disposed.',
        ),
      );
    }
    if (_activeController != null) {
      return Stream<String>.error(
        const LlmEngineException(
          'A reply is already being generated; cancel it before starting '
          'another.',
        ),
      );
    }

    final StreamController<String> controller = StreamController<String>();
    _activeController = controller;
    _emittedSoFar = '';

    // Kick off generation without blocking the caller. All heavy work happens
    // on fllama's helper isolate / native threads (Req 8.1); here we only wire
    // the callback to the stream.
    controller.onCancel = () {
      // Downstream stopped listening: cancel the in-flight inference so the
      // runtime stops producing tokens (Req 2.6).
      _cancelActive();
    };

    _startGeneration(
      controller: controller,
      prompt: prompt,
      history: history,
      maxTokens: maxTokens ?? defaultMaxTokens,
      temperature: temperature ?? defaultTemperature,
    );

    return controller.stream;
  }

  /// Assembles the fllama request and drives its streaming callback into
  /// [controller], converting cumulative runtime text into incremental deltas.
  Future<void> _startGeneration({
    required StreamController<String> controller,
    required String prompt,
    required List<ChatMessage> history,
    required int maxTokens,
    required double temperature,
  }) async {
    // Ensure the model file has been validated before running (load-if-needed
    // per the contract); a validation failure ends the stream with a clear
    // error (Req 7.5, 8.4).
    try {
      if (!_loaded) {
        await load();
      }
    } catch (error) {
      _finishWithError(controller, error);
      return;
    }

    final OpenAiRequest request = OpenAiRequest(
      modelPath: modelPath,
      messages: _buildMessages(prompt, history),
      // Scaled so one request gets the full [contextSize] after fllama splits
      // n_ctx across its parallel slots.
      contextSize: nativeContextSize,
      numGpuLayers: numGpuLayers,
      maxTokens: maxTokens,
      temperature: temperature,
    );

    void onToken(String response, String _, bool done) {
      // Ignore late callbacks after the stream has already been torn down
      // (e.g. a cancel raced with the final token).
      if (!identical(_activeController, controller) || controller.isClosed) {
        return;
      }

      // The runtime hands back the full cumulative text each time; emit only
      // the portion not yet sent so concatenating fragments yields the full
      // reply (LlmEngine contract).
      if (response.length > _emittedSoFar.length &&
          response.startsWith(_emittedSoFar)) {
        controller.add(response.substring(_emittedSoFar.length));
        _emittedSoFar = response;
      } else if (response != _emittedSoFar) {
        // Defensive: if the runtime ever returns non-monotonic text, fall back
        // to emitting the whole response and resync our cursor.
        controller.add(response);
        _emittedSoFar = response;
      }

      if (done) {
        // The runtime signals a load failure through the output text rather
        // than an exception; turn that into a stream error (Req 2.5, 8.4).
        if (_emittedSoFar.isEmpty && _isLoadError(response)) {
          _finishWithError(
            controller,
            LlmEngineException(
              'The local model could not be loaded. Your device may not have '
              'enough memory to run the assistant. ($response)',
            ),
          );
          return;
        }
        _finishOk(controller);
      }
    }

    try {
      final int requestId = await _chat(request, onToken);
      // A cancel() may have arrived before we learned the request id; honor it
      // now that we know which inference to cancel.
      if (!identical(_activeController, controller) || controller.isClosed) {
        _cancel(requestId);
        return;
      }
      _activeRequestId = requestId;
    } catch (error) {
      _finishWithError(
        controller,
        LlmEngineException(
          'The assistant could not generate a reply.',
          error,
        ),
      );
    }
  }

  /// Maps the assembled [prompt] and prior [history] onto fllama's chat
  /// [Message] list. The system framing and retrieved passages are already
  /// baked into [prompt] by the caller, so [prompt] becomes the final user
  /// turn; [history] supplies the prior turns (oldest first) with their roles
  /// mapped system/user/assistant (Req 2.2).
  List<Message> _buildMessages(String prompt, List<ChatMessage> history) {
    final List<Message> messages = <Message>[
      for (final ChatMessage m in history) Message(_roleOf(m.role), m.text),
      Message(Role.user, prompt),
    ];
    return messages;
  }

  /// Maps a domain [ChatRole] onto fllama's [Role].
  Role _roleOf(ChatRole role) {
    switch (role) {
      case ChatRole.system:
        return Role.system;
      case ChatRole.assistant:
        return Role.assistant;
      case ChatRole.user:
        return Role.user;
    }
  }

  @override
  Future<void> cancel() async {
    _cancelActive();
  }

  /// Cancels the in-flight inference (if any) and closes the active stream. Safe
  /// to call when nothing is in flight (Req 2.6).
  void _cancelActive() {
    final StreamController<String>? controller = _activeController;
    if (controller == null) return;

    final int? requestId = _activeRequestId;
    if (requestId != null) {
      try {
        _cancel(requestId);
      } catch (_) {
        // Best-effort: even if the native cancel fails, we still tear down the
        // stream below so input is re-enabled.
      }
    }

    // Detach state first so the (possibly still-arriving) final callback is
    // ignored, then close the stream so listeners see a clean completion.
    _activeController = null;
    _activeRequestId = null;
    _emittedSoFar = '';
    if (!controller.isClosed) {
      controller.close();
    }
  }

  /// Completes [controller] successfully and clears the in-flight state.
  void _finishOk(StreamController<String> controller) {
    if (identical(_activeController, controller)) {
      _activeController = null;
      _activeRequestId = null;
      _emittedSoFar = '';
    }
    if (!controller.isClosed) {
      controller.close();
    }
  }

  /// Emits [error] on [controller], then closes it and clears in-flight state.
  void _finishWithError(StreamController<String> controller, Object error) {
    if (identical(_activeController, controller)) {
      _activeController = null;
      _activeRequestId = null;
      _emittedSoFar = '';
    }
    if (!controller.isClosed) {
      controller.addError(error);
      controller.close();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Abort any in-flight generation and release the stream. fllama owns the
    // native context lifecycle internally; there is no separate unload handle
    // in this binding, so releasing our stream resources and cancelling the
    // active request is the extent of what this engine holds.
    _cancelActive();
    _loaded = false;
  }
}
