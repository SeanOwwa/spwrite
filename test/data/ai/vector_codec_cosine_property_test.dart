// Property test for cosine similarity / dot / normalize on the vector codec
// (ai_feature_3.6 task 2.3).
//
// Feature: ai_feature_3.6, Property 2: Cosine of L2-normalized vectors is
// bounded and reflexive. For any non-zero vectors, `similarity ∈ [-1, 1]`; a
// vector with itself scores `1.0` (within tolerance); scaling a vector by a
// positive constant does not change its similarity to any other vector.
//
// **Validates: Requirements 1.2**
//
// This file exercises the pure similarity math in [VectorCodec]
// (`lib/data/ai/vector_codec.dart`): `cosineSimilarity`, `dot`, and
// `normalize`. It bundles the facets the design's Correctness Property 2 calls
// out together with the closely-related invariants named in the task and the
// design §Testing Strategy (identical → 1.0, orthogonal → 0.0, symmetry, zero
// vectors → 0.0), each as its own `property`/`test` so a failure points at the
// exact invariant.
//
// Strategy: vectors are generated as fixed-length lists of *finite* doubles in a
// bounded range (no NaN/infinity, which are not valid embedding components).
// Generators that need a directioned (non-zero) vector nudge an all-zero draw
// to a unit basis vector so `l2Norm > 0`. Orthogonality is constructed exactly
// (not sampled) by splitting the dimensions into two disjoint supports, so the
// dot product is provably zero regardless of the drawn magnitudes.

import 'dart:math' as math;

import 'package:kiri_check/kiri_check.dart';
import 'package:spwrite/data/ai/vector_codec.dart';
import 'package:test/test.dart';

void main() {
  // Float32 storage plus accumulated floating-point error over a dot product:
  // a tolerance comfortably above Float32 epsilon but tight enough to catch a
  // real regression.
  const double tolerance = 1e-6;

  // A finite, bounded component: embedding values are ordinary finite doubles,
  // so NaN/infinity are excluded. The range is wide enough to include large and
  // tiny magnitudes and both signs.
  Arbitrary<double> component() =>
      float(min: -100.0, max: 100.0, nan: false, infinity: false);

  // A fixed-length vector of finite components. Lengths cover the small-dim
  // cases plus a few realistic sizes.
  Arbitrary<List<double>> vectorOfLength(int length) =>
      list(component(), minLength: length, maxLength: length);

  // A vector that is guaranteed to have a direction (non-zero L2 norm). If a
  // draw happens to be all-zero, the first component is set to 1.0 so the
  // vector points somewhere and `normalize` produces a genuine unit vector.
  Arbitrary<List<double>> nonZeroVectorOfLength(int length) =>
      vectorOfLength(length).map((List<double> v) {
        if (VectorCodec.l2Norm(v) == 0.0) {
          final List<double> nudged = List<double>.of(v);
          nudged[0] = 1.0;
          return nudged;
        }
        return v;
      });

  // A dimension for paired vectors, kept modest so `combine`d pairs stay cheap.
  const int pairDim = 8;

  Arbitrary<(List<double>, List<double>)> nonZeroPair() => combine2(
        nonZeroVectorOfLength(pairDim),
        nonZeroVectorOfLength(pairDim),
      ).map((r) => (r.$1, r.$2));

  group('VectorCodec cosine similarity — Property 2 (Req 1.2)', () {
    property('similarity is bounded in [-1, 1] for any non-zero vectors', () {
      forAll(
        nonZeroPair(),
        ((List<double>, List<double>) pair) {
          final double sim = VectorCodec.cosineSimilarity(pair.$1, pair.$2);
          // A small epsilon past the exact bound absorbs floating-point error
          // right at ±1 (e.g. near-parallel vectors).
          expect(
            sim,
            greaterThanOrEqualTo(-1.0 - tolerance),
            reason: 'cosine must not fall below -1',
          );
          expect(
            sim,
            lessThanOrEqualTo(1.0 + tolerance),
            reason: 'cosine must not exceed 1',
          );
        },
        maxExamples: 200,
      );
    });

    property('a non-zero vector with itself scores 1.0 (reflexive)', () {
      forAll(
        nonZeroVectorOfLength(pairDim),
        (List<double> v) {
          expect(
            VectorCodec.cosineSimilarity(v, v),
            closeTo(1.0, tolerance),
            reason: 'a vector is perfectly similar to itself',
          );
        },
        maxExamples: 200,
      );
    });

    property('scaling by a positive constant does not change similarity', () {
      forAll(
        combine3(
          nonZeroVectorOfLength(pairDim),
          nonZeroVectorOfLength(pairDim),
          // A strictly-positive scale factor, both tiny and large.
          float(min: 1e-3, max: 1000.0, nan: false, infinity: false),
        ),
        ((List<double>, List<double>, double) r) {
          final List<double> a = r.$1;
          final List<double> b = r.$2;
          final double k = r.$3;
          final List<double> scaledA =
              a.map((double x) => x * k).toList(growable: false);

          final double base = VectorCodec.cosineSimilarity(a, b);
          final double scaled = VectorCodec.cosineSimilarity(scaledA, b);
          expect(
            scaled,
            closeTo(base, tolerance),
            reason: 'cosine is scale-invariant under positive scaling of a',
          );
        },
        maxExamples: 200,
      );
    });

    property('similarity is symmetric: cos(a, b) == cos(b, a)', () {
      forAll(
        nonZeroPair(),
        ((List<double>, List<double>) pair) {
          expect(
            VectorCodec.cosineSimilarity(pair.$1, pair.$2),
            closeTo(
              VectorCodec.cosineSimilarity(pair.$2, pair.$1),
              tolerance,
            ),
            reason: 'cosine similarity is symmetric in its arguments',
          );
        },
        maxExamples: 200,
      );
    });

    property('orthogonal vectors (disjoint support) score 0.0', () {
      // Build an even-length vector, then zero out one half in `a` and the other
      // half in `b`, so `a` and `b` have disjoint non-zero supports and are
      // therefore orthogonal by construction (dot product is exactly 0).
      const int half = 4; // full dimension = 2 * half
      forAll(
        combine2(
          nonZeroVectorOfLength(half),
          nonZeroVectorOfLength(half),
        ),
        ((List<double>, List<double>) r) {
          final List<double> aVals = r.$1;
          final List<double> bVals = r.$2;
          final List<double> a = <double>[...aVals, ...List<double>.filled(half, 0.0)];
          final List<double> b = <double>[...List<double>.filled(half, 0.0), ...bVals];

          expect(
            VectorCodec.cosineSimilarity(a, b),
            closeTo(0.0, tolerance),
            reason: 'vectors with disjoint support are orthogonal → cosine 0',
          );
        },
        maxExamples: 200,
      );
    });

    property('a zero vector scores 0.0 against any vector', () {
      forAll(
        nonZeroVectorOfLength(pairDim),
        (List<double> v) {
          final List<double> zero = List<double>.filled(pairDim, 0.0);
          expect(
            VectorCodec.cosineSimilarity(zero, v),
            0.0,
            reason: 'a zero vector has no direction → similarity 0',
          );
          expect(
            VectorCodec.cosineSimilarity(v, zero),
            0.0,
            reason: 'zero vector on either side yields 0',
          );
          expect(
            VectorCodec.cosineSimilarity(zero, zero),
            0.0,
            reason: 'two zero vectors are still 0, never NaN',
          );
        },
        maxExamples: 200,
      );
    });

    property('cosine equals the dot product of normalized inputs', () {
      forAll(
        nonZeroPair(),
        ((List<double>, List<double>) pair) {
          final double cosine =
              VectorCodec.cosineSimilarity(pair.$1, pair.$2);
          final double dotOfUnits = VectorCodec.dot(
            VectorCodec.normalize(pair.$1),
            VectorCodec.normalize(pair.$2),
          );
          expect(
            dotOfUnits,
            closeTo(cosine, tolerance),
            reason: 'normalizing then taking the dot product is cosine '
                '(the encoding used for stored vectors)',
          );
        },
        maxExamples: 200,
      );
    });

    property('normalize produces a unit vector (norm 1) for non-zero input',
        () {
      forAll(
        nonZeroVectorOfLength(pairDim),
        (List<double> v) {
          final List<double> unit = VectorCodec.normalize(v);
          expect(
            VectorCodec.l2Norm(unit),
            closeTo(1.0, tolerance),
            reason: 'an L2-normalized non-zero vector has unit length',
          );
        },
        maxExamples: 200,
      );
    });
  });

  group('VectorCodec cosine similarity — concrete examples (Req 1.2)', () {
    test('identical unit vectors score exactly 1.0', () {
      final List<double> v = <double>[0.6, 0.8]; // already unit length
      expect(VectorCodec.cosineSimilarity(v, v), closeTo(1.0, tolerance));
    });

    test('opposite vectors score -1.0', () {
      final List<double> a = <double>[1.0, 0.0, 0.0];
      final List<double> b = <double>[-1.0, 0.0, 0.0];
      expect(VectorCodec.cosineSimilarity(a, b), closeTo(-1.0, tolerance));
    });

    test('axis-aligned orthogonal unit vectors score 0.0', () {
      final List<double> x = <double>[1.0, 0.0];
      final List<double> y = <double>[0.0, 1.0];
      expect(VectorCodec.cosineSimilarity(x, y), closeTo(0.0, tolerance));
    });

    test('45-degree vectors score cos(45°) ≈ 0.7071', () {
      final List<double> right = <double>[1.0, 0.0];
      final List<double> diagonal = <double>[1.0, 1.0];
      expect(
        VectorCodec.cosineSimilarity(right, diagonal),
        closeTo(1.0 / math.sqrt2, tolerance),
      );
    });
  });
}
