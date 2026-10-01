// Desktop smoke integration test for the embedded local-model runtime
// (task 5.4, design §12 "Integration (desktop)").
//
// Validates: Requirements 2.2, 8.5
//
// What this verifies, end-to-end and on-device: with a small GGUF test model
// present, constructing [FllamaLlmEngine], loading it, and generating a reply
// for a short prompt yields a non-empty assistant reply (Req 2.2). The native
// runtime is only attempted on the desktop platforms the feature targets —
// macOS, Windows, Linux (Req 8.5); on any other platform the test is skipped.
//
// ## Gating — why this normally SKIPS
//
// Running real inference needs two things this environment (and CI) does not
// have by default:
//   1. the GGUF Model Asset on disk (roughly ~1 GiB; see [ModelCatalog]), and
//   2. the compiled native llama.cpp runtime for the host desktop platform.
//
// Rather than fail CI where neither is present, the test resolves the model
// path from an environment variable and SKIPS cleanly when it is unset or the
// file is missing. This keeps the default (no model) run green while still
// giving a maintainer a real, on-device check when they point it at a model.
//
// ## How to run it WITH a model present
//
// Download a small instruct GGUF (the app's default is Qwen2.5-1.5B-Instruct
// Q4_K_M — see lib/domain/ai/model_catalog.dart) and point the test at it.
//
// The model path is read two ways so it works under both `flutter test` and a
// device/desktop `integration_test` run:
//
//   * environment variable `SPWRITE_TEST_MODEL_PATH` (read via
//     `Platform.environment`), or
//   * `--dart-define=SPWRITE_TEST_MODEL_PATH=/abs/path` (read via
//     `String.fromEnvironment`).
//
// Examples (macOS/Linux):
//
//   # via an exported env var
//   export SPWRITE_TEST_MODEL_PATH="$HOME/Library/Application Support/spwrite/qwen2.5-1.5b-instruct-q4_k_m.gguf"
//   flutter test integration_test/fllama_engine_smoke_test.dart
//
//   # or via a dart-define (works for `flutter test` and desktop runs)
//   flutter test integration_test/fllama_engine_smoke_test.dart \
//     --dart-define=SPWRITE_TEST_MODEL_PATH=/abs/path/to/model.gguf
//
//   # run on the desktop device (exercises the real native runtime end-to-end)
//   flutter test integration_test/fllama_engine_smoke_test.dart -d macos
//
// With no `SPWRITE_TEST_MODEL_PATH` set (the default), the test is reported as
// skipped, not failed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:spwrite/data/ai/fllama_llm_engine.dart';

/// The environment variable / dart-define name that points the smoke test at a
/// GGUF Model Asset on disk. When unset or the file is missing, the test is
/// skipped so CI without a model stays green (design §12).
const String _kModelPathDefine =
    String.fromEnvironment('SPWRITE_TEST_MODEL_PATH');

/// Resolves the configured test model path from a `--dart-define` first, then
/// falling back to the process environment, so the test works under both
/// `flutter test` and desktop `integration_test` runs. Returns `null` when
/// neither source provides a value.
String? _resolveModelPath() {
  if (_kModelPathDefine.isNotEmpty) return _kModelPathDefine;
  final String? fromEnv = Platform.environment['SPWRITE_TEST_MODEL_PATH'];
  if (fromEnv != null && fromEnv.trim().isNotEmpty) return fromEnv.trim();
  return null;
}

/// The desktop platforms this feature targets first (Req 8.5). The native
/// runtime is only attempted here; other platforms skip.
bool get _isDesktop =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Computes the human-readable reason to skip, or `null` when the test should
/// actually run (desktop host AND a readable model file is present).
String? _skipReason() {
  if (!_isDesktop) {
    return 'Local-model runtime targets desktop (macOS/Windows/Linux) only '
        '(Req 8.5); skipping on ${Platform.operatingSystem}.';
  }
  final String? modelPath = _resolveModelPath();
  if (modelPath == null) {
    return 'No test model configured. Set SPWRITE_TEST_MODEL_PATH (env var or '
        '--dart-define) to a GGUF file to run the desktop smoke test.';
  }
  if (!File(modelPath).existsSync()) {
    return 'Configured test model not found at "$modelPath"; skipping the '
        'desktop smoke test.';
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Evaluated once at collection time: a non-null reason means the test is
  // reported as SKIPPED (never failed) when the gate is not satisfied.
  final String? skipReason = _skipReason();

  test(
    'a prompt yields a non-empty reply from the embedded model (Req 2.2, 8.5)',
    () async {
      // Guarded so the body is inert even if a runner ignores `skip:`.
      final String? modelPath = _resolveModelPath();
      if (skipReason != null || modelPath == null) {
        markTestSkipped(skipReason ?? 'No test model configured.');
        return;
      }

      final FllamaLlmEngine engine = FllamaLlmEngine(
        modelPath: modelPath,
        // Keep the smoke test light: a small context and a short reply cap so
        // it exercises the load → generate → stream path without a long run.
        contextSize: 512,
        defaultMaxTokens: 32,
      );

      final StringBuffer reply = StringBuffer();
      try {
        await engine.load();

        // Collect the streamed deltas; concatenating them yields the full
        // reply per the LlmEngine contract. A generous timeout keeps a stuck
        // runtime from hanging the suite while still allowing a cold start.
        await engine
            .generate(prompt: 'Say hello in one word.', maxTokens: 16)
            .forEach(reply.write)
            .timeout(const Duration(minutes: 2));
      } finally {
        await engine.dispose();
      }

      // Req 2.2: the assistant's reply is generated and non-empty.
      expect(reply.toString().trim(), isNotEmpty);
    },
    skip: skipReason,
  );
}
