/// Domain layer: the [ModelMetadata] immutable value object describing a
/// downloadable Local Model (the GGUF Model Asset), and the [ModelCatalog] of
/// known entries with its [ModelCatalog.defaultModel] default.
///
/// The Local Model is downloaded once on first use and cached on disk; after
/// that the assistant runs fully offline (Req 3). This catalog captures exactly
/// what the data layer needs to fetch and trust that asset:
///   - a stable [ModelMetadata.id],
///   - the [ModelMetadata.url] of a clearly documented, openly accessible
///     source (Req 3.1, 7.4),
///   - the expected [ModelMetadata.sizeBytes] (so the UI can state the
///     approximate one-time download size, Req 3.1),
///   - the [ModelMetadata.sha256] checksum used to verify integrity before the
///     asset is accepted as ready (Req 3.5), and
///   - the [ModelMetadata.licenseName]/[ModelMetadata.licenseUrl] documenting
///     that the model is openly licensed (Req 7.2).
///
/// The model is chosen as **data, not code** so it can be updated by editing the
/// catalog without touching the download, state, or presentation layers
/// (design §6).
///
/// Like the other domain value objects ([ChatMessage], [Character]),
/// [ModelMetadata] is immutable and supports value equality and [copyWith].
library;

/// Immutable metadata for a downloadable Local Model (a GGUF Model Asset): a
/// stable [id], the download [url], the expected [sizeBytes], the [sha256]
/// integrity checksum, and the [licenseName]/[licenseUrl] documenting its open
/// license (Req 3.1, 3.5, 7.2, 7.4).
class ModelMetadata {
  /// Stable identifier for this model entry (e.g.
  /// `qwen2.5-1.5b-instruct-q4_k_m`). Used to name the cached file and to look
  /// the entry up in the [ModelCatalog].
  final String id;

  /// The download URL of the GGUF Model Asset, pointing at a clearly
  /// documented, openly accessible source (Req 3.1, 7.4).
  final String url;

  /// The expected size of the asset in bytes. Surfaced to the user as the
  /// approximate one-time download size (Req 3.1) and usable as a download
  /// sanity check.
  final int sizeBytes;

  /// The lowercase hex SHA-256 checksum of the complete asset. The download is
  /// verified against this before the asset is accepted as ready, so a
  /// partial/corrupt file is never loaded as if complete (Req 3.5).
  final String sha256;

  /// Human-readable name of the model's license (e.g. `Apache-2.0`),
  /// documenting that the model is openly licensed (Req 7.2).
  final String licenseName;

  /// URL of the model's full license text (Req 7.2).
  final String licenseUrl;

  const ModelMetadata({
    required this.id,
    required this.url,
    required this.sizeBytes,
    required this.sha256,
    required this.licenseName,
    required this.licenseUrl,
  });

  /// Returns a copy with the given fields replaced.
  ModelMetadata copyWith({
    String? id,
    String? url,
    int? sizeBytes,
    String? sha256,
    String? licenseName,
    String? licenseUrl,
  }) {
    return ModelMetadata(
      id: id ?? this.id,
      url: url ?? this.url,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      sha256: sha256 ?? this.sha256,
      licenseName: licenseName ?? this.licenseName,
      licenseUrl: licenseUrl ?? this.licenseUrl,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ModelMetadata &&
        other.id == id &&
        other.url == url &&
        other.sizeBytes == sizeBytes &&
        other.sha256 == sha256 &&
        other.licenseName == licenseName &&
        other.licenseUrl == licenseUrl;
  }

  @override
  int get hashCode =>
      Object.hash(id, url, sizeBytes, sha256, licenseName, licenseUrl);

  @override
  String toString() {
    return 'ModelMetadata(id: $id, sizeBytes: $sizeBytes, '
        'license: $licenseName)';
  }
}

/// The catalog of known Local Models and the [defaultModel] the assistant
/// downloads on first use.
///
/// ## Chosen default model
///
/// **Qwen2.5-1.5B-Instruct** (Q4_K_M GGUF quantization), distributed by the
/// `bartowski` community quantization on Hugging Face:
/// <https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF>.
///
/// It fits the design's target of a small (~1–3B parameter) Q4 GGUF that runs
/// on a normal laptop: roughly 0.92 GiB (986,048,768 bytes) for the Q4_K_M
/// file, small enough for a one-time download and modest RAM use.
///
/// ## License (Req 7.2, 7.4)
///
/// Qwen2.5-1.5B-Instruct is released under the **Apache License 2.0**, a
/// permissive, OSI-approved license fully compatible with a free, open-source
/// application. The GGUF repository is public and not gated, satisfying the
/// requirement that the one-time download come from a clearly documented,
/// openly accessible source. License text:
/// <https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct/blob/main/LICENSE>.
///
/// The [defaultModel.sha256] and [defaultModel.sizeBytes] below are the exact
/// values published for the `Qwen2.5-1.5B-Instruct-Q4_K_M.gguf` file, so the
/// downloader can verify integrity before accepting the asset (Req 3.5).
class ModelCatalog {
  const ModelCatalog._();

  /// The model downloaded on first use of the assistant: Qwen2.5-1.5B-Instruct
  /// (Q4_K_M GGUF), Apache-2.0 licensed, from Hugging Face (Req 3.1, 7.2, 7.4).
  static const ModelMetadata defaultModel = ModelMetadata(
    id: 'qwen2.5-1.5b-instruct-q4_k_m',
    url: 'https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/'
        'resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf?download=true',
    sizeBytes: 986048768,
    sha256:
        '1adf0b11065d8ad2e8123ea110d1ec956dab4ab038eab665614adba04b6c3370',
    licenseName: 'Apache-2.0',
    licenseUrl:
        'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct/blob/main/LICENSE',
  );

  /// The Embedding Model downloaded on first use of semantic retrieval:
  /// **bge-small-en-v1.5** (GGUF), Apache-2.0 licensed, from Hugging Face
  /// (Req 3.1, 3.2, 3.6, 10.2, 10.3).
  ///
  /// ## Chosen default embedding model
  ///
  /// **`bge-small-en-v1.5`** (`BAAI/bge-small-en-v1.5`), distributed as a GGUF
  /// quantization on Hugging Face. It is a small (~33M-parameter) text
  /// embedding model producing **384-dimensional** vectors with a 512-token
  /// context, comfortably covering the ~800-char chunks the indexer produces.
  /// It is chosen because it is small, fast on a normal laptop, and needs **no
  /// task-instruction prefixes** (unlike nomic-embed), keeping the embedding
  /// path simple. The 384 dimension is a property of the model runtime and is
  /// exposed at load time via `EmbeddingModel.dimension`; the catalog carries
  /// only what the downloader needs to fetch and verify the asset.
  ///
  /// ## License (Req 3.6, 7.2)
  ///
  /// `bge-small-en-v1.5` is released under the **Apache License 2.0**, a
  /// permissive, OSI-approved license fully compatible with a free, open-source
  /// application. The published GGUF repository is public and not gated,
  /// satisfying the requirement that the one-time download come from a clearly
  /// documented, openly accessible source (Req 3.1, 3.6). Model card and
  /// license: <https://huggingface.co/BAAI/bge-small-en-v1.5>.
  ///
  /// ## Pinned artifact (open question 2)
  ///
  /// The url / sizeBytes / sha256 are pinned to CompendiumLabs'
  /// bge-small-en-v1.5-q8_0.gguf (sha256 from the Hugging Face LFS pointer),
  /// replacing the original placeholders that were to be pinned from the
  /// final published GGUF artifact, exactly as the chat [defaultModel] values
  /// were pinned.
  static const ModelMetadata defaultEmbeddingModel = ModelMetadata(
    id: 'bge-small-en-v1.5-q8_0',
    // Pinned: CompendiumLabs' published Q8_0 GGUF of BAAI/bge-small-en-v1.5.
    url: 'https://huggingface.co/CompendiumLabs/bge-small-en-v1.5-gguf/'
        'resolve/main/bge-small-en-v1.5-q8_0.gguf?download=true',
    sizeBytes: 36806944,
    sha256:
        'ec38e8da142596baa913124ae50550de284b6916bf59577ef2f0cb9660c2f514',
    licenseName: 'Apache-2.0',
    licenseUrl: 'https://huggingface.co/BAAI/bge-small-en-v1.5',
  );

  /// All models known to the app: the chat [defaultModel] and the embedding
  /// [defaultEmbeddingModel]. The list leaves room to offer alternatives later
  /// without changing the download/state/presentation layers.
  static const List<ModelMetadata> all = <ModelMetadata>[
    defaultModel,
    defaultEmbeddingModel,
  ];
}
