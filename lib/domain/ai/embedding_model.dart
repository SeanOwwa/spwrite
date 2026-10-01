/// Domain layer: the [EmbeddingModel] abstraction over the on-device embedding
/// runtime.
///
/// Mirrors [LlmEngine]: the data layer's `FllamaEmbeddingModel` implements each
/// member against the embedded runtime, so the higher layers (the semantic
/// retriever, the project indexer) depend only on this narrow interface and
/// never on the concrete runtime. This keeps the embedding runtime swappable —
/// a fllama/llama.cpp embedding call today, or a dedicated embedding FFI/isolate
/// tomorrow — as a **data-layer-only** decision behind this seam (Req 3.3, 10.2,
/// 10.3).
///
/// The engine exposes a small lifecycle — [load] to bring the model resident,
/// [embed]/[embedBatch] to convert text into fixed-length vectors, and
/// [dispose] to release native resources — mirroring how the other domain
/// abstractions ([LlmEngine], [CharacterRepository], [DocumentRepository]) hide
/// their implementation behind a narrow, throwing interface.
///
/// ## Spike result — the fllama embedding entry point (design open question 1)
///
/// Confirmed against the pinned fllama checkout
/// (`github.com/Telosnex/fllama`, ref `f624e4bf…`, the exact `pubspec.yaml`
/// pin) — read directly from the pub-cache source, not inferred:
///
/// * **The fllama Dart API does not expose embeddings.** `lib/fllama.dart`
///   re-exports only chat/inference/tokenize/GPU surfaces
///   (`fllamaChat`, `fllamaInference`, `fllamaTokenize`,
///   `fllamaCancelInference`, `fllamaGetGpuMemoryInfo`, …). There is no
///   `embed`/`embedding` function, and `OpenAiRequest` has no embeddings mode.
/// * **The native C wrapper does not expose embeddings either.** `src/fllama.h`
///   declares only `fllama_inference`, `fllama_inference_sync`,
///   `fllama_inference_cancel`, tokenize, and GPU-info exports. The single
///   `"set_embeddings: value = 0"` string in `src/fllama.cpp` is a per-token
///   **log-noise filter**, not an entry point; the "embedding" mentions in
///   `docs/ADR_003…` describe the **WASM/browser (wllama)** request-ID
///   lifecycle, not the desktop FFI path this app uses.
/// * **The vendored llama.cpp does support embeddings natively.**
///   `src/llama.cpp/include/llama.h` declares `llama_set_embeddings`,
///   `llama_get_embeddings`, `llama_get_embeddings_seq`, `llama_pooling_type`,
///   and `LLAMA_POOLING_TYPE_{MEAN,CLS,LAST}` — the raw capability is present
///   in the bundled runtime, just not surfaced by the fllama wrapper.
///
/// **Decision (data-layer-only, behind this seam):** the bundled fllama build
/// cannot produce embeddings through its public API, so `FllamaEmbeddingModel`
/// (task 5.1) must reach the embedding capability another way — a dedicated
/// embedding **FFI binding** onto the already-linked llama.cpp
/// (`llama_set_embeddings(ctx, true)` + `LLAMA_POOLING_TYPE_MEAN` +
/// `llama_get_embeddings_seq`), run in a **background isolate** to stay off the
/// UI thread — rather than a fllama chat/inference call. Because every caller
/// depends only on this `EmbeddingModel` interface, that choice stays a
/// data-layer decision: the seam is the contract, and the implementation is
/// free to change (or swap to a different embedding runtime) without touching
/// any layer above the data layer (Req 3.3, 10.2, 10.3).
library;

/// Abstracts the on-device Embedding Model runtime so the layers above never
/// touch the embedded inference engine directly (Req 3, 8.1, 10.2, 10.3).
///
/// An embedding is a fixed-length numeric vector representing the meaning of a
/// piece of text, such that texts with similar meaning have nearby vectors.
///
/// Lifecycle: callers [load] the model lazily on first use, then call [embed] or
/// [embedBatch] one or more times while the model stays resident, and finally
/// [dispose] to release it when the project closes or resources demand it —
/// mirroring [LlmEngine].
///
/// Implementations must keep model loading and embedding work **off the UI
/// thread** so the app stays responsive while indexing and retrieval run
/// (Req 4.6, 8.1, 9.4), and must surface failures by **throwing** so callers
/// (the composite retriever) can degrade gracefully to keyword or chat-only
/// grounding rather than break (Req 7.4).
abstract class EmbeddingModel {
  /// Dimension of the vectors this model produces (e.g. 384 for bge-small).
  ///
  /// Stable once the model is [load]ed. Used to size storage (the Float32 BLOB
  /// is `dimension * 4` bytes) and to detect a model change, so vectors produced
  /// by a different model can be treated as stale and reindexed (Req 4.2, 7.4).
  int get dimension;

  /// A stable id, matching the corresponding `ModelCatalog` entry id, so stored
  /// embeddings can be tagged with the model that produced them.
  ///
  /// Used together with [dimension] to detect a dimension/model mismatch and
  /// trigger a reindex when the embedding model has changed (Req 4.2, 7.4).
  String get modelId;

  /// Brings the Embedding Model resident and ready to [embed] (Req 3.3, 3.7).
  ///
  /// Called lazily on first use rather than at app startup. Loading runs off the
  /// UI thread (Req 8.1). Completes when the model is ready; throws a clear error
  /// when the host lacks the resources to load the model, or when the bundled
  /// runtime does not expose embeddings, so the caller can degrade gracefully
  /// rather than crash (Req 7.4). Calling [load] when the model is already
  /// resident is a no-op.
  Future<void> load();

  /// Embeds a single [text] into a fixed-length vector of length [dimension]
  /// (Req 1.1, 8.1).
  ///
  /// Runs off the UI thread. The implementation applies any model-specific
  /// task-instruction prefix (e.g. `search_document:` / `search_query:` for
  /// nomic-embed) internally, so callers pass raw text; the recommended default
  /// (bge-small) needs no prefix. If [load] has not completed, implementations
  /// should load first or throw. Throws on failure so callers can fall back
  /// (Req 7.4).
  Future<List<double>> embed(String text);

  /// Embeds many [texts] at once, letting the runtime amortize overhead during
  /// indexing (Req 4.6).
  ///
  /// The returned list has the same length as [texts], and each result vector
  /// (of length [dimension]) corresponds to the input at the same index —
  /// **order is preserved**. Runs off the UI thread. Throws on failure so
  /// callers can fall back (Req 7.4).
  Future<List<List<double>>> embedBatch(List<String> texts);

  /// Releases the Embedding Model and any native resources it holds.
  ///
  /// Called when the project is closed or resources demand it. After [dispose]
  /// the engine must be [load]ed again before further use.
  Future<void> dispose();
}
