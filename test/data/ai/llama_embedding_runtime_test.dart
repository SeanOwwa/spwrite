// Integration-style test for the real llama.cpp embedding FFI runner behind
// FllamaEmbeddingModel.
//
// Validates: Requirements 3.3, 7.4, 8.1
//
// Runs only when both are available locally, otherwise SKIPS:
//   * the embedding GGUF — env SPWRITE_TEST_EMBEDDING_MODEL_PATH, or the
//     catalog file name in the app's macOS Application Support directory;
//   * the native library exporting the llama.cpp C API — env
//     SPWRITE_TEST_LLAMA_LIBRARY, or the fllama.framework inside a built
//     `flutter build macos` app under build/macos.
//
// Example:
//   SPWRITE_TEST_EMBEDDING_MODEL_PATH=/tmp/bge-small-en-v1.5-q8_0.gguf \
//     flutter test test/data/ai/llama_embedding_runtime_test.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:spwrite/data/ai/fllama_embedding_model.dart';

const int _dim = 384;

String? _existing(List<String?> candidates) {
  for (final String? c in candidates) {
    if (c != null && c.isNotEmpty && File(c).existsSync()) return c;
  }
  return null;
}

String? _modelPath() {
  final String home = Platform.environment['HOME'] ?? '';
  return _existing(<String?>[
    Platform.environment['SPWRITE_TEST_EMBEDDING_MODEL_PATH'],
    '$home/Library/Containers/com.example.spwrite/Data/Library/'
        'Application Support/com.example.spwrite/bge-small-en-v1.5-q8_0.gguf',
    '$home/Library/Application Support/com.example.spwrite/'
        'bge-small-en-v1.5-q8_0.gguf',
  ]);
}

String? _libraryPath() {
  const String fw = 'Spwrite.app/Contents/Frameworks/fllama.framework/'
      'Versions/A/fllama';
  return _existing(<String?>[
    Platform.environment['SPWRITE_TEST_LLAMA_LIBRARY'],
    'build/macos/Build/Products/Release/$fw',
    'build/macos/Build/Products/Debug/$fw',
  ]);
}

double _dot(List<double> a, List<double> b) {
  double s = 0;
  for (int i = 0; i < a.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}

void main() {
  final String? modelPath = _modelPath();
  final String? libraryPath = _libraryPath();
  final Object skip = (!Platform.isMacOS)
      ? 'native runner check runs on macOS only'
      : modelPath == null
          ? 'embedding GGUF not found (set SPWRITE_TEST_EMBEDDING_MODEL_PATH)'
          : libraryPath == null
              ? 'fllama native library not found (build macOS or set '
                  'SPWRITE_TEST_LLAMA_LIBRARY)'
              : false;

  test('real FFI runner yields normalized 384-d vectors that rank meaning',
      () async {
    final FllamaEmbeddingModel model = FllamaEmbeddingModel(
      modelPath: modelPath!,
      dimension: _dim,
      modelId: 'bge-small-en-v1.5-q8_0',
      nativeLibraryPath: libraryPath,
    );
    try {
      await model.load();
      final List<List<double>> v = await model.embedBatch(<String>[
        'Zorbac is a green-eyed sorcerer',
        'The sorcerer with green eyes',
        'The ferry leaves at noon',
      ]);
      expect(v, hasLength(3));
      for (final List<double> vec in v) {
        expect(vec, hasLength(_dim));
        final double norm = math.sqrt(_dot(vec, vec));
        expect(norm, closeTo(1.0, 1e-4));
      }
      final double similar = _dot(v[0], v[1]);
      final double unrelated = _dot(v[0], v[2]);
      // ignore: avoid_print
      print('cosine similar=$similar unrelated=$unrelated');
      expect(similar, greaterThan(unrelated));

      // The model stays resident: a second call (query path) is consistent.
      final List<double> again =
          await model.embed('Zorbac is a green-eyed sorcerer');
      expect(_dot(again, v[0]), closeTo(1.0, 1e-4));

      // Long input is truncated to fit the context rather than failing.
      final List<double> long =
          await model.embed(List<String>.filled(2000, 'word').join(' '));
      expect(long, hasLength(_dim));
    } finally {
      await model.dispose();
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('a dimension mismatch is reported clearly, not as unsupported',
      () async {
    final FllamaEmbeddingModel model = FllamaEmbeddingModel(
      modelPath: modelPath!,
      dimension: 768,
      modelId: 'wrong-dim',
      nativeLibraryPath: libraryPath,
    );
    try {
      await expectLater(
        model.embed('hello'),
        throwsA(isA<EmbeddingModelException>()
            .having((EmbeddingModelException e) => e.isUnsupported,
                'isUnsupported', isFalse)
            .having((EmbeddingModelException e) => e.message, 'message',
                contains('384'))),
      );
    } finally {
      await model.dispose();
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('an unloadable library path is reported as unsupported', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('emb');
    final File fake = File('${tmp.path}/model.gguf')..writeAsBytesSync(<int>[1]);
    final FllamaEmbeddingModel model = FllamaEmbeddingModel(
      modelPath: fake.path,
      dimension: _dim,
      modelId: 'x',
      nativeLibraryPath: '${tmp.path}/does-not-exist.dylib',
    );
    try {
      await expectLater(
        model.embed('x'),
        throwsA(isA<EmbeddingModelException>().having(
            (EmbeddingModelException e) => e.isUnsupported,
            'isUnsupported',
            isTrue)),
      );
    } finally {
      await model.dispose();
      await tmp.delete(recursive: true);
    }
  });
}
