// Unit tests for ranking correctness of the vector similarity math in
// VectorCodec (task 2.4).
//
// Validates: Requirements 1.2
//
// Requirement 1.2 says the semantic retriever returns the most relevant
// passages ranked by similarity. The ranking itself is decided by
// VectorCodec.cosineSimilarity: given a query vector and a set of candidate
// vectors, sorting candidates by descending cosine similarity must place the
// closest (most similar) candidate first. These tests pin the three concrete
// guarantees the ranking relies on, each with a hand-computed expected value:
//
//   1. Identical (parallel) vectors score exactly 1.0 — the maximum, so an
//      exact match always ranks first.
//   2. Orthogonal vectors score exactly 0.0 — no shared direction, so an
//      unrelated candidate sinks to the bottom.
//   3. Sorting a candidate set by cosineSimilarity(query, candidate) descending
//      yields the correct closest-first order, matching the angle between each
//      candidate and the query.
//
// cosineSimilarity is scale-invariant (it divides out both norms), so these
// tests use plain integer-valued vectors and hand-compute the expected cosine
// from cos θ = (a · b) / (|a| |b|) rather than pre-normalizing the inputs.

import 'package:flutter_test/flutter_test.dart';

import 'package:spwrite/data/ai/vector_codec.dart';

/// Floating-point tolerance for hand-computed cosine expectations. Cosine is a
/// handful of multiplies, adds and one divide over Float64, so the accumulated
/// error is far below this bound; it exists only to avoid brittle exact-bit
/// comparisons.
const double _tolerance = 1e-12;

void main() {
  group('identical vectors score 1.0 (Req 1.2)', () {
    test('a non-trivial vector is maximally similar to itself', () {
      // cos(0) = 1.0 for any vector compared with itself.
      final List<double> v = <double>[3.0, -4.0, 12.0];

      expect(VectorCodec.cosineSimilarity(v, v), closeTo(1.0, _tolerance));
    });

    test('a positively scaled copy is also parallel and scores 1.0', () {
      // Cosine is scale-invariant: b = 2a points the same way as a, so cos = 1.
      final List<double> a = <double>[1.0, 2.0, 2.0];
      final List<double> b = <double>[2.0, 4.0, 4.0];

      expect(VectorCodec.cosineSimilarity(a, b), closeTo(1.0, _tolerance));
    });

    test('the similarity of a vector to itself never exceeds 1.0', () {
      // Ranking correctness depends on 1.0 being the ceiling: nothing can
      // out-score an exact match.
      final List<double> v = <double>[0.5, 0.25, -0.75, 1.5];

      expect(
        VectorCodec.cosineSimilarity(v, v),
        lessThanOrEqualTo(1.0 + _tolerance),
      );
    });
  });

  group('orthogonal vectors score 0.0 (Req 1.2)', () {
    test('axis-aligned unit vectors are orthogonal', () {
      // e_x · e_y = 0, so cos = 0.
      final List<double> x = <double>[1.0, 0.0];
      final List<double> y = <double>[0.0, 1.0];

      expect(VectorCodec.cosineSimilarity(x, y), closeTo(0.0, _tolerance));
    });

    test('a hand-picked orthogonal pair (dot product 0) scores 0.0', () {
      // [1, 2, 3] · [3, 0, -1] = 3 + 0 - 3 = 0 -> orthogonal.
      final List<double> a = <double>[1.0, 2.0, 3.0];
      final List<double> b = <double>[3.0, 0.0, -1.0];

      expect(VectorCodec.cosineSimilarity(a, b), closeTo(0.0, _tolerance));
    });

    test('anti-parallel vectors score -1.0, the ranking floor', () {
      // cos(180) = -1.0: an opposite-direction candidate is the least similar.
      final List<double> a = <double>[2.0, -1.0];
      final List<double> b = <double>[-2.0, 1.0];

      expect(VectorCodec.cosineSimilarity(a, b), closeTo(-1.0, _tolerance));
    });
  });

  group('ranking order by similarity is correct (Req 1.2)', () {
    test('sorting candidates by descending cosine puts the closest first', () {
      // Query points along +x. Hand-computed cosines against the query:
      //   exact    [1, 0]        -> 1 / (1 * 1)          = 1.0
      //   near     [1, 1]        -> 1 / (1 * sqrt2)       ~ 0.7071
      //   ortho    [0, 1]        -> 0 / (1 * 1)          = 0.0
      //   opposite [-1, 0]       -> -1 / (1 * 1)         = -1.0
      final List<double> query = <double>[1.0, 0.0];

      final Map<String, List<double>> candidates = <String, List<double>>{
        'ortho': <double>[0.0, 1.0],
        'opposite': <double>[-1.0, 0.0],
        'exact': <double>[1.0, 0.0],
        'near': <double>[1.0, 1.0],
      };

      final List<String> rankedIds = candidates.keys.toList()
        ..sort((String a, String b) {
          final double sa = VectorCodec.cosineSimilarity(query, candidates[a]!);
          final double sb = VectorCodec.cosineSimilarity(query, candidates[b]!);
          return sb.compareTo(sa); // descending: closest first
        });

      expect(rankedIds, <String>['exact', 'near', 'ortho', 'opposite']);

      // Spot-check the driving scores match the hand computation.
      expect(
        VectorCodec.cosineSimilarity(query, candidates['exact']!),
        closeTo(1.0, _tolerance),
      );
      expect(
        VectorCodec.cosineSimilarity(query, candidates['near']!),
        closeTo(0.70710678118654752, _tolerance),
      );
      expect(
        VectorCodec.cosineSimilarity(query, candidates['ortho']!),
        closeTo(0.0, _tolerance),
      );
      expect(
        VectorCodec.cosineSimilarity(query, candidates['opposite']!),
        closeTo(-1.0, _tolerance),
      );
    });

    test('a smaller angle always outranks a larger one', () {
      // Query [1, 1] (45 deg from each axis). Candidate cosines:
      //   [2, 1] -> (2 + 1)/(sqrt2 * sqrt5) = 3/sqrt10       ~ 0.9487  (~18.4 deg)
      //   [1, 2] -> (1 + 2)/(sqrt2 * sqrt5) = 3/sqrt10       ~ 0.9487  (~18.4 deg)
      //   [1, 0] -> (1 + 0)/(sqrt2 * 1)     = 1/sqrt2        ~ 0.7071  (45 deg)
      // The two closest candidates tie; the more-off-axis one ranks last.
      final List<double> query = <double>[1.0, 1.0];

      final double closeA =
          VectorCodec.cosineSimilarity(query, <double>[2.0, 1.0]);
      final double closeB =
          VectorCodec.cosineSimilarity(query, <double>[1.0, 2.0]);
      final double far =
          VectorCodec.cosineSimilarity(query, <double>[1.0, 0.0]);

      expect(closeA, closeTo(0.94868329805051381, _tolerance));
      expect(closeB, closeTo(0.94868329805051381, _tolerance));
      expect(far, closeTo(0.70710678118654752, _tolerance));

      expect(closeA, greaterThan(far));
      expect(closeB, greaterThan(far));
    });

    test('ranking is consistent across a higher-dimension candidate set', () {
      // A 4-dim query with three candidates whose similarity is ordered by
      // construction (fewer sign flips / more shared magnitude ranks higher).
      final List<double> query = <double>[1.0, 1.0, 1.0, 1.0];

      // all aligned  -> cos = 4 / (2 * 2) = 1.0
      final List<double> best = <double>[1.0, 1.0, 1.0, 1.0];
      // one component flipped -> dot = 2, |v| = 2 -> cos = 2/4 = 0.5
      final List<double> middle = <double>[1.0, 1.0, 1.0, -1.0];
      // two flipped -> dot = 0 -> cos = 0.0
      final List<double> worst = <double>[1.0, 1.0, -1.0, -1.0];

      final double sBest = VectorCodec.cosineSimilarity(query, best);
      final double sMiddle = VectorCodec.cosineSimilarity(query, middle);
      final double sWorst = VectorCodec.cosineSimilarity(query, worst);

      expect(sBest, closeTo(1.0, _tolerance));
      expect(sMiddle, closeTo(0.5, _tolerance));
      expect(sWorst, closeTo(0.0, _tolerance));

      // Strictly descending: the ranking is unambiguous.
      expect(sBest, greaterThan(sMiddle));
      expect(sMiddle, greaterThan(sWorst));
    });
  });
}
