/// Data layer: pure encoding and similarity math for the on-device vector
/// index (design §Data Models — Embedding encoding).
///
/// [VectorCodec] is the single place that decides how an embedding
/// `List<double>` is turned into the bytes stored in the `ai_chunk_embeddings`
/// `embedding` BLOB and back again, and how two vectors are compared. Keeping
/// this logic pure and free of any database, model, or Flutter dependency lets
/// the repository, retriever, and indexer all share one definition and lets it
/// be property-tested in isolation (Req 4.1; design §Testing Strategy).
///
/// **Encoding.** A vector of `dim` values is stored as **little-endian Float32**
/// — exactly `dim * 4` bytes (Req 4.1; design §Embedding encoding). Little-endian
/// is written and read explicitly rather than relying on the host's native byte
/// order, so a store written on one machine decodes identically on another.
/// Float32 halves storage versus Float64 with negligible cosine-accuracy loss
/// for retrieval.
///
/// **Normalization for cosine.** Vectors are **L2-normalized before storage**
/// (and the query vector normalized at retrieval), so cosine similarity reduces
/// to a plain dot product: `similarity(a, b) = Σ aᵢbᵢ` for unit vectors. This
/// makes scoring cheap and the resulting `score` directly comparable to a
/// `minSimilarity` relevance floor (design §Embedding encoding, §Retrieval
/// Budget). Identical unit vectors score `1.0`; orthogonal ones score `0.0`.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Stateless helpers for encoding, decoding, normalizing, and comparing
/// embedding vectors. All methods are pure and side-effect-free.
///
/// The class is not meant to be instantiated; its members are static so callers
/// use it as a namespace (`VectorCodec.encode(...)`).
abstract final class VectorCodec {
  /// Number of bytes used to store a single Float32 vector component.
  static const int _bytesPerFloat = 4;

  /// Encodes [vector] into a little-endian Float32 byte buffer of exactly
  /// `vector.length * 4` bytes (Req 4.1).
  ///
  /// Each value is narrowed to Float32 precision, matching what [decode] will
  /// read back. An empty vector yields an empty (zero-length) buffer. Callers
  /// that store vectors for cosine search should pass an already
  /// [normalize]d vector so the stored bytes are unit-length.
  static Uint8List encode(List<double> vector) {
    final ByteData data = ByteData(vector.length * _bytesPerFloat);
    for (int i = 0; i < vector.length; i++) {
      data.setFloat32(i * _bytesPerFloat, vector[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  /// Decodes a little-endian Float32 [bytes] buffer back into a list of doubles
  /// (Req 4.1).
  ///
  /// The buffer length must be a whole multiple of 4; otherwise the bytes are
  /// not a valid Float32 vector and an [ArgumentError] is thrown so a corrupt or
  /// mis-shaped row is caught rather than silently mis-decoded (design §Error
  /// Handling — index corruption). Each 4-byte little-endian group becomes one
  /// double, so the result has `bytes.length ~/ 4` elements.
  static List<double> decode(Uint8List bytes) {
    if (bytes.length % _bytesPerFloat != 0) {
      throw ArgumentError.value(
        bytes.length,
        'bytes.length',
        'must be a multiple of $_bytesPerFloat to decode as Float32 vector',
      );
    }
    final int length = bytes.length ~/ _bytesPerFloat;
    // Copy into a fresh buffer so the ByteData view does not depend on the
    // source list's offset/alignment.
    final ByteData data = ByteData.sublistView(bytes);
    final List<double> vector = List<double>.filled(length, 0.0);
    for (int i = 0; i < length; i++) {
      vector[i] = data.getFloat32(i * _bytesPerFloat, Endian.little);
    }
    return vector;
  }

  /// The Euclidean (L2) norm — `√(Σ vᵢ²)` — of [vector].
  ///
  /// Returns `0.0` for an empty or all-zero vector.
  static double l2Norm(List<double> vector) {
    double sumOfSquares = 0.0;
    for (final double value in vector) {
      sumOfSquares += value * value;
    }
    // Guard tiny negative rounding before the square root.
    return sumOfSquares <= 0.0 ? 0.0 : math.sqrt(sumOfSquares);
  }

  /// Returns an L2-normalized copy of [vector], i.e. a unit vector pointing in
  /// the same direction, so cosine similarity between normalized vectors is a
  /// plain dot product (design §Embedding encoding).
  ///
  /// A zero (or empty) vector has no direction to normalize, so it is returned
  /// unchanged (as zeros); its similarity to anything is then `0.0`, which is
  /// the intended "no signal" outcome.
  static List<double> normalize(List<double> vector) {
    final double norm = l2Norm(vector);
    if (norm == 0.0) {
      return List<double>.of(vector);
    }
    final List<double> unit = List<double>.filled(vector.length, 0.0);
    for (int i = 0; i < vector.length; i++) {
      unit[i] = vector[i] / norm;
    }
    return unit;
  }

  /// The dot product `Σ aᵢbᵢ` of [a] and [b], which for L2-normalized inputs is
  /// their cosine similarity (design §Embedding encoding).
  ///
  /// Both vectors must have the same length; a mismatch means the stored vector
  /// does not match the query model's dimension, so an [ArgumentError] is thrown
  /// for the caller to treat as a dimension mismatch (design §Error Handling —
  /// dimension mismatch).
  static double dot(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError(
        'vectors must have equal length to compute a dot product '
        '(${a.length} != ${b.length})',
      );
    }
    double sum = 0.0;
    for (int i = 0; i < a.length; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }

  /// Cosine similarity of [a] and [b] in `[-1.0, 1.0]`, independent of whether
  /// the inputs are already normalized (design §Embedding encoding; Req 1.2).
  ///
  /// Computed as the dot product divided by the product of the two norms. When
  /// either vector is zero-length or all-zero it has no direction, so the
  /// similarity is `0.0`. For pre-normalized (unit) vectors this equals
  /// [dot]; identical vectors score `1.0` and orthogonal vectors `0.0`.
  static double cosineSimilarity(List<double> a, List<double> b) {
    final double normA = l2Norm(a);
    final double normB = l2Norm(b);
    if (normA == 0.0 || normB == 0.0) {
      return 0.0;
    }
    return dot(a, b) / (normA * normB);
  }
}
