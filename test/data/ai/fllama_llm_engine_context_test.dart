// Regression test: fllama splits n_ctx across its parallel slots, so the
// engine must request contextSize * slots for one request to get the full
// window (otherwise a grounded prompt fails with "request (N tokens) exceeds
// the available context size (512 tokens)").

import 'dart:io';

import 'package:fllama/fllama.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spwrite/data/ai/fllama_llm_engine.dart';

void main() {
  test('requests contextSize scaled by fllama parallel slots', () async {
    final Directory dir = await Directory.systemTemp.createTemp('engine_ctx');
    addTearDown(() => dir.delete(recursive: true));
    final File model = File('${dir.path}/m.gguf')..writeAsBytesSync([1, 2, 3]);

    OpenAiRequest? seen;
    final FllamaLlmEngine engine = FllamaLlmEngine(
      modelPath: model.path,
      contextSize: 2048,
      chatRunner: (OpenAiRequest r, FllamaInferenceCallback cb) async {
        seen = r;
        cb('ok', '', true);
        return 1;
      },
      cancelRunner: (_) {},
      loadErrorDetector: (_) => false,
    );
    await engine.load();
    await engine.generate(prompt: 'Who is Zorbac?').join();

    expect(seen, isNotNull);
    expect(seen!.contextSize, 2048 * FllamaLlmEngine.fllamaParallelSlots);
    expect(engine.contextSize, 2048, reason: 'per-request budget unchanged');
  });
}
