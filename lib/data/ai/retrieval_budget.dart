/// Data layer: the pure [RetrievalBudget] calculator that decides how much
/// retrieved grounding fits alongside the conversation and the reply within the
/// chat model's context window (design §"Retrieval Budget vs context window",
/// Req 5).
///
/// A full-length project is far larger than any on-device model's context
/// window, so a grounded prompt can only carry a bounded slice of retrieved
/// material. This calculator is the single place that turns the model's
/// `contextSize` and reply reservation into a concrete **grounding token
/// budget**, then selects the highest-scoring passages that fit — in strict
/// descending-score order, whole chunks only, never truncating a chunk
/// mid-text (Req 5.1, 5.3). It also derives a hard **top-N cap** the semantic
/// retriever uses to bound its candidate work, consistent with the budget
/// (design §"Retrieval Budget"; wired into [SemanticContextRetriever]).
///
/// The budget is derived as (design §"Retrieval Budget"):
///
/// ```
/// groundingBudget = contextSize
///                 − reservedReply        (= maxTokens, always reserved, Req 5.4)
///                 − historyTokens         (estimate of the recent turns)
///                 − promptFramingTokens   (system framing + the user message)
/// ```
///
/// Chunks are then added in similarity order until the running estimate would
/// exceed `groundingBudget`; the remainder is excluded rather than truncated
/// (Req 5.3). If no candidate clears the relevance floor the caller applies,
/// nothing is injected (Req 5.5) — this class only sees the candidates it is
/// given and never pads the budget with weak matches, so an empty candidate
/// list yields empty grounding.
///
/// Because raising the model's `contextSize` (e.g. 2048 → 4096) widens
/// `groundingBudget` and lowering `maxTokens` frees space too, the formula
/// adapts automatically to whatever the engine is configured with — the budget
/// is not part of the retrieval contract, only its inputs are (design §"Tuning
/// note"; Req 5.2).
///
/// Token counts use a conservative **chars ÷ 4** estimate rather than a real
/// tokenizer; a precise tokenizer would tighten the budget and is noted as a
/// future refinement (design §"Retrieval Budget"; open design question 3). The
/// estimate rounds up so a chunk is never counted as cheaper than it is, which
/// keeps the guarantee that the injected grounding stays within budget.
///
/// This class is intentionally pure: it performs no I/O, touches no database,
/// model, or Flutter dependency, and depends only on the domain
/// [RetrievedPassage] value object, so it can be unit- and property-tested in
/// isolation (design §Testing Strategy — Budget math; Property 5).
library;

import 'dart:math' as math;

import '../../domain/ai/context_retriever.dart';

/// Estimates the number of tokens a piece of text will occupy, so the budget
/// math can compare a candidate chunk's cost against the remaining budget
/// without loading a real tokenizer.
///
/// The default implementation, [RetrievalBudget.estimateTokens], uses a
/// conservative chars ÷ 4 heuristic that rounds up (design §"Retrieval Budget").
typedef TokenEstimator = int Function(String text);

/// The outcome of fitting candidate passages into the grounding budget: the
/// passages that were [included] (in the same descending-score order they were
/// offered) together with the [groundingBudget] they were fit within and the
/// [usedTokens] they are estimated to consume.
///
/// [excludedCount] reports how many offered candidates did not fit, so callers
/// can tell "nothing was relevant" (an empty candidate set) apart from "more was
/// relevant than fit the window" (Req 5.3). The result is immutable and
/// [included] is unmodifiable.
class BudgetedGrounding {
  /// The passages that fit within [groundingBudget], in the descending-score
  /// order they were supplied. Whole chunks only — never a truncated passage
  /// (Req 5.1, 5.3).
  final List<RetrievedPassage> included;

  /// The grounding token budget these passages were selected to fit within,
  /// i.e. the value returned by [RetrievalBudget.groundingBudget] for the same
  /// inputs. Never negative.
  final int groundingBudget;

  /// The estimated total tokens the [included] passages occupy. Always
  /// `≤ groundingBudget` (Req 5.1, 5.2).
  final int usedTokens;

  /// How many offered candidates were left out because they would have exceeded
  /// [groundingBudget] or the top-N cap (Req 5.3).
  final int excludedCount;

  BudgetedGrounding({
    required List<RetrievedPassage> included,
    required this.groundingBudget,
    required this.usedTokens,
    required this.excludedCount,
  }) : included = List<RetrievedPassage>.unmodifiable(included);

  /// Whether any grounding was injected at all. `false` means the prompt is
  /// answered without grounding (chat-only / "not found"), which is the correct
  /// outcome when the budget is exhausted by history/framing or no candidate
  /// was supplied (Req 5.5).
  bool get isEmpty => included.isEmpty;

  @override
  String toString() {
    return 'BudgetedGrounding(included: ${included.length}, '
        'usedTokens: $usedTokens, groundingBudget: $groundingBudget, '
        'excludedCount: $excludedCount)';
  }
}

/// A pure calculator that derives the grounding token budget from the chat
/// model's context window and selects the highest-scoring passages that fit
/// within it (design §"Retrieval Budget vs context window", Req 5).
///
/// An instance captures the model/prompt sizing inputs once — the window
/// ([contextSize]), the always-reserved reply capacity ([reservedReplyTokens]),
/// the estimated cost of the conversation history ([historyTokens]) and the
/// fixed prompt framing ([promptFramingTokens]) — so [groundingBudget],
/// [topN], and [fit] all read a single consistent budget. Nothing here performs
/// I/O; the caller supplies the already-estimated history/framing sizes.
class RetrievalBudget {
  /// The chat model's context window in tokens (`FllamaLlmEngine.contextSize`,
  /// e.g. 2048 or 4096). The whole prompt — grounding + history + framing — plus
  /// the reserved reply must fit within this (Req 5.1, 5.2).
  final int contextSize;

  /// Tokens reserved so the model can generate up to its reply cap (the engine's
  /// `maxTokens`). This is always subtracted first so a full grounded prompt can
  /// never eat the space needed for the reply (Req 5.4).
  final int reservedReplyTokens;

  /// Estimated tokens the recent conversation history will occupy in the prompt.
  /// Supplied by the caller (it owns the history window); subtracted from the
  /// window so grounding fits alongside it.
  final int historyTokens;

  /// Estimated tokens the fixed prompt framing occupies — the system framing and
  /// the user's current message — subtracted from the window so grounding leaves
  /// room for them.
  final int promptFramingTokens;

  /// Optional hard ceiling on how many passages may be included regardless of
  /// how many would fit the token budget. When null, only the token budget
  /// bounds the count. See [topN] for the effective cap.
  final int? maxPassages;

  /// The token estimator used to size candidate passages; defaults to the
  /// conservative chars ÷ 4 heuristic ([estimateTokens]).
  final TokenEstimator _estimateTokens;

  /// The default per-chunk character target used to derive a sensible top-N cap
  /// when [maxPassages] is not supplied, matching the chunker's ~800-char chunk
  /// size (`DocumentChunker.maxChunkChars`); an ~800-char chunk is ~200 tokens.
  static const int _defaultChunkTokens = 200;

  /// Creates a budget for a single grounded prompt.
  ///
  /// All token inputs are clamped to be non-negative; negative sizing values are
  /// meaningless and would otherwise inflate the budget. [contextSize] and
  /// [reservedReplyTokens] mirror the engine's `contextSize` and `maxTokens`.
  RetrievalBudget({
    required int contextSize,
    required int reservedReplyTokens,
    int historyTokens = 0,
    int promptFramingTokens = 0,
    this.maxPassages,
    TokenEstimator? estimateTokens,
  })  : contextSize = math.max(0, contextSize),
        reservedReplyTokens = math.max(0, reservedReplyTokens),
        historyTokens = math.max(0, historyTokens),
        promptFramingTokens = math.max(0, promptFramingTokens),
        _estimateTokens = estimateTokens ?? estimateTokensDefault;

  /// The tokens available for grounding after reserving the reply and
  /// accounting for history and framing (design §"Retrieval Budget"):
  ///
  /// ```
  /// contextSize − reservedReplyTokens − historyTokens − promptFramingTokens
  /// ```
  ///
  /// Clamped to `0` so an over-full window (history + framing + reply already
  /// exceed the context) yields no grounding rather than a negative budget
  /// (Req 5.2, 5.4).
  int get groundingBudget {
    final int remaining = contextSize -
        reservedReplyTokens -
        historyTokens -
        promptFramingTokens;
    return remaining < 0 ? 0 : remaining;
  }

  /// A hard cap on the number of passages to consider, derived from the
  /// [groundingBudget] (design §"Retrieval Budget"; wired into
  /// [SemanticContextRetriever]).
  ///
  /// With ~200-token chunks and a typical 2048-window budget this yields roughly
  /// 3–5 chunks, matching the 3.5 keyword retriever's `_topK = 5`. The estimate
  /// is `groundingBudget ÷ _defaultChunkTokens` (at least 1 when any budget
  /// exists, `0` when the window is already full), then further limited by
  /// [maxPassages] when set. It is a *bound on candidate work*, not a promise to
  /// return that many — [fit] still stops at the exact token budget.
  int get topN {
    final int budget = groundingBudget;
    int cap = budget <= 0 ? 0 : math.max(1, budget ~/ _defaultChunkTokens);
    if (maxPassages != null) {
      cap = math.min(cap, math.max(0, maxPassages!));
    }
    return cap;
  }

  /// Selects, from [candidates] (expected in descending-score order), the
  /// highest-scoring passages whose combined estimated token cost fits within
  /// [groundingBudget], returning them and the budgeting metadata (Req 5.1,
  /// 5.3).
  ///
  /// Selection walks the candidates in order and includes each passage only when
  /// its estimated token cost still fits the remaining budget; a passage that
  /// would overflow is skipped whole (never truncated) and the walk continues so
  /// a later, smaller high-value passage can still fit (Req 5.3). Inclusion also
  /// respects [topN], so no more than the derived cap of passages is returned.
  ///
  /// The order of [candidates] is preserved for the [included] set; this method
  /// does not re-rank. Callers that have not pre-sorted by descending score
  /// should do so first, since the budget is meant to admit the *most relevant*
  /// passages first. An empty [candidates] list yields empty grounding, which is
  /// the correct "nothing relevant" outcome (Req 5.5).
  BudgetedGrounding fit(List<RetrievedPassage> candidates) {
    final int budget = groundingBudget;
    final int cap = topN;

    final List<RetrievedPassage> included = <RetrievedPassage>[];
    int usedTokens = 0;
    int excluded = 0;

    for (final RetrievedPassage passage in candidates) {
      if (included.length >= cap) {
        excluded++;
        continue;
      }
      final int cost = _estimateTokens(passage.text);
      if (usedTokens + cost <= budget) {
        included.add(passage);
        usedTokens += cost;
      } else {
        // Whole-chunk only: exclude rather than truncate, but keep scanning so a
        // smaller high-ranked chunk can still fit (Req 5.3).
        excluded++;
      }
    }

    return BudgetedGrounding(
      included: included,
      groundingBudget: budget,
      usedTokens: usedTokens,
      excludedCount: excluded,
    );
  }

  /// Estimates the tokens [text] occupies using this budget's configured
  /// estimator (the chars ÷ 4 default unless overridden).
  int estimateTokens(String text) => _estimateTokens(text);

  /// The default conservative token estimate: `⌈text.length / 4⌉` (design
  /// §"Retrieval Budget"; open design question 3).
  ///
  /// English text averages ~4 characters per token, so dividing character count
  /// by four approximates the token count without a real tokenizer. Rounding up
  /// (ceiling) ensures a chunk is never estimated as cheaper than it is, so the
  /// selected grounding cannot silently exceed the true budget. Empty text costs
  /// `0` tokens.
  static int estimateTokensDefault(String text) {
    if (text.isEmpty) return 0;
    return (text.length + 3) ~/ 4;
  }
}
