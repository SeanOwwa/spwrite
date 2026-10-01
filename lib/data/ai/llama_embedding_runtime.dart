/// Data layer: [LlamaEmbeddingRuntime], the real llama.cpp-backed embedding
/// runner behind [FllamaEmbeddingModel] (design §2 open question 1, Req 3.3,
/// 7.4, 8.1, 10.3).
///
/// `fllama`'s Dart API only exposes text generation, but the `fllama` native
/// library it bundles is a full llama.cpp build that exports the C API
/// (`llama_model_load_from_file`, `llama_init_from_model`, `llama_tokenize`,
/// `llama_encode`/`llama_decode`, `llama_get_embeddings_seq`, ...). This file
/// binds those symbols directly with `dart:ffi`.
///
/// ## Struct layouts
///
/// [_LlamaModelParams], [_LlamaContextParams] and [_LlamaBatch] mirror the C
/// structs in the vendored header
/// `fllama@f624e4bf/src/llama.cpp/include/llama.h` field-for-field. A layout
/// mismatch would be silent memory corruption, so after fetching the library's
/// own defaults (`llama_*_default_params`) the worker checks a fingerprint of
/// known default values (see [_checkDefaultsFingerprint]); if it does not match,
/// the runtime refuses to proceed and reports "unsupported", so the composite
/// retriever falls back to keyword grounding instead of crashing.
///
/// ## Threading
///
/// All native work runs on one long-lived worker isolate that keeps the model
/// and context resident across calls; [dispose] frees them and ends the
/// isolate. The UI isolate only exchanges plain messages (Req 8.1, 9.4).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

import 'fllama_embedding_model.dart';

/// Owns the embedding worker isolate and exposes an [EmbeddingRunner]-shaped
/// [embed] call. Create one per [FllamaEmbeddingModel]; call [dispose] to free
/// the native model/context.
class LlamaEmbeddingRuntime {
  /// Explicit path of the native library exporting the llama.cpp C API. When
  /// `null`, the platform default is used (the bundled `fllama` library).
  /// Tests point this at a built `fllama.framework` binary.
  final String? libraryPath;

  /// Maximum tokens per input; longer inputs are truncated. bge-small was
  /// trained with a 512-token context.
  final int maxTokens;

  /// Number of model layers offloaded to the GPU. Defaults to 0 (CPU): the
  /// embedding model is tiny and this avoids contending with the chat model.
  final int gpuLayers;

  LlamaEmbeddingRuntime({
    this.libraryPath,
    this.maxTokens = 512,
    this.gpuLayers = 0,
  }) : assert(maxTokens > 2, 'maxTokens must leave room for special tokens');

  Isolate? _isolate;
  SendPort? _workerPort;
  ReceivePort? _replies;
  Future<void>? _starting;
  int _nextId = 0;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  bool _disposed = false;

  /// Embeds [texts] (already prefixed) with the GGUF at [modelPath], returning
  /// one L2-normalized vector of length [dimension] per input, in order.
  ///
  /// Throws [EmbeddingModelException]; `isUnsupported` is set when the native
  /// library/symbols are unavailable or the struct layout check fails.
  Future<List<List<double>>> embed({
    required String modelPath,
    required List<String> texts,
    required int dimension,
  }) async {
    if (_disposed) {
      throw const EmbeddingModelException('The embedding runtime is disposed.');
    }
    if (texts.isEmpty) return <List<double>>[];
    await _ensureWorker();
    final Object? reply = await _request(<String, Object?>{
      'cmd': 'embed',
      'libraryPath': libraryPath,
      'modelPath': modelPath,
      'texts': texts,
      'dimension': dimension,
      'maxTokens': maxTokens,
      'gpuLayers': gpuLayers,
    });
    final List<Object?> raw = reply! as List<Object?>;
    return <List<double>>[
      for (final Object? v in raw) List<double>.from(v! as List<Object?>),
    ];
  }

  /// Frees the native model/context and terminates the worker isolate.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _starting;
    } catch (_) {}
    if (_workerPort != null) {
      try {
        await _request(<String, Object?>{'cmd': 'dispose'})
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        // Best effort: fall through to killing the isolate.
      }
    }
    _shutdown(const EmbeddingModelException('The embedding runtime is disposed.'));
  }

  Future<void> _ensureWorker() {
    if (_workerPort != null) return Future<void>.value();
    return _starting ??= _spawn().catchError((Object error) {
      _starting = null;
      throw EmbeddingModelException(
        'Could not start the embedding worker.',
        cause: error,
      );
    });
  }

  Future<void> _spawn() async {
    final ReceivePort replies = ReceivePort('spwrite-embedding-replies');
    _replies = replies;
    final Completer<SendPort> ready = Completer<SendPort>();
    replies.listen((Object? message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message == null) {
        // onExit: the worker is gone; fail every pending call so callers fall
        // back instead of hanging. A later embed() spawns a fresh worker.
        if (!ready.isCompleted) {
          ready.completeError(StateError('embedding worker exited'));
        }
        _shutdown(const EmbeddingModelException(
          'The embedding worker stopped unexpectedly.',
        ));
        return;
      }
      if (message is Map) {
        final Completer<Object?>? c = _pending.remove(message['id'] as int);
        if (c == null) return;
        if (message['ok'] == true) {
          c.complete(message['result']);
        } else {
          c.completeError(EmbeddingModelException(
            message['error'] as String? ?? 'Unknown embedding error.',
            isUnsupported: message['unsupported'] == true,
          ));
        }
      }
    });
    _isolate = await Isolate.spawn<SendPort>(
      _workerMain,
      replies.sendPort,
      debugName: 'spwrite-embedding',
      onExit: replies.sendPort, // delivers `null` when the worker exits
    );
    _workerPort = await ready.future;
  }

  Future<Object?> _request(Map<String, Object?> message) {
    final SendPort? port = _workerPort;
    if (port == null) {
      return Future<Object?>.error(
        const EmbeddingModelException('The embedding worker is not running.'),
      );
    }
    final int id = _nextId++;
    final Completer<Object?> completer = Completer<Object?>();
    _pending[id] = completer;
    port.send(<String, Object?>{...message, 'id': id});
    return completer.future;
  }

  void _shutdown(EmbeddingModelException reason) {
    for (final Completer<Object?> c in _pending.values) {
      if (!c.isCompleted) c.completeError(reason);
    }
    _pending.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _workerPort = null;
    _replies?.close();
    _replies = null;
    _starting = null;
  }
}

// ---------------------------------------------------------------------------
// Worker isolate
// ---------------------------------------------------------------------------

/// Entry point of the embedding worker isolate. Handles `embed` / `dispose`
/// requests sequentially; native state lives in a single [_Engine].
void _workerMain(SendPort replyTo) {
  final ReceivePort inbox = ReceivePort('spwrite-embedding-worker');
  replyTo.send(inbox.sendPort);
  _Engine? engine;
  inbox.listen((Object? raw) {
    // onExit (null) / onError ([error, stack]) messages arrive on the main
    // side's port, never here; every message here is a request map.
    if (raw is! Map) return;
    final int id = raw['id'] as int;
    final String cmd = raw['cmd'] as String;
    if (cmd == 'dispose') {
      engine?.free();
      engine = null;
      replyTo.send(<String, Object?>{'id': id, 'ok': true, 'result': null});
      inbox.close();
      return;
    }
    try {
      final _Engine e = engine ??= _Engine(
        _LlamaApi.open(raw['libraryPath'] as String?),
      );
      final List<List<double>> vectors = e.embedAll(
        modelPath: raw['modelPath'] as String,
        texts: List<String>.from(raw['texts'] as List<Object?>),
        dimension: raw['dimension'] as int,
        maxTokens: raw['maxTokens'] as int,
        gpuLayers: raw['gpuLayers'] as int,
      );
      replyTo.send(<String, Object?>{'id': id, 'ok': true, 'result': vectors});
    } on EmbeddingModelException catch (error) {
      replyTo.send(<String, Object?>{
        'id': id,
        'ok': false,
        'error': error.cause == null
            ? error.message
            : '${error.message} (${error.cause})',
        'unsupported': error.isUnsupported,
      });
    } catch (error) {
      replyTo.send(<String, Object?>{
        'id': id,
        'ok': false,
        'error': 'Embedding failed: $error',
        'unsupported': false,
      });
    }
  });
}

/// Native model + context + reusable batch, resident for the worker's life.
class _Engine {
  final _LlamaApi api;

  _Engine(this.api);

  Pointer<Void> _model = nullptr;
  Pointer<Void> _ctx = nullptr;
  Pointer<Void> _vocab = nullptr;
  _LlamaBatch? _batch;
  String? _modelPath;
  int _gpuLayers = 0;
  int _batchCapacity = 0;
  int _nEmbd = 0;

  List<List<double>> embedAll({
    required String modelPath,
    required List<String> texts,
    required int dimension,
    required int maxTokens,
    required int gpuLayers,
  }) {
    _ensureLoaded(modelPath, maxTokens, gpuLayers);
    if (_nEmbd != dimension) {
      throw EmbeddingModelException(
        'The embedding model at "$modelPath" produces $_nEmbd-dimensional '
        'vectors; expected $dimension.',
      );
    }
    return <List<double>>[for (final String t in texts) _embedOne(t)];
  }

  void _ensureLoaded(String modelPath, int maxTokens, int gpuLayers) {
    if (_ctx != nullptr &&
        _modelPath == modelPath &&
        _gpuLayers == gpuLayers &&
        _batchCapacity == maxTokens) {
      return;
    }
    free();

    final _LlamaModelParams mparams = api.modelDefaultParams();
    final _LlamaContextParams cparams = api.contextDefaultParams();
    _checkDefaultsFingerprint(mparams, cparams);

    if (!File(modelPath).existsSync()) {
      throw EmbeddingModelException(
        'The embedding model file is missing at "$modelPath".',
      );
    }

    mparams.nGpuLayers = gpuLayers;
    final Pointer<Utf8> pathPtr = modelPath.toNativeUtf8();
    try {
      _model = api.modelLoadFromFile(pathPtr, mparams);
    } finally {
      malloc.free(pathPtr);
    }
    if (_model == nullptr) {
      throw EmbeddingModelException(
        'llama.cpp could not load the embedding model at "$modelPath".',
      );
    }

    int nCtx = maxTokens;
    final int nCtxTrain = api.modelNCtxTrain(_model);
    if (nCtxTrain > 0 && nCtxTrain < nCtx) nCtx = nCtxTrain;

    cparams
      ..embeddings = true
      ..nCtx = nCtx
      ..nBatch = nCtx
      ..nUbatch = nCtx
      ..nSeqMax = 1;
    _ctx = api.initFromModel(_model, cparams);
    if (_ctx == nullptr) {
      free();
      throw const EmbeddingModelException(
        'llama.cpp could not create an embedding context.',
      );
    }
    if (api.poolingType(_ctx) == _poolingRank) {
      free();
      throw const EmbeddingModelException(
        'The embedding model is a reranker (rank pooling), not an embedder.',
      );
    }
    _vocab = api.modelGetVocab(_model);
    _nEmbd = api.modelNEmbd(_model);
    _batch = api.batchInit(nCtx, 0, 1);
    _batchCapacity = maxTokens;
    _modelPath = modelPath;
    _gpuLayers = gpuLayers;
  }

  /// The effective token limit (the context size actually allocated).
  int get _tokenLimit => _batch == null ? 0 : api.nCtx(_ctx);

  List<double> _embedOne(String text) {
    final List<int> tokens = _tokenize(text);
    if (tokens.isEmpty) {
      // Nothing to embed (empty text without special tokens): a zero vector
      // scores 0 against everything and so never surfaces as relevant.
      return List<double>.filled(_nEmbd, 0.0);
    }
    final int limit = _tokenLimit;
    List<int> input = tokens;
    if (input.length > limit) {
      // Keep the leading tokens (incl. [CLS]) and the trailing special token
      // (e.g. [SEP]) so the encoder still sees a well-formed sequence.
      input = <int>[...tokens.sublist(0, limit - 1), tokens.last];
    }

    final _LlamaBatch batch = _batch!;
    for (int i = 0; i < input.length; i++) {
      batch.token[i] = input[i];
      batch.pos[i] = i;
      batch.nSeqId[i] = 1;
      batch.seqId[i][0] = 0;
      batch.logits[i] = 1;
    }
    batch.nTokens = input.length;

    final Pointer<Void> memory = api.getMemory(_ctx);
    api.memoryClear(memory, true);
    // Encoder-only models (BERT) have no memory; llama_encode is the direct
    // path for them. Decoder models go through llama_decode.
    final int rc = memory == nullptr
        ? api.encode(_ctx, batch)
        : api.decode(_ctx, batch);
    if (rc != 0) {
      throw EmbeddingModelException('llama.cpp failed to embed text (code $rc).');
    }

    final List<double> out = List<double>.filled(_nEmbd, 0.0);
    final Pointer<Float> pooled = api.getEmbeddingsSeq(_ctx, 0);
    if (pooled != nullptr) {
      for (int j = 0; j < _nEmbd; j++) {
        out[j] = pooled[j];
      }
    } else {
      // No pooling configured: mean of the per-token embeddings.
      int count = 0;
      for (int i = 0; i < input.length; i++) {
        final Pointer<Float> row = api.getEmbeddingsIth(_ctx, i);
        if (row == nullptr) continue;
        for (int j = 0; j < _nEmbd; j++) {
          out[j] += row[j];
        }
        count++;
      }
      if (count == 0) {
        throw const EmbeddingModelException(
          'llama.cpp returned no embeddings for the text.',
        );
      }
      for (int j = 0; j < _nEmbd; j++) {
        out[j] /= count;
      }
    }
    return _l2Normalize(out);
  }

  List<int> _tokenize(String text) {
    final List<int> bytes = utf8.encode(text);
    final Pointer<Uint8> textPtr = malloc<Uint8>(bytes.length + 1);
    try {
      textPtr.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      int capacity = bytes.length + 16;
      for (int attempt = 0; attempt < 2; attempt++) {
        final Pointer<Int32> buf = malloc<Int32>(capacity);
        try {
          final int n = api.tokenize(
            _vocab,
            textPtr.cast<Utf8>(),
            bytes.length,
            buf,
            capacity,
            true, // add_special: [CLS] ... [SEP]
            false, // parse_special: treat user text literally
          );
          if (n >= 0) return List<int>.of(buf.asTypedList(n));
          capacity = -n; // Buffer too small: retry with the exact size.
        } finally {
          malloc.free(buf);
        }
      }
      throw const EmbeddingModelException('llama.cpp could not tokenize text.');
    } finally {
      malloc.free(textPtr);
    }
  }

  void free() {
    final _LlamaBatch? batch = _batch;
    if (batch != null) api.batchFree(batch);
    _batch = null;
    if (_ctx != nullptr) api.free(_ctx);
    _ctx = nullptr;
    if (_model != nullptr) api.modelFree(_model);
    _model = nullptr;
    _vocab = nullptr;
    _modelPath = null;
    _batchCapacity = 0;
    _nEmbd = 0;
  }
}

List<double> _l2Normalize(List<double> v) {
  double sum = 0;
  for (final double x in v) {
    sum += x * x;
  }
  final double norm = math.sqrt(sum);
  if (norm == 0 || norm.isNaN) return v;
  return <double>[for (final double x in v) x / norm];
}

/// Verifies that the default params read through our Dart struct mirrors carry
/// the exact defaults `llama_model_default_params` / `llama_context_default_params`
/// set in the vendored llama.cpp sources. A mismatch means the native library
/// was built from a different `llama.h` than the one mirrored here, so the
/// runtime reports "unsupported" rather than risk passing corrupt structs.
void _checkDefaultsFingerprint(
  _LlamaModelParams m,
  _LlamaContextParams c,
) {
  final bool ok = m.devices == nullptr &&
      m.nGpuLayers == -1 &&
      m.mainGpu == 0 &&
      m.tensorSplit == nullptr &&
      m.kvOverrides == nullptr &&
      !m.vocabOnly &&
      !m.checkTensors &&
      m.useExtraBufts &&
      !m.noHost &&
      !m.noAlloc &&
      !m.loadMtp &&
      c.nCtx == 512 &&
      c.nBatch == 2048 &&
      c.nUbatch == 512 &&
      c.nSeqMax == 1 &&
      c.nRsSeq == 0 &&
      c.nOutputsMax == 0 &&
      c.nOutputsMaxPerSeq == 1 &&
      c.poolingType == -1 &&
      c.ropeFreqBase == 0.0 &&
      c.yarnExtFactor == -1.0 &&
      c.yarnOrigCtx == 0 &&
      c.defragThold == -1.0 &&
      c.cbEval == nullptr &&
      c.abortCallback == nullptr &&
      !c.embeddings &&
      c.offloadKqv &&
      c.noPerf &&
      c.opOffload &&
      c.swaFull &&
      !c.kvUnified &&
      c.samplers == nullptr &&
      c.nSamplers == 0 &&
      c.ctxOther == nullptr;
  if (!ok) {
    throw const EmbeddingModelException(
      'The bundled llama.cpp library does not match the expected API layout; '
      'semantic retrieval is disabled on this build.',
      isUnsupported: true,
    );
  }
}

// ---------------------------------------------------------------------------
// FFI bindings — mirrors fllama@f624e4bf src/llama.cpp/include/llama.h
// ---------------------------------------------------------------------------

const int _poolingRank = 4; // LLAMA_POOLING_TYPE_RANK

/// `struct llama_model_params` (llama.h).
final class _LlamaModelParams extends Struct {
  external Pointer<Void> devices; // ggml_backend_dev_t *
  external Pointer<Void> tensorBuftOverrides;
  @Int32()
  external int nGpuLayers;
  @Int32()
  external int splitMode; // enum llama_split_mode
  @Int32()
  external int loadMode; // enum llama_load_mode
  @Int32()
  external int mainGpu;
  external Pointer<Float> tensorSplit;
  external Pointer<Void> progressCallback;
  external Pointer<Void> progressCallbackUserData;
  external Pointer<Void> kvOverrides;
  @Bool()
  external bool vocabOnly;
  @Bool()
  external bool checkTensors;
  @Bool()
  external bool useExtraBufts;
  @Bool()
  external bool noHost;
  @Bool()
  external bool noAlloc;
  @Bool()
  external bool loadMtp;
}

/// `struct llama_context_params` (llama.h).
final class _LlamaContextParams extends Struct {
  @Uint32()
  external int nCtx;
  @Uint32()
  external int nBatch;
  @Uint32()
  external int nUbatch;
  @Uint32()
  external int nSeqMax;
  @Uint32()
  external int nRsSeq;
  @Uint32()
  external int nOutputsMax;
  @Uint32()
  external int nOutputsMaxPerSeq;
  @Int32()
  external int nThreads;
  @Int32()
  external int nThreadsBatch;
  @Int32()
  external int ctxType; // enum llama_context_type
  @Int32()
  external int ropeScalingType; // enum llama_rope_scaling_type
  @Int32()
  external int poolingType; // enum llama_pooling_type
  @Int32()
  external int attentionType; // enum llama_attention_type
  @Int32()
  external int flashAttnType; // enum llama_flash_attn_type
  @Float()
  external double ropeFreqBase;
  @Float()
  external double ropeFreqScale;
  @Float()
  external double yarnExtFactor;
  @Float()
  external double yarnAttnFactor;
  @Float()
  external double yarnBetaFast;
  @Float()
  external double yarnBetaSlow;
  @Uint32()
  external int yarnOrigCtx;
  @Float()
  external double defragThold;
  external Pointer<Void> cbEval;
  external Pointer<Void> cbEvalUserData;
  @Int32()
  external int typeK; // enum ggml_type
  @Int32()
  external int typeV; // enum ggml_type
  external Pointer<Void> abortCallback;
  external Pointer<Void> abortCallbackData;
  @Bool()
  external bool embeddings;
  @Bool()
  external bool offloadKqv;
  @Bool()
  external bool noPerf;
  @Bool()
  external bool opOffload;
  @Bool()
  external bool swaFull;
  @Bool()
  external bool kvUnified;
  external Pointer<Void> samplers; // struct llama_sampler_seq_config *
  @Size()
  external int nSamplers;
  external Pointer<Void> ctxOther; // struct llama_context *
}

/// `struct llama_batch` (llama.h).
final class _LlamaBatch extends Struct {
  @Int32()
  external int nTokens;
  external Pointer<Int32> token;
  external Pointer<Float> embd;
  external Pointer<Int32> pos;
  external Pointer<Int32> nSeqId;
  external Pointer<Pointer<Int32>> seqId;
  external Pointer<Int8> logits;
}

/// Resolved llama.cpp entry points.
class _LlamaApi {
  final void Function() backendInit;
  final _LlamaModelParams Function() modelDefaultParams;
  final _LlamaContextParams Function() contextDefaultParams;
  final Pointer<Void> Function(Pointer<Utf8>, _LlamaModelParams)
      modelLoadFromFile;
  final Pointer<Void> Function(Pointer<Void>, _LlamaContextParams)
      initFromModel;
  final int Function(Pointer<Void>) modelNEmbd;
  final int Function(Pointer<Void>) modelNCtxTrain;
  final Pointer<Void> Function(Pointer<Void>) modelGetVocab;
  final int Function(Pointer<Void>) poolingType;
  final int Function(Pointer<Void>) nCtx;
  final int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Int32>, int,
      bool, bool) tokenize;
  final _LlamaBatch Function(int, int, int) batchInit;
  final void Function(_LlamaBatch) batchFree;
  final int Function(Pointer<Void>, _LlamaBatch) encode;
  final int Function(Pointer<Void>, _LlamaBatch) decode;
  final Pointer<Float> Function(Pointer<Void>, int) getEmbeddingsSeq;
  final Pointer<Float> Function(Pointer<Void>, int) getEmbeddingsIth;
  final Pointer<Void> Function(Pointer<Void>) getMemory;
  final void Function(Pointer<Void>, bool) memoryClear;
  final void Function(Pointer<Void>) free;
  final void Function(Pointer<Void>) modelFree;

  _LlamaApi._(DynamicLibrary lib)
      : backendInit = lib.lookupFunction<Void Function(), void Function()>(
            'llama_backend_init'),
        modelDefaultParams = lib.lookupFunction<_LlamaModelParams Function(),
            _LlamaModelParams Function()>('llama_model_default_params'),
        contextDefaultParams = lib.lookupFunction<
            _LlamaContextParams Function(),
            _LlamaContextParams Function()>('llama_context_default_params'),
        modelLoadFromFile = lib.lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>, _LlamaModelParams),
            Pointer<Void> Function(
                Pointer<Utf8>, _LlamaModelParams)>('llama_model_load_from_file'),
        initFromModel = lib.lookupFunction<
            Pointer<Void> Function(Pointer<Void>, _LlamaContextParams),
            Pointer<Void> Function(
                Pointer<Void>, _LlamaContextParams)>('llama_init_from_model'),
        modelNEmbd = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('llama_model_n_embd'),
        modelNCtxTrain = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('llama_model_n_ctx_train'),
        modelGetVocab = lib.lookupFunction<
            Pointer<Void> Function(Pointer<Void>),
            Pointer<Void> Function(Pointer<Void>)>('llama_model_get_vocab'),
        poolingType = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('llama_pooling_type'),
        nCtx = lib.lookupFunction<Uint32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('llama_n_ctx'),
        tokenize = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32, Pointer<Int32>,
                Int32, Bool, Bool),
            int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Int32>, int,
                bool, bool)>('llama_tokenize'),
        batchInit = lib.lookupFunction<
            _LlamaBatch Function(Int32, Int32, Int32),
            _LlamaBatch Function(int, int, int)>('llama_batch_init'),
        batchFree = lib.lookupFunction<Void Function(_LlamaBatch),
            void Function(_LlamaBatch)>('llama_batch_free'),
        encode = lib.lookupFunction<Int32 Function(Pointer<Void>, _LlamaBatch),
            int Function(Pointer<Void>, _LlamaBatch)>('llama_encode'),
        decode = lib.lookupFunction<Int32 Function(Pointer<Void>, _LlamaBatch),
            int Function(Pointer<Void>, _LlamaBatch)>('llama_decode'),
        getEmbeddingsSeq = lib.lookupFunction<
            Pointer<Float> Function(Pointer<Void>, Int32),
            Pointer<Float> Function(
                Pointer<Void>, int)>('llama_get_embeddings_seq'),
        getEmbeddingsIth = lib.lookupFunction<
            Pointer<Float> Function(Pointer<Void>, Int32),
            Pointer<Float> Function(
                Pointer<Void>, int)>('llama_get_embeddings_ith'),
        getMemory = lib.lookupFunction<Pointer<Void> Function(Pointer<Void>),
            Pointer<Void> Function(Pointer<Void>)>('llama_get_memory'),
        memoryClear = lib.lookupFunction<Void Function(Pointer<Void>, Bool),
            void Function(Pointer<Void>, bool)>('llama_memory_clear'),
        free = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('llama_free'),
        modelFree = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('llama_model_free');

  /// Every symbol the binding needs; checked up front so a library missing any
  /// of them is reported as "unsupported" instead of throwing mid-call.
  static const List<String> _requiredSymbols = <String>[
    'llama_backend_init',
    'llama_model_default_params',
    'llama_context_default_params',
    'llama_model_load_from_file',
    'llama_init_from_model',
    'llama_model_n_embd',
    'llama_model_n_ctx_train',
    'llama_model_get_vocab',
    'llama_pooling_type',
    'llama_n_ctx',
    'llama_tokenize',
    'llama_batch_init',
    'llama_batch_free',
    'llama_encode',
    'llama_decode',
    'llama_get_embeddings_seq',
    'llama_get_embeddings_ith',
    'llama_get_memory',
    'llama_memory_clear',
    'llama_free',
    'llama_model_free',
  ];

  /// Opens the native library ([path] if given, else the platform's bundled
  /// `fllama` library) and resolves every symbol, then initializes the
  /// backend. Throws an `isUnsupported` [EmbeddingModelException] when the
  /// library or any symbol is unavailable.
  static _LlamaApi open(String? path) {
    final DynamicLibrary? lib = _openLibrary(path);
    if (lib == null) {
      throw const EmbeddingModelException(
        'The llama.cpp runtime library is not available on this build; '
        'semantic retrieval is unavailable and keyword grounding will be used.',
        isUnsupported: true,
      );
    }
    for (final String symbol in _requiredSymbols) {
      if (!lib.providesSymbol(symbol)) {
        throw EmbeddingModelException(
          'The bundled llama.cpp runtime does not export "$symbol"; semantic '
          'retrieval is unavailable and keyword grounding will be used.',
          isUnsupported: true,
        );
      }
    }
    final _LlamaApi api = _LlamaApi._(lib);
    api.backendInit();
    return api;
  }

  static DynamicLibrary? _openLibrary(String? path) {
    DynamicLibrary? tryOpen(String name) {
      try {
        final DynamicLibrary lib = DynamicLibrary.open(name);
        return lib.providesSymbol('llama_backend_init') ? lib : null;
      } catch (_) {
        return null;
      }
    }

    if (path != null) return tryOpen(path);
    if (Platform.isMacOS || Platform.isIOS) {
      final DynamicLibrary? framework = tryOpen('fllama.framework/fllama');
      if (framework != null) return framework;
      // The app binary links the plugin framework, so its symbols may already
      // be visible process-wide.
      final DynamicLibrary process = DynamicLibrary.process();
      return process.providesSymbol('llama_backend_init') ? process : null;
    }
    if (Platform.isWindows) return tryOpen('fllama.dll');
    if (Platform.isLinux || Platform.isAndroid) return tryOpen('libfllama.so');
    return null;
  }
}
