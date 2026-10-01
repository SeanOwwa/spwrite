// Property test for the embedding encode/decode round-trip
// (ai_feature_3.6 task 2.2).
//
// Feature: ai_feature_3.6, Property 1: Embedding round-trip is lossless within
// Float32 tolerance. For any vector `v`, `decode(encode(v))` equals `v`
// element-wise within Float32 precision, and the encoded byte length is exactly
// `dim * 4`.
//
// **Validates: Requirements 4.1**
//
// Strategy: generate a vector as a `List<double>` whose length ranges from 0
// (the empty-vector edge case) up to a small dimension, drawn from a value pool
// that mixes ordinary magnitudes, tiny/large magnitudes, zero, and negatives —
// the shape of L2-normalized embedding components plus a few extremes. For each
// generated vector the test asserts:
//   - the encoded buffer is exactly `vector.length * 4` bytes (Float32 =
//     4 bytes/component), and
//   - decoding it reproduces each component within Float32 precision.
//
// `VectorCodec.encode` narrows every value to Float32 when it writes the BLOB,
// so the correct reference to compare against is each value AFTER a Float32
// narrowing round-trip — not the original Float64 literal. The test computes
// that reference independently with a `ByteData` Float32 write/read and asserts
// the decoded value equals it exactly (a Float32 value that is written and read
// back as Float32 is bit-for-bit stable). This is a tighter check than an
// absolute epsilon and still honours "within Float32 tolerance": the only loss
// permitted is the Float64 -> Float32 narrowing that encoding performs.
//
// kiri_check 1.3.1: `forAll`'s block is synchronous here (pure math, no I/O),
// so no async is involved. Values are generated with `float(...)` composed into
// a `list(...)` including `minLength: 0` for the empty-vector case.

import 'dart:typed_data';

import 'package:kiri_check/kiri_check.dart';
import 'package:test/test.dart';

import 'package:spwrite/data/ai/vector_codec.dart';

/// Narrows [value] to Float32 the same way [VectorCodec.encode] does, by
/// writing it as little-endian Float32 and reading it back. This is the exact
/// value the codec stores, so a correct round-trip must reproduce it bit-for-bit.
double float32Narrow(double value) {
  final ByteData data = ByteData(4);
  data.setFloat32(0, value, Endian.little);
  return data.getFloat32(0, Endian.little);
}

void main() {
  // A pool of component values covering the range a normalized embedding
  // component lives in, plus extremes that stress the Float32 narrowing:
  // zero, small and large magnitudes, negatives, and a value with many
  // significant digits that does NOT fit exactly in Float32.
  const List<double> valuePool = <double>[
    0.0,
    1.0,
    -1.0,
    0.5,
    -0.5,
    0.1,
    -0.123456789,
    0.9999999,
    1e-7,
    -1e-7,
    1234.5678,
    -98765.4321,
    3.4028235e38, // near Float32 max
    1.5e-38, // near Float32 min normal
    0.7071067811865476, // 1/sqrt(2): common for a 2-D unit vector
  ];

  Arbitrary<double> component() =>
      integer(min: 0, max: valuePool.length - 1).map((int i) => valuePool[i]);

  // Vectors from empty (dim 0) up to a small dimension. Empty is the documented
  // edge case (encode yields a zero-length buffer; decode yields []).
  Arbitrary<List<double>> vector() =>
      list(component(), minLength: 0, maxLength: 12);

  property('Property 1: embedding encode/decode round-trip is lossless '
      'within Float32 tolerance and BLOB length is dim * 4', () {
    forAll(
      vector(),
      (List<double> v) {
        final Uint8List encoded = VectorCodec.encode(v);

        // BLOB length is exactly dim * 4 bytes.
        expect(
          encoded.length,
          v.length * 4,
          reason: 'encoded BLOB must be exactly length * 4 bytes '
              '(Float32 = 4 bytes/component)',
        );

        final List<double> decoded = VectorCodec.decode(encoded);

        // Same number of components round-tripped: none added or lost.
        expect(
          decoded.length,
          v.length,
          reason: 'decode must return one component per 4 bytes',
        );

        // Each component round-trips to its Float32-narrowed value exactly.
        for (int i = 0; i < v.length; i++) {
          expect(
            decoded[i],
            float32Narrow(v[i]),
            reason: 'component $i must round-trip within Float32 precision '
                '(original ${v[i]})',
          );
        }
      },
      maxExamples: 200,
    );
  });
}
