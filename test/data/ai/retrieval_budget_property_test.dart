// Property test for the grounding budget (ai_feature_3.6 task 8.2).
//
// Feature: ai_feature_3.6 — On-device semantic retrieval (RAG).
// Property 5: Grounding never exceeds the budget. For any set of candidate
// chunks and any `contextSize`/`maxTokens`/history, the injected grounding's
// estimated token count is ≤ `groundingBudget`, and reserved reply capacity
// (`maxTokens`) is always preserved. Chunks are included strictly in
// descending-score (input) order with no partial/truncated chunk. This also
// exercises the design's note that the budget adapts when `contextSize` changes
// 2048 → 4096 (widening the budget widens what fits).
//
// **Validates: Requirements 5.1, 5.2, 5.3, 5.4**
//
// This file exercises the pure budget math in [RetrievalBudget]
// (`lib/data/ai/retrieval_budget.dart`): `groundingBudget`, `topN`, and `fit`.
// It touches no database, model, or Flutter dependency — only the domain
// [RetrievedPassage] value object — so the invariants are checked in isolation
// (design §Testing Strategy — Budget math; §Correctness Properties, Property 5).
//
// Strategy: generate candidate passages as lists of text of varied length
// (including empty and large chunks) with descending scores, together with the
// budget's sizing inputs (`contextSize`, `reservedReplyTokens`, `historyTokens`,
// `promptFramingTokens`, and an optional `maxPassages` cap). Sizing inputs span
// both the "roomy window" case (grounding fits) and the "over-full window" case
// (history + framing + reply already exceed the context → zero budget). Each
// invariant from Property 5 is its own `property` so a failure points at the
// exact facet. Following the repo's kiri_check convention
// (vector_codec_cosine_property_test.dart, chunk_hashing_property_test.dart):
// `property(...) { forAll(...) }` with a bounded `maxExamples` and
// `combineN(...).map(...)` records for multi-argument generators.

import 'package:kiri_check/kiri_check.dart';
import 'package:test/test.dart';

import 'package:spwrite/data/ai/retrieval_budget.dart';
import 'package:spwrite/domain/ai/context_retriever.dart';

/// A generated set of budget inputs plus the candidate passages to fit.
typedef BudgetCase = ({
  int contextSize,
  int reservedReplyTokens,
  int historyTokens,
  int promptFramingTokens,
  int? maxPassages,
  List<RetrievedPassage> candidates,
});

void main() {
  // ---------------------------------------------------------------------------
  // Generators.
  // ---------------------------------------------------------------------------

  // A chunk's character length. Covers empty text (0 tokens), tiny chunks, a
  // realistic ~800-char (~200-token) chunk, and an oversized chunk that alone
  // may exceed a small budget so the "exclude, don't truncate" path is hit.
  Arbitrary<int> chunkLength() => integer(min: 0, max: 4000);

  // A single candidate passage of the given text length. The text is a run of
  // 'a' — the budget only ever measures `text.length`, so content is irrelevant
  // and a uniform fill keeps generation cheap while length varies widely.
  Arbitrary<RetrievedPassage> passage() => chunkLength().map(
        (int len) => RetrievedPassage(
          text: 'a' * len,
          sourceId: 'src',
          sourceTitle: 'title',
          score: 0.0,
        ),
      );

  // A list of candidate passages (0..12) in the descending-score order the
  // budget is fed. `fit` does not re-rank, so scores are assigned strictly
  // decreasing here only to model the real "highest-scoring first" contract;
  // the invariants under test depend on input order, not the score values.
  Arbitrary<List<RetrievedPassage>> candidates() =>
      list(passage(), minLength: 0, maxLength: 12).map(
        (List<RetrievedPassage> ps) {
          double score = 1.0;
          return <RetrievedPassage>[
            for (final RetrievedPassage p in ps)
              p.copyWith(score: score -= 0.01),
          ];
        },
      );

  // An optional passage cap. A sentinel of -100 maps to `null` (no cap);
  // otherwise the value is used directly, including small negatives so the
  // clamp-to-zero behaviour is exercised. Modelled as a plain int generator so
  // it composes cleanly with `combineN` (avoiding `oneOf`'s dynamic typing).
  Arbitrary<int?> maxPassagesOpt() =>
      integer(min: -100, max: 8).map<int?>((int n) => n == -100 ? null : n);

  // Budget sizing inputs. Ranges deliberately straddle both regimes:
  //  - contextSize includes the two documented windows (2048, 4096) plus a
  //    spread that can be smaller than the reservations (→ zero budget).
  //  - reservedReply/history/framing can together exceed contextSize, which is
  //    the "over-full window" case that must yield empty grounding.
  Arbitrary<BudgetCase> budgetCase() => combine6(
        integer(min: 0, max: 8192),
        integer(min: 0, max: 2048),
        integer(min: 0, max: 4096),
        integer(min: 0, max: 2048),
        maxPassagesOpt(),
        candidates(),
      ).map(
        (r) => (
          contextSize: r.$1,
          reservedReplyTokens: r.$2,
          historyTokens: r.$3,
          promptFramingTokens: r.$4,
          maxPassages: r.$5,
          candidates: r.$6,
        ),
      );

  RetrievalBudget budgetOf(BudgetCase c) => RetrievalBudget(
        contextSize: c.contextSize,
        reservedReplyTokens: c.reservedReplyTokens,
        historyTokens: c.historyTokens,
        promptFramingTokens: c.promptFramingTokens,
        maxPassages: c.maxPassages,
      );

  group('RetrievalBudget — Property 5 (Req 5.1–5.4)', () {
    // -------------------------------------------------------------------------
    // 5.1 / 5.2: the selected grounding never exceeds the grounding budget.
    // -------------------------------------------------------------------------
    property('usedTokens never exceeds groundingBudget', () {
      forAll(budgetCase(), (BudgetCase c) {
        final RetrievalBudget budget = budgetOf(c);
        final BudgetedGrounding g = budget.fit(c.candidates);

        expect(
          g.usedTokens,
          lessThanOrEqualTo(budget.groundingBudget),
          reason: 'injected grounding must fit within the derived budget so the '
              'combined prompt stays inside contextSize (Req 5.1, 5.2)',
        );
        // The reported budget on the result matches the calculator's budget.
        expect(g.groundingBudget, equals(budget.groundingBudget));
        expect(g.usedTokens, greaterThanOrEqualTo(0));
      }, maxExamples: 300);
    });

    // -------------------------------------------------------------------------
    // 5.4: reply capacity is always reserved — grounding never encroaches on the
    // reserved reply tokens. The budget subtracts `reservedReplyTokens` first,
    // so the grounding it admits can never claim the reply's share of the
    // window: `usedTokens ≤ contextSize − reservedReplyTokens`. (History and
    // framing are the caller's own prompt budget; the reservation invariant is
    // specifically about grounding not stealing the reply's space.)
    // -------------------------------------------------------------------------
    property('reserved reply capacity is always preserved', () {
      forAll(budgetCase(), (BudgetCase c) {
        final RetrievalBudget budget = budgetOf(c);
        final BudgetedGrounding g = budget.fit(c.candidates);

        final int reserved = budget.reservedReplyTokens; // clamped ≥ 0
        if (budget.contextSize >= reserved) {
          // Grounding plus the reserved reply must fit the window: grounding
          // can never eat into the space reserved for generating up to
          // maxTokens.
          expect(
            g.usedTokens + reserved,
            lessThanOrEqualTo(budget.contextSize),
            reason: 'a full grounded prompt must not consume the space reserved '
                'for generating up to maxTokens (Req 5.4)',
          );
        } else {
          // The reply reservation alone exceeds the window → there is no room
          // for grounding at all, so none is added.
          expect(g.isEmpty, isTrue,
              reason: 'when the reserved reply exceeds the whole context '
                  'window, no grounding is injected (Req 5.4)');
        }
      }, maxExamples: 300);
    });

    // -------------------------------------------------------------------------
    // 5.3: chunks are included in input (descending-score) order — fit never
    // reorders the candidates it admits.
    // -------------------------------------------------------------------------
    property('included passages preserve the input (descending-score) order',
        () {
      forAll(budgetCase(), (BudgetCase c) {
        final BudgetedGrounding g = budgetOf(c).fit(c.candidates);

        // Every included passage appears in the candidate list, and the
        // relative order of the included subset matches the candidate order.
        int lastIndex = -1;
        for (final RetrievedPassage inc in g.included) {
          final int idx = c.candidates.indexOf(inc);
          expect(idx, greaterThan(lastIndex),
              reason: 'included passages keep their original relative order; '
                  'fit does not re-rank (Req 5.3)');
          lastIndex = idx;
        }
      }, maxExamples: 300);
    });

    // -------------------------------------------------------------------------
    // 5.3: no chunk is truncated — each included passage is a whole candidate,
    // byte-for-byte, never a shortened slice.
    // -------------------------------------------------------------------------
    property('no passage is truncated — each included passage is a whole '
        'candidate', () {
      forAll(budgetCase(), (BudgetCase c) {
        final BudgetedGrounding g = budgetOf(c).fit(c.candidates);

        for (final RetrievedPassage inc in g.included) {
          expect(
            c.candidates.contains(inc),
            isTrue,
            reason: 'an included passage must equal a whole input candidate — '
                'chunks are excluded, never truncated mid-text (Req 5.3)',
          );
        }
        // included + excluded accounts for exactly the candidates offered.
        expect(g.included.length + g.excludedCount, equals(c.candidates.length));
      }, maxExamples: 300);
    });

    // -------------------------------------------------------------------------
    // 5.2 / 5.4: an over-full window (history + framing + reserved reply already
    // exceed the context) yields empty grounding rather than a negative budget.
    // -------------------------------------------------------------------------
    property('an over-full window yields empty grounding', () {
      // Force the reservations to exceed the context window.
      final Arbitrary<BudgetCase> overFull = combine6(
        integer(min: 0, max: 1024), // contextSize
        integer(min: 0, max: 1024), // reservedReply
        integer(min: 0, max: 2048), // history
        integer(min: 0, max: 2048), // framing
        maxPassagesOpt(),
        list(passage(), minLength: 1, maxLength: 8),
      ).map(
        (r) => (
          contextSize: r.$1,
          reservedReplyTokens: r.$2,
          historyTokens: r.$3,
          promptFramingTokens: r.$4,
          maxPassages: r.$5,
          candidates: r.$6,
        ),
      );

      forAll(overFull, (BudgetCase c) {
        final RetrievalBudget budget = budgetOf(c);
        // Only assert the invariant when the window is genuinely over-full.
        final int demand = budget.reservedReplyTokens +
            budget.historyTokens +
            budget.promptFramingTokens;
        if (demand > budget.contextSize) {
          expect(budget.groundingBudget, equals(0),
              reason: 'budget clamps to 0, never negative (Req 5.2, 5.4)');
          final BudgetedGrounding g = budget.fit(c.candidates);
          expect(g.isEmpty, isTrue,
              reason: 'no grounding fits an over-full window');
          expect(g.usedTokens, equals(0));
          // All candidates were offered but none fit.
          expect(g.excludedCount, equals(c.candidates.length));
        }
      }, maxExamples: 300);
    });

    // -------------------------------------------------------------------------
    // 5.1: topN caps inclusion — fit never returns more passages than the
    // derived cap, regardless of how many would fit the token budget.
    // -------------------------------------------------------------------------
    property('topN caps the number of included passages', () {
      forAll(budgetCase(), (BudgetCase c) {
        final RetrievalBudget budget = budgetOf(c);
        final BudgetedGrounding g = budget.fit(c.candidates);

        expect(
          g.included.length,
          lessThanOrEqualTo(budget.topN),
          reason: 'inclusion is bounded by the budget-derived top-N cap '
              '(Req 5.1)',
        );
        // And never more than were offered.
        expect(g.included.length, lessThanOrEqualTo(c.candidates.length));
      }, maxExamples: 300);
    });

    // -------------------------------------------------------------------------
    // 5.1 / 5.2: an explicit maxPassages cap is honoured (clamped ≥ 0), so a
    // caller-supplied ceiling always bounds the result.
    // -------------------------------------------------------------------------
    property('an explicit maxPassages cap bounds inclusion', () {
      final Arbitrary<({int cap, BudgetCase c})> capped = combine2(
        integer(min: 0, max: 6),
        budgetCase(),
      ).map((r) => (cap: r.$1, c: r.$2));

      forAll(capped, (({int cap, BudgetCase c}) tc) {
        final RetrievalBudget budget = RetrievalBudget(
          contextSize: 8192, // roomy so the token budget is not the limiter
          reservedReplyTokens: 512,
          maxPassages: tc.cap,
        );
        final BudgetedGrounding g = budget.fit(tc.c.candidates);
        expect(
          g.included.length,
          lessThanOrEqualTo(tc.cap),
          reason: 'never include more than the caller-supplied maxPassages cap',
        );
      }, maxExamples: 200);
    });

    // -------------------------------------------------------------------------
    // Adaptation: widening contextSize 2048 → 4096 (all else equal) never
    // shrinks the budget and never drops a previously-included passage — the
    // formula adapts to the configured window (design §Tuning note; Req 5.2).
    // -------------------------------------------------------------------------
    property('raising contextSize 2048 → 4096 never reduces what fits', () {
      forAll(candidates(), (List<RetrievedPassage> cs) {
        RetrievalBudget at(int contextSize) => RetrievalBudget(
              contextSize: contextSize,
              reservedReplyTokens: 512,
              historyTokens: 200,
              promptFramingTokens: 100,
            );

        final RetrievalBudget small = at(2048);
        final RetrievalBudget large = at(4096);

        expect(large.groundingBudget,
            greaterThanOrEqualTo(small.groundingBudget),
            reason: 'a larger context window widens the grounding budget');
        expect(large.topN, greaterThanOrEqualTo(small.topN),
            reason: 'a larger window never lowers the top-N cap');

        final BudgetedGrounding gSmall = small.fit(cs);
        final BudgetedGrounding gLarge = large.fit(cs);

        // Every passage that fit the 2048 window also fits the 4096 window: the
        // selection walks candidates in the same order and the larger budget is
        // strictly more permissive, so nothing that fit before is dropped.
        for (final RetrievedPassage p in gSmall.included) {
          expect(gLarge.included.contains(p), isTrue,
              reason: 'widening the window must not drop a passage that already '
                  'fit the smaller window (Req 5.2)');
        }
        expect(gLarge.included.length,
            greaterThanOrEqualTo(gSmall.included.length));
      }, maxExamples: 200);
    });
  });

  // ---------------------------------------------------------------------------
  // Concrete examples — anchor the budget math at exact, hand-checked numbers.
  // ---------------------------------------------------------------------------
  group('RetrievalBudget — concrete examples (Req 5.1–5.4)', () {
    test('roomy budget includes whole chunks in order until full', () {
      // groundingBudget = 4096 - 512 - 0 - 0 = 3584 tokens.
      final RetrievalBudget budget = RetrievalBudget(
        contextSize: 4096,
        reservedReplyTokens: 512,
      );
      // Three ~200-token chunks (~800 chars) → 200 + 200 + 200 = 600 ≤ 3584,
      // but topN with 3584/200 = 17 easily admits all three.
      final List<RetrievedPassage> cs = <RetrievedPassage>[
        RetrievedPassage(text: 'a' * 800, sourceId: 's', sourceTitle: 't', score: 0.9),
        RetrievedPassage(text: 'a' * 800, sourceId: 's', sourceTitle: 't', score: 0.8),
        RetrievedPassage(text: 'a' * 800, sourceId: 's', sourceTitle: 't', score: 0.7),
      ];
      final BudgetedGrounding g = budget.fit(cs);
      expect(g.included, equals(cs));
      expect(g.usedTokens, equals(600));
      expect(g.excludedCount, equals(0));
      expect(g.usedTokens, lessThanOrEqualTo(g.groundingBudget));
    });

    test('over-full window (reservations exceed context) yields empty', () {
      final RetrievalBudget budget = RetrievalBudget(
        contextSize: 512,
        reservedReplyTokens: 512,
        historyTokens: 400,
        promptFramingTokens: 100,
      );
      expect(budget.groundingBudget, equals(0));
      final BudgetedGrounding g = budget.fit(<RetrievedPassage>[
        RetrievedPassage(text: 'a' * 40, sourceId: 's', sourceTitle: 't', score: 0.9),
      ]);
      expect(g.isEmpty, isTrue);
      expect(g.usedTokens, equals(0));
      expect(g.excludedCount, equals(1));
    });

    test('an oversized chunk is excluded, not truncated', () {
      // groundingBudget = 800 - 512 = 288 tokens.
      final RetrievalBudget budget = RetrievalBudget(
        contextSize: 800,
        reservedReplyTokens: 512,
      );
      // First chunk ~ 400 tokens (1600 chars) > 288 → excluded whole.
      // Second chunk ~ 25 tokens (100 chars) → fits.
      final RetrievedPassage big =
          RetrievedPassage(text: 'a' * 1600, sourceId: 's', sourceTitle: 't', score: 0.9);
      final RetrievedPassage small =
          RetrievedPassage(text: 'a' * 100, sourceId: 's', sourceTitle: 't', score: 0.8);
      final BudgetedGrounding g = budget.fit(<RetrievedPassage>[big, small]);
      expect(g.included, equals(<RetrievedPassage>[small]),
          reason: 'the oversized chunk is skipped whole and the smaller, '
              'lower-ranked chunk still fits');
      expect(g.excludedCount, equals(1));
      // The included chunk is verbatim, never a shortened slice.
      expect(g.included.single.text.length, equals(100));
    });

    test('maxPassages caps inclusion below the token budget', () {
      final RetrievalBudget budget = RetrievalBudget(
        contextSize: 8192,
        reservedReplyTokens: 512,
        maxPassages: 2,
      );
      final List<RetrievedPassage> cs = <RetrievedPassage>[
        for (int i = 0; i < 5; i++)
          RetrievedPassage(text: 'a' * 40, sourceId: 's', sourceTitle: 't', score: 1.0 - i * 0.1),
      ];
      final BudgetedGrounding g = budget.fit(cs);
      expect(g.included.length, equals(2));
      expect(g.excludedCount, equals(3));
    });
  });
}
