/// Domain layer: the [LlmEngine] abstraction over the Local Model runtime.
///
/// The state layer (`AiAssistantState`) depends only on this interface, never
/// on the concrete on-device runtime (e.g. the embedded llama.cpp binding),
/// keeping the runtime swappable and the state layer unit-testable with fakes.
/// The data layer's `FllamaLlmEngine` implements each member against the
/// embedded runtime (Req 2.2, 2.4, 2.6, 8.1).
///
/// The engine exposes a small lifecycle — [load] to bring the model resident,
/// [generate] to stream a reply token-by-token, [cancel] to abort an in-flight
/// generation, and [dispose] to release the model — mirroring how the other
/// domain abstractions ([CharacterRepository], [DocumentRepository]) hide their
/// implementation behind a narrow, throwing interface.
library;

import 'chat_message.dart';

/// Abstracts the Local Model runtime so the state layer never touches the
/// embedded inference engine directly.
///
/// Lifecycle: callers [load] the model lazily on first use (Req 8.2), then call
/// [generate] one or more times while the model stays resident for
/// responsiveness (Req 8.3), and finally [dispose] to release it when the
/// project closes or resources demand it (Req 8.3).
///
/// Implementations must keep model loading and text generation **off the UI
/// thread** so the app stays responsive while the assistant works (Req 8.1),
/// and must surface failures by throwing (or emitting an error on the stream)
/// so the state layer can present a recoverable error and retain the prior
/// conversation (Req 2.5, 7.5, 8.4).
abstract class LlmEngine {
  /// Brings the Local Model resident and ready to [generate].
  ///
  /// Called lazily on first assistant use rather than at app startup (Req 8.2).
  /// Loading runs off the UI thread (Req 8.1). Completes when the model is
  /// ready; throws a clear error when the host lacks the resources to load the
  /// model so the caller can degrade gracefully rather than crash
  /// (Req 7.5, 8.4). Calling [load] when the model is already resident is a
  /// no-op.
  Future<void> load();

  /// Streams the assistant's reply to [prompt] token-by-token, so the panel can
  /// progressively reveal the answer as it arrives (Req 2.4).
  ///
  /// The [prompt] is the already-assembled grounded prompt (system framing plus
  /// retrieved Project-Context passages and the new user message). Prior turns
  /// are supplied via [history] — the recent conversation, oldest first,
  /// truncated by the caller to fit the model's context window — so the engine
  /// can condition on the exchange (Req 2.2).
  ///
  /// Generation runs off the UI thread (Req 8.1). The returned [Stream] emits
  /// incremental text fragments in order and closes when the reply is complete;
  /// concatenating the emitted fragments yields the full reply. The stream
  /// emits an error if generation fails (model error, out of memory), letting
  /// the state layer surface a recoverable error turn (Req 2.5).
  ///
  /// Optional decoding controls: [maxTokens] caps the reply length, and
  /// [temperature] tunes randomness; implementations apply sensible defaults
  /// when these are omitted. If [load] has not completed, implementations
  /// should load first or throw.
  Stream<String> generate({
    required String prompt,
    List<ChatMessage> history,
    int? maxTokens,
    double? temperature,
  });

  /// Cancels the in-flight [generate] stream, if any (Req 2.6).
  ///
  /// After cancellation the current generation stream stops emitting and the
  /// engine is ready to [generate] again; any partial output already emitted is
  /// retained or discarded by the caller consistently. Calling [cancel] when no
  /// generation is in flight is a no-op.
  Future<void> cancel();

  /// Releases the Local Model and any native resources it holds (Req 8.3).
  ///
  /// Called when the project is closed or resources demand it. After [dispose]
  /// the engine must be [load]ed again before further use.
  Future<void> dispose();
}
