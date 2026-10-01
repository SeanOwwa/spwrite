import 'package:flutter_test/flutter_test.dart';
import 'package:spwrite/domain/ai/model_catalog.dart';

void main() {
  ModelMetadata base() => const ModelMetadata(
        id: 'model-1',
        url: 'https://example.com/model.gguf',
        sizeBytes: 1024,
        sha256: 'abc123',
        licenseName: 'Apache-2.0',
        licenseUrl: 'https://example.com/LICENSE',
      );

  group('ModelMetadata construction', () {
    test('stores all fields', () {
      final m = base();

      expect(m.id, 'model-1');
      expect(m.url, 'https://example.com/model.gguf');
      expect(m.sizeBytes, 1024);
      expect(m.sha256, 'abc123');
      expect(m.licenseName, 'Apache-2.0');
      expect(m.licenseUrl, 'https://example.com/LICENSE');
    });
  });

  group('ModelMetadata equality and hashCode', () {
    test('identical field values are equal and share a hashCode', () {
      expect(base(), base());
      expect(base().hashCode, base().hashCode);
    });

    test('differing in any single field are not equal', () {
      expect(base() == base().copyWith(id: 'other'), isFalse);
      expect(base() == base().copyWith(url: 'https://other/'), isFalse);
      expect(base() == base().copyWith(sizeBytes: 2048), isFalse);
      expect(base() == base().copyWith(sha256: 'def456'), isFalse);
      expect(base() == base().copyWith(licenseName: 'MIT'), isFalse);
      expect(base() == base().copyWith(licenseUrl: 'https://other/L'), isFalse);
    });
  });

  group('ModelMetadata copyWith', () {
    test('no arguments returns an equal copy', () {
      expect(base().copyWith(), base());
    });

    test('replaces only the given field', () {
      final copy = base().copyWith(sizeBytes: 4096, licenseName: 'MIT');

      expect(copy.sizeBytes, 4096);
      expect(copy.licenseName, 'MIT');
      // Untouched fields are preserved.
      expect(copy.id, base().id);
      expect(copy.url, base().url);
      expect(copy.sha256, base().sha256);
      expect(copy.licenseUrl, base().licenseUrl);
    });
  });

  group('ModelCatalog default entry', () {
    test('defaultModel is the Qwen2.5-1.5B-Instruct Q4_K_M asset', () {
      const model = ModelCatalog.defaultModel;

      expect(model.id, 'qwen2.5-1.5b-instruct-q4_k_m');
      expect(model.url, contains('Qwen2.5-1.5B-Instruct-Q4_K_M.gguf'));
      expect(model.url, startsWith('https://'));
      expect(model.sizeBytes, 986048768);
      expect(model.sha256,
          '1adf0b11065d8ad2e8123ea110d1ec956dab4ab038eab665614adba04b6c3370');
      expect(model.licenseName, 'Apache-2.0');
      expect(model.licenseUrl, startsWith('https://'));
    });

    test('all contains the default model', () {
      expect(ModelCatalog.all, contains(ModelCatalog.defaultModel));
      expect(ModelCatalog.all, isNotEmpty);
    });
  });

  group('ModelCatalog embedding entry', () {
    test('defaultEmbeddingModel is present and is the bge-small-en-v1.5 asset',
        () {
      const model = ModelCatalog.defaultEmbeddingModel;

      // The embedding entry is present as a distinct ModelMetadata carrying the
      // fields the downloader needs (id + license documented). The vector
      // dimension (384) is a runtime property exposed via
      // EmbeddingModel.dimension, so it is not carried on the catalog entry.
      expect(model, isA<ModelMetadata>());
      expect(model.id, 'bge-small-en-v1.5-q8_0');
      expect(model.licenseName, 'Apache-2.0');
      expect(model.licenseUrl, startsWith('https://'));
      // The bge-small model card / source is documented on the license URL.
      expect(model.licenseUrl, contains('bge-small-en-v1.5'));
    });

    test('is pinned to a real downloadable artifact', () {
      const model = ModelCatalog.defaultEmbeddingModel;

      expect(model.url, startsWith('https://'));
      expect(model.url, contains('bge-small-en-v1.5'));
      expect(model.url, isNot(contains('<')));
      expect(model.sizeBytes, greaterThan(0));
      expect(model.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('is distinct from the chat default model entry', () {
      expect(ModelCatalog.defaultEmbeddingModel,
          isNot(equals(ModelCatalog.defaultModel)));
      expect(ModelCatalog.defaultEmbeddingModel.id,
          isNot(equals(ModelCatalog.defaultModel.id)));
    });

    test('all includes both the chat and embedding entries', () {
      expect(ModelCatalog.all, contains(ModelCatalog.defaultModel));
      expect(ModelCatalog.all, contains(ModelCatalog.defaultEmbeddingModel));
      // Both distinct entries are present.
      expect(ModelCatalog.all.length, greaterThanOrEqualTo(2));
    });
  });
}
