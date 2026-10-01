/// Data layer: [FllamaEmbeddingModel], the concrete [EmbeddingModel] backed by
/// the on-device llama.cpp runtime bundled with the `fllama` package (design §2,
/// Req 3.3, 7.4, 8.1, 10.3).
///
/// This is the **only** place that touches the embedding runtime; every layer
/// above depends solely on the [EmbeddingModel] abstraction, so the runtime — and
/// exactly *how* embeddings are produced — stays a data-layer-only decision
/// (design §2, Req 10.2, 10.3).
///
/// ## Why a runner seam inside the seam (design §2, task 1.1 spike)
///
/// The task 1.1 spike (recorded as a doc-comment on [EmbeddingModel]) confirmed
/// that **`fllama`'s public API does not expose an embeddings entry point** — its
/// Dart surface and native `src/fllama.h` export only chat/inference/tokenize/GPU
/// calls. The bundled llama.cpp *itself* does support embeddings
/// (`llama_set_embeddings`, `LLAMA_POOLING_TYPE_MEAN`, `llama_get_embeddings_seq`),
/// so the decision — kept entirely behind this class — is to reach that
/// capability through a dedicated embedding FFI binding / background isolate
/// rather than a fllama chat call. That binding is [LlamaEmbeddingRuntime]
/// (`llama_embedding_runtime.dart`), the default runner.
///
/// To keep that concrete runtime call swappable *and* to make this class
/// unit-testable without the native binding, the actual "text → vector" call is
/// injected as an [EmbeddingRunner], exactly mirroring how [FllamaLlmEngine]
/// injects its `chatRunner`. Tests drive the model with a deterministic fake
/// runner; production wiring supplies the real llama.cpp-backed runner. Swapping
/// the embedding runtime (a different FFI binding, a different model) never
/// reaches beyond this file.
///
/// ## Off the UI thread (Req 8.1, 9.4)
///
/// Embedding a chunk or a query is CPU-heavy. Like [FllamaLlmEngine] (which runs
/// llama.cpp on fllama's helper isolate), this model keeps embedding work off the
/// caller's isolate: the default runner dispatches the native call onto a
/// long-lived background worker isolate that keeps the model resident, so
/// indexing and retrieval never block the UI.
///
/// ## Throws on failure (Req 7.4)
///
/// Loading and embedding surface failures by **throwing** an
/// [EmbeddingModelException]. That is the contract the [EmbeddingModel] interface
/// promises so the composite retriever can catch it and degrade gracefully to
/// keyword / chat-only grounding rather than break. In particular, when the
/// native llama.cpp library or its symbols are unavailable on this host/build
/// (or its struct layout does not match), [embed] throws an "unsupported" error
/// and the composite falls back to keyword grounding (design §Error Handling;
/// Req 7.1, 7.4).
library;

import 'dart:async';
import 'dart:io';

import '../../domain/ai/embedding_model.dart';
import 'llama_embedding_runtime.dart';

/// The role a piece of text plays in retrieval, used only to select the
/// task-instruction prefix some embedding models require.
///
/// Asymmetric-prefix models (e.g. nomic-embed) expect stored chunks to be
/// prefixed with `search_document:` and queries with `search_query:`. The
/// recommended default (bge-small) needs no prefix, so both roles map to the
/// empty prefix and the distinction is a no-op (design §2 — task-instruction
/// prefixes).
enum EmbeddingTaskRole {
  /// Text being embedded for storage in the index (a document/character chunk).
  document,

  /// Text being embedded to search against the index (a user query).
  query,
}

/// The task-instruction prefixes a model applies to [EmbeddingTaskRole.document]
/// and [EmbeddingTaskRole.query] text before embedding.
///
/// This captures the one model-specific asymmetry [FllamaEmbeddingModel] needs.
/// [none] (both prefixes empty) is correct for bge-small and keeps v1 simple;
/// [nomic] supplies the `search_document:` / `search_query:` prefixes for
/// nomic-embed-style models, so switching models stays a data-layer-only change
/// (design §2).
class EmbeddingPrefixes {
  /// Prefix prepended to document (stored-chunk) text before embedding.
  final String document;

  /// Prefix prepended to query text before embedding.
  final String query;

  const EmbeddingPrefixes({this.document = '', this.query = ''});

  /// No prefixes — correct for symmetric models like bge-small-en-v1.5.
  static const EmbeddingPrefixes none = EmbeddingPrefixes();

  /// The `search_document:` / `search_query:` prefixes used by nomic-embed-style
  /// models.
  static const EmbeddingPrefixes nomic = EmbeddingPrefixes(
    document: 'search_document: ',
    query: 'search_query: ',
  );

  /// Returns the prefix for [role].
  String forRole(EmbeddingTaskRole role) {
    switch (role) {
      case EmbeddingTaskRole.document:
        return document;
      case EmbeddingTaskRole.query:
        return query;
    }
  }
}

/// Signature for the concrete "text → vectors" runtime call, injected so the
/// embedding runtime is swappable and this class is unit-testable without the
/// native binding — mirroring [FllamaLlmEngine]'s injected chat runner.
///
/// Given the absolute [modelPath] of the cached embedding GGUF and a batch of
/// already-prefixed [texts], returns one vector per input **in the same order**,
/// each of length [FllamaEmbeddingModel.dimension]. Implementations run the
/// heavy native work off the caller's isolate. Throws on failure so the model
/// can surface it as an [EmbeddingModelException].
typedef EmbeddingRunner = Future<List<List<double>>> Function({
  required String modelPath,
  required List<String> texts,
  required int dimension,
});

/// Raised when the Embedding Model cannot be loaded or cannot produce
/// embeddings. Carries a human-readable [message] the state/presentation layer
/// can surface (a recoverable, non-blocking status), and an optional [cause]
/// with the underlying error (Req 7.4).
///
/// The [isUnsupported] flag marks the specific case where the bundled runtime
/// does not expose an embeddings entry point on this build/host, so the composite
/// retriever can fall back to keyword grounding permanently rather than retry
/// (design §Error Handling; Req 7.1, 7.4).
class EmbeddingModelException implements Exception {
  /// A human-readable description of what went wrong.
  final String message;

  /// The underlying error, when this exception wraps another failure.
  final Object? cause;

  /// Whether the failure is because the runtime does not support embeddings on
  /// this build/host (as opposed to a missing file or a transient runtime
  /// error). When `true`, callers should fall back permanently until the
  /// embedding runtime seam is satisfied (Req 7.1, 7.4).
  final bool isUnsupported;

  const EmbeddingModelException(
    this.message, {
    this.cause,
    this.isUnsupported = false,
  });

  @override
  String toString() => cause == null
      ? 'EmbeddingModelException: $message'
      : 'EmbeddingModelException: $message ($cause)';
}

/// The embedded-runtime [EmbeddingModel]: loads the cached embedding GGUF and
/// turns text into fixed-length vectors, off the UI thread, throwing on failure.
///
/// The concrete runtime call is delegated to an injected [EmbeddingRunner] so
/// this class owns only the lifecycle, batching, ordering, task-instruction
/// prefixing, and error contract — never the native details (design §2).
class FllamaEmbeddingModel implements EmbeddingModel {
  /// Absolute path to the cached embedding GGUF this model runs. Provided by the
  /// wiring layer from `ModelDownloader` (the already-verified, cached file), so
  /// this class never touches the network — it only loads a file on disk.
  final String modelPath;

  final int _dimension;
  final String _modelId;

  /// The task-instruction prefixes this model applies to document vs query text.
  /// Defaults to [EmbeddingPrefixes.none] (bge-small needs no prefix).
  final EmbeddingPrefixes prefixes;

  final EmbeddingRunner _runner;

  /// Whether [load] has completed successfully (the cached file validated).
  bool _loaded = false;

  /// Whether [dispose] has been called; further use is rejected.
  bool _disposed = false;

  /// Creates an embedding model bound to the GGUF at [modelPath].
  ///
  /// [dimension] and [modelId] come from the catalog entry / model runtime and
  /// stay stable for the life of the model. The [runner] is injected and
  /// defaults to the real llama.cpp-backed runner; tests supply a deterministic
  /// fake. [prefixes] selects any model-specific task-instruction prefixes and
  /// defaults to none (bge-small).
  ///
  /// When no [runner] is given, the model owns a [LlamaEmbeddingRuntime] (a
  /// long-lived worker isolate over the bundled llama.cpp C API) and frees it
  /// on [dispose]. [nativeLibraryPath] overrides where that runtime looks for
  /// the native library (tests point it at a built `fllama.framework`).
  factory FllamaEmbeddingModel({
    required String modelPath,
    required int dimension,
    required String modelId,
    EmbeddingPrefixes prefixes = EmbeddingPrefixes.none,
    EmbeddingRunner? runner,
    String? nativeLibraryPath,
  }) {
    if (runner != null) {
      return FllamaEmbeddingModel._(
        modelPath: modelPath,
        dimension: dimension,
        modelId: modelId,
        prefixes: prefixes,
        runner: runner,
        ownedRuntime: null,
      );
    }
    final LlamaEmbeddingRuntime runtime =
        LlamaEmbeddingRuntime(libraryPath: nativeLibraryPath);
    return FllamaEmbeddingModel._(
      modelPath: modelPath,
      dimension: dimension,
      modelId: modelId,
      prefixes: prefixes,
      runner: runtime.embed,
      ownedRuntime: runtime,
    );
  }

  FllamaEmbeddingModel._({
    required this.modelPath,
    required int dimension,
    required String modelId,
    required this.prefixes,
    required EmbeddingRunner runner,
    required LlamaEmbeddingRuntime? ownedRuntime,
  })  : assert(dimension > 0, 'dimension must be positive'),
        _dimension = dimension,
        _modelId = modelId,
        _runner = runner,
        _ownedRuntime = ownedRuntime;

  /// The native runtime this model created for itself (no runner injected);
  /// released on [dispose].
  final LlamaEmbeddingRuntime? _ownedRuntime;

  @override
  int get dimension => _dimension;

  @override
  String get modelId => _modelId;

  @override
  Future<void> load() async {
    if (_disposed) {
      throw const EmbeddingModelException(
        'The embedding model has been disposed and cannot be loaded again.',
      );
    }
    if (_loaded) return; // Already resident: no-op (per the EmbeddingModel contract).

    // Validate that the cached embedding GGUF is present and non-empty before we
    // ever hand it to the runtime, so a missing/corrupt asset surfaces as a
    // clear, recoverable error rather than failing opaquely deep in native code
    // (mirrors FllamaLlmEngine.load; Req 7.4).
    final File file = File(modelPath);
    bool exists;
    try {
      exists = await file.exists();
    } catch (error) {
      throw EmbeddingModelException(
        'Could not access the embedding model file at "$modelPath".',
        cause: error,
      );
    }
    if (!exists) {
      throw EmbeddingModelException(
        'The embedding model file is missing at "$modelPath". Download the '
        'embedding model and try again.',
      );
    }
    try {
      final int length = await file.length();
      if (length <= 0) {
        throw EmbeddingModelException(
          'The embedding model file at "$modelPath" is empty or corrupt. '
          'Re-download the embedding model and try again.',
        );
      }
    } on EmbeddingModelException {
      rethrow;
    } catch (error) {
      throw EmbeddingModelException(
        'Could not read the embedding model file at "$modelPath".',
        cause: error,
      );
    }

    _loaded = true;
  }

  @override
  Future<List<double>> embed(String text) async {
    final List<List<double>> vectors = await _embedWithRole(
      <String>[text],
      EmbeddingTaskRole.query,
    );
    return vectors.first;
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) {
    return _embedWithRole(texts, EmbeddingTaskRole.document);
  }

  /// Shared path for [embed]/[embedBatch]: ensures the model is loaded, applies
  /// the [role]'s task-instruction prefix to each input, dispatches the batch to
  /// the injected runner (off the UI thread), and validates the runner returned
  /// one correctly-sized vector per input, in order. Throws
  /// [EmbeddingModelException] on any failure so callers can fall back (Req 7.4).
  Future<List<List<double>>> _embedWithRole(
    List<String> texts,
    EmbeddingTaskRole role,
  ) async {
    if (_disposed) {
      throw const EmbeddingModelException(
        'The embedding model has been disposed.',
      );
    }
    // Load-if-needed per the contract; a load failure propagates as a thrown
    // EmbeddingModelException.
    if (!_loaded) {
      await load();
    }

    // An empty batch has an empty result — no need to touch the runtime, and it
    // keeps the order-preserving contract trivially true.
    if (texts.isEmpty) {
      return <List<double>>[];
    }

    final String prefix = prefixes.forRole(role);
    final List<String> prepared = prefix.isEmpty
        ? List<String>.of(texts)
        : <String>[for (final String t in texts) '$prefix$t'];

    late final List<List<double>> vectors;
    try {
      vectors = await _runner(
        modelPath: modelPath,
        texts: prepared,
        dimension: _dimension,
      );
    } on EmbeddingModelException {
      rethrow;
    } catch (error) {
      throw EmbeddingModelException(
        'The embedding model could not embed the provided text.',
        cause: error,
      );
    }

    // Defensive: enforce the runner's order-and-shape contract so a
    // misbehaving runtime is caught here rather than corrupting the index or
    // producing meaningless cosine scores downstream (design §Error Handling).
    if (vectors.length != prepared.length) {
      throw EmbeddingModelException(
        'The embedding runtime returned ${vectors.length} vectors for '
        '${prepared.length} inputs.',
      );
    }
    for (final List<double> vector in vectors) {
      if (vector.length != _dimension) {
        throw EmbeddingModelException(
          'The embedding runtime returned a ${vector.length}-dimensional '
          'vector; expected $_dimension.',
        );
      }
    }
    return vectors;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _loaded = false;
    // Free the resident native model/context and stop the worker isolate when
    // this model owns them; an injected runner manages its own resources.
    await _ownedRuntime?.dispose();
  }
}
