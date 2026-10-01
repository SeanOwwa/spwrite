// Unit tests for FllamaEmbeddingModel driven by an injected fake
// EmbeddingRunner (task 5.2).
//
// Validates: Requirements 3.3, 7.4, 8.1
//
// FllamaEmbeddingModel is the only class that touches the embedding runtime,
// and it delegates the concrete "text -> vectors" call to an injected
// EmbeddingRunner (mirroring how FllamaLlmEngine injects its chatRunner). That
// seam lets these tests exercise every branch of the model's lifecycle,
// batching, ordering, task-instruction prefixing, and error contract without
// the native FFI binding:
//
//   * load() validates the cached GGUF (present + non-empty; missing/empty
//     throws EmbeddingModelException) — the happy path uses a real temp file.
//   * embed() returns a single dimension-length vector; embedBatch() preserves
//     input order and returns correctly-sized vectors.
//   * task-instruction prefixes are applied per role (document vs query) only
//     when the model is configured with them (bge-small uses none).
//   * a wrong vector count or a wrong-dimension vector from the runner surfaces
//     as a thrown EmbeddingModelException (defensive shape check).
//   * dispose() rejects further use.
//   * an empty batch returns empty without ever touching the runner.
//   * the default (production) runner throws an isUnsupported
//     EmbeddingModelException when the native llama.cpp library is not
//     loadable (as on the plain `flutter test` host), so the composite
//     retriever can fall back. The real runner is exercised by
//     llama_embedding_runtime_test.dart when a GGUF + built library exist.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:spwrite/data/ai/fllama_embedding_model.dart';

/// Test dimension used throughout — small enough to hand-write vectors.
const int _dim = 4;

/// The catalog-style id the model is tagged with.
const String _modelId = 'bge-small-en-v1.5';

/// Builds a deterministic dimension-length vector for [text] so a fake runner
/// can produce distinct, order-checkable vectors. The first component encodes
/// the text length; the rest are a fixed ramp. The actual values are irrelevant
/// to the model (it only checks shape/order), but making them distinct lets the
/// order-preservation assertions be meaningful.
List<double> _vectorFor(String text) {
  return <double>[
    text.length.toDouble(),
    1.0,
    2.0,
    3.0,
  ];
}

/// A configurable fake EmbeddingRunner that records what it was called with and
/// returns whatever the test asked it to. This is the embedding analogue of
/// FllamaLlmEngine's fake chatRunner: it stands in for the native binding so the
/// model's own logic (loading, prefixing, ordering, validation) is what's under
/// test.
class _FakeRunner {
  _FakeRunner({
    this.overrideResult,
    this.throwError,
  });

  /// When set, returned verbatim instead of the synthesized result — used to
  /// simulate a misbehaving runtime (wrong count / wrong dimension).
  final List<List<double>>? overrideResult;

  /// When set, thrown instead of returning — simulates a runtime failure.
  final Object? throwError;

  int callCount = 0;
  String? lastModelPath;
  List<String>? lastTexts;
  int? lastDimension;

  Future<List<List<double>>> call({
    required String modelPath,
    required List<String> texts,
    required int dimension,
  }) async {
    callCount++;
    lastModelPath = modelPath;
    lastTexts = List<String>.of(texts);
    lastDimension = dimension;

    final Object? error = throwError;
    if (error != null) {
      throw error;
    }
    if (overrideResult != null) {
      return overrideResult!;
    }
    return <List<double>>[for (final String t in texts) _vectorFor(t)];
  }
}

/// Creates a real, non-empty temp GGUF stand-in and returns its path, so
/// load()'s file validation exercises the happy path against the actual
/// filesystem. The file is registered for teardown by the caller.
Future<File> _makeModelFile(Directory dir) async {
  final File file = File('${dir.path}/model.gguf');
  await file.writeAsBytes(<int>[1, 2, 3, 4]);
  return file;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fllama_embed_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('load() validates the cached model file (Req 3.3, 7.4)', () {
    test('load succeeds for a present, non-empty file', () async {
      final File file = await _makeModelFile(tempDir);
      final _FakeRunner runner = _FakeRunner();
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        runner: runner.call,
      );

      // Should complete without throwing; loading must not touch the runner.
      await model.load();
      expect(runner.callCount, 0);
    });

    test('load is a no-op when already loaded', () async {
      final File file = await _makeModelFile(tempDir);
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        runner: _FakeRunner().call,
      );

      await model.load();
      // Delete the file after the first load; a second load must not re-check
      // and must not throw (proves it short-circuits).
      await file.delete();
      await model.load();
    });

    test('load throws EmbeddingModelException when the file is missing',
        () async {
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: '${tempDir.path}/does_not_exist.gguf',
        dimension: _dim,
        modelId: _modelId,
        runner: _FakeRunner().call,
      );

      await expectLater(
        model.load(),
        throwsA(isA<EmbeddingModelException>()),
      );
    });

    test('load throws EmbeddingModelException when the file is empty',
        () async {
      final File file = File('${tempDir.path}/empty.gguf');
      await file.writeAsBytes(<int>[]);
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        runner: _FakeRunner().call,
      );

      await expectLater(
        model.load(),
        throwsA(isA<EmbeddingModelException>()),
      );
    });
  });

  group('embed() and embedBatch() shape and ordering (Req 8.1)', () {
    test('embed returns a single dimension-length vector', () async {
      final File file = await _makeModelFile(tempDir);
      final _FakeRunner runner = _FakeRunner();
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        runner: runner.call,
      );

      final List<double> vector = await model.embed('hello world');

      expect(vector, hasLength(_dim));
      // The runner was handed exactly the one input.
      expect(runner.lastTexts, <String>['hello world']);
      expect(runner.lastDimension, _dim);
      expect(runner.lastModelPath, file.path);
    });

    test('embed loads the model lazily on first use', () async {
      final File file = await _makeModelFile(tempDir);
      final _FakeRunner runner = _FakeRunner();
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        runner: runner.call,
      );

      // No explicit load() call — embed must load first.
      final List<double> vector = await model.embed('lazy');
      expect(vector, hasLength(_dim));
      expect(runner.callCount, 1);
    });

    test('embedBatch preserves input order and vector sizes', () async {
      final File file = await _makeModelFile(tempDir);
      final _FakeRunner runner = _FakeRunner();
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        runner: runner.call,
      );

      final List<String> inputs = <String>['a', 'bb', 'ccc', 'dddd'];
      final List<List<double>> vectors = await model.embedBatch(inputs);

      expect(vectors, hasLength(inputs.length));
      for (final List<double> v in vectors) {
        expect(v, hasLength(_dim));
      }
      // The synthesized vectors encode input length in component 0, so
      // order-preservation is observable: input i -> vector with length(i).
      for (int i = 0; i < inputs.length; i++) {
        expect(vectors[i][0], inputs[i].length.toDouble());
      }
    });
  });

  group('task-instruction prefixes are applied per role (design §2)', () {
    test('no prefixes (bge-small default) leaves text untouched', () async {
      final File file = await _makeModelFile(tempDir);
      final _FakeRunner runner = _FakeRunner();
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        // prefixes defaults to EmbeddingPrefixes.none
        runner: runner.call,
      );

      await model.embed('a query');
      expect(runner.lastTexts, <String>['a query']);

      await model.embedBatch(<String>['a document']);
      expect(runner.lastTexts, <String>['a document']);
    });

    test('query role uses the query prefix (embed)', () async {
      final File file = await _makeModelFile(tempDir);
      final _FakeRunner runner = _FakeRunner();
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        prefixes: EmbeddingPrefixes.nomic,
        runner: runner.call,
      );

      // embed() embeds with the query role.
      await model.embed('who is the villain');
      expect(runner.lastTexts, <String>['search_query: who is the villain']);
    });

    test('document role uses the document prefix (embedBatch)', () async {
      final File file = await _makeModelFile(tempDir);
      final _FakeRunner runner = _FakeRunner();
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        prefixes: EmbeddingPrefixes.nomic,
        runner: runner.call,
      );

      // embedBatch() embeds with the document role.
      await model.embedBatch(<String>['chapter one', 'chapter two']);
      expect(
        runner.lastTexts,
        <String>[
          'search_document: chapter one',
          'search_document: chapter two',
        ],
      );
    });
  });

  group('runner contract violations surface as thrown errors (Req 7.4)', () {
    test('a runner failure is wrapped as an EmbeddingModelException', () async {
      final File file = await _makeModelFile(tempDir);
      final _FakeRunner runner = _FakeRunner(
        throwError: StateError('native boom'),
      );
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        runner: runner.call,
      );

      await expectLater(
        model.embed('x'),
        throwsA(isA<EmbeddingModelException>()),
      );
    });

    test('an EmbeddingModelException from the runner propagates unchanged',
        () async {
      final File file = await _makeModelFile(tempDir);
      final _FakeRunner runner = _FakeRunner(
        throwError: const EmbeddingModelException(
          'unsupported',
          isUnsupported: true,
        ),
      );
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        runner: runner.call,
      );

      await expectLater(
        model.embed('x'),
        throwsA(
          isA<EmbeddingModelException>()
              .having((EmbeddingModelException e) => e.isUnsupported,
                  'isUnsupported', isTrue),
        ),
      );
    });

    test('a wrong vector count throws EmbeddingModelException', () async {
      final File file = await _makeModelFile(tempDir);
      // Two inputs but the runner returns only one vector.
      final _FakeRunner runner = _FakeRunner(
        overrideResult: <List<double>>[
          <double>[0.0, 1.0, 2.0, 3.0],
        ],
      );
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        runner: runner.call,
      );

      await expectLater(
        model.embedBatch(<String>['one', 'two']),
        throwsA(isA<EmbeddingModelException>()),
      );
    });

    test('a wrong-dimension vector throws EmbeddingModelException', () async {
      final File file = await _makeModelFile(tempDir);
      // Correct count (1) but the vector has the wrong length.
      final _FakeRunner runner = _FakeRunner(
        overrideResult: <List<double>>[
          <double>[0.0, 1.0], // length 2, expected 4
        ],
      );
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        runner: runner.call,
      );

      await expectLater(
        model.embed('x'),
        throwsA(isA<EmbeddingModelException>()),
      );
    });
  });

  group('lifecycle: dispose and empty batch', () {
    test('dispose rejects further embed/embedBatch/load use', () async {
      final File file = await _makeModelFile(tempDir);
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        runner: _FakeRunner().call,
      );

      await model.load();
      await model.dispose();

      await expectLater(
        model.embed('x'),
        throwsA(isA<EmbeddingModelException>()),
      );
      await expectLater(
        model.embedBatch(<String>['x']),
        throwsA(isA<EmbeddingModelException>()),
      );
      await expectLater(
        model.load(),
        throwsA(isA<EmbeddingModelException>()),
      );
    });

    test('dispose is idempotent', () async {
      final File file = await _makeModelFile(tempDir);
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        runner: _FakeRunner().call,
      );

      await model.dispose();
      // A second dispose must not throw.
      await model.dispose();
    });

    test('an empty batch returns empty without touching the runner', () async {
      final File file = await _makeModelFile(tempDir);
      final _FakeRunner runner = _FakeRunner();
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
        runner: runner.call,
      );

      final List<List<double>> vectors = await model.embedBatch(<String>[]);

      expect(vectors, isEmpty);
      expect(runner.callCount, 0);
    });
  });

  group('the default runner without a native library (design §Error Handling)', () {
    test('the default runner throws an isUnsupported EmbeddingModelException',
        () async {
      final File file = await _makeModelFile(tempDir);
      // No runner injected: the production default runner is used. Under
      // `flutter test` the bundled fllama library is not on the load path.
      final FllamaEmbeddingModel model = FllamaEmbeddingModel(
        modelPath: file.path,
        dimension: _dim,
        modelId: _modelId,
      );
      addTearDown(model.dispose);

      await expectLater(
        model.embed('x'),
        throwsA(
          isA<EmbeddingModelException>()
              .having((EmbeddingModelException e) => e.isUnsupported,
                  'isUnsupported', isTrue),
        ),
      );
    });
  });
}
