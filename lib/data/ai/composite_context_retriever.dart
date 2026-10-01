/// Data layer: [CompositeContextRetriever], the single [ContextRetriever] seam
/// handed to `AiAssistantState` that composes the two grounding strategies and
/// handles query-time fallback so the assistant always has a working path
/// (design §4 "CompositeContextRetriever", Req 7).
///
/// The retrieval feature ships two concrete retrievers behind the same domain
/// seam: the Tier-2 [SemanticContextRetriever], which ranks the project's stored
/// chunk vectors by meaning, and the Tier-1 [KeywordContextRetriever], which
/// ranks the same material by lexical overlap and needs neither an embedding
/// model nor a built index. This composite chooses between them per query and
/// degrades gracefully, so the assistant keeps working before the embedding
/// model is downloaded, while the index is still building, or if semantic
/// retrieval fails at query time (Req 7.1–7.4). Because it is itself a
/// [ContextRetriever], the state and presentation layers never learn there are
/// two tiers — the fallback lives entirely behind the seam (Req 7.5).
///
/// **Precedence (design §4, highest first):**
///
/// 1. **Semantic** — used when the embedding model is ready *and* the project
///    has at least one stored embedding. Readiness comes from the injected
///    [isSemanticReady] gate (backed by the embedding-model / [IndexingState]
///    status in the wiring layer), and index presence from the semantic
///    retriever's own [SemanticContextRetriever.hasProjectMaterial]. A partial
///    index while building still counts as available: the semantic scan returns
///    whatever vectors exist right now, and any gap is covered by the keyword
///    fallback (Req 7.2).
/// 2. **Keyword** — the [KeywordContextRetriever], used when semantic is
///    unavailable (model not downloaded, index empty or still building) or when
///    semantic [retrieve] *throws* at query time. A semantic error is swallowed
///    into a keyword fallback — recoverable and non-blocking — and reported once
///    through the optional [onSemanticError] hook so the wiring layer can set a
///    transient status without surfacing a chat error (Req 7.1, 7.2, 7.4).
/// 3. **Chat-only** — if both tiers return empty, this composite returns an
///    empty list and `AiAssistantState` answers as a general assistant, exactly
///    as in 3.5 (Req 7.3).
///
/// **Budgeting.** When a [RetrievalBudget] is supplied, the semantic result is
/// fit to the model's grounding budget here — the highest-scoring passages that
/// fit the window, whole chunks only, in descending-score order — so the
/// composite is the single place the budget's top-N/token cap is applied to
/// semantic grounding consistent with the design (design §"Retrieval Budget";
/// Req 5). The keyword fallback is returned as-is (it already caps its own
/// top-k), so a budget change never blocks the fallback path.
///
/// **`hasProjectMaterial` (Req 5.5, 7).** Reported as the OR of the two tiers:
/// the project has searchable material if *either* the vector index holds a
/// stored chunk *or* the keyword index holds a passage. This keeps the
/// emptiness semantics of both tiers intact across the fallback — a caller can
/// still tell an *empty project* (nothing to search in either tier) apart from a
/// *no-match query* (material exists but none was relevant), so the assistant
/// reports "no project material to search" only when the project is genuinely
/// empty.
library;

import '../../domain/ai/context_retriever.dart';
import 'keyword_context_retriever.dart';
import 'retrieval_budget.dart';
import 'semantic_context_retriever.dart';

/// A [ContextRetriever] that composes a primary [SemanticContextRetriever] with
/// a fallback [KeywordContextRetriever], trying semantic grounding first and
/// degrading to keyword grounding whenever semantic is unavailable, yields
/// nothing usable, or fails at query time (design §4, Req 7).
///
/// Construction is cheap and does no I/O; the tiers do their own lazy work on
/// [retrieve]. Both tiers must be scoped to the *same* project so the composite
/// never mixes material across projects (the wiring layer builds them per
/// project, Req 1.5, 8.4).
class CompositeContextRetriever implements ContextRetriever {
  /// The primary, meaning-based retriever. Tried first whenever it is available
  /// (Req 1, 7 precedence).
  final SemanticContextRetriever _semantic;

  /// The fully-offline lexical retriever used as the fallback whenever semantic
  /// is unavailable, empty, or errors (Req 7.1, 7.2, 7.4).
  final KeywordContextRetriever _keyword;

  /// Readiness gate for the semantic tier: returns `true` when the embedding
  /// model is loaded/ready. Combined with the index-present check
  /// ([SemanticContextRetriever.hasProjectMaterial]) to decide whether semantic
  /// is worth attempting for a query. Supplied by the wiring layer from the
  /// embedding-model / [IndexingState] status; defaults to always-ready so the
  /// composite can be used with a self-gating semantic tier (Req 7.1).
  final bool Function() isSemanticReady;

  /// Optional budget applied to the semantic result before it is returned: the
  /// highest-scoring passages that fit the model's grounding window, whole
  /// chunks only, in descending-score order (design §"Retrieval Budget", Req 5).
  /// When `null`, the semantic result is returned unbudgeted (the semantic
  /// retriever's own `topN` still bounds it).
  final RetrievalBudget? budget;

  /// Optional hook invoked (once per failed query) when semantic retrieval
  /// throws and the composite falls back to keyword grounding. Lets the wiring
  /// layer record a recoverable, non-blocking transient status without ever
  /// surfacing the failure as a chat error (Req 7.4). Never called on the normal
  /// "semantic returned empty" path — only on a thrown error.
  final void Function(Object error)? onSemanticError;

  /// Creates a composite over [semantic] (primary) and [keyword] (fallback).
  ///
  /// [isSemanticReady] gates whether the semantic tier is attempted (defaults to
  /// always-ready); [budget] optionally caps semantic grounding to the model's
  /// window; [onSemanticError] optionally observes a swallowed query-time
  /// semantic failure so the wiring layer can surface a non-blocking status.
  CompositeContextRetriever({
    required SemanticContextRetriever semantic,
    required KeywordContextRetriever keyword,
    bool Function()? isSemanticReady,
    this.budget,
    this.onSemanticError,
  })  : _semantic = semantic,
        _keyword = keyword,
        isSemanticReady = isSemanticReady ?? _alwaysReady;

  /// Returns the most relevant Project-Context passages for [query], preferring
  /// semantic grounding and falling back to keyword grounding, or an empty list
  /// when neither tier finds anything (→ chat-only, Req 7.3).
  ///
  /// The path is (design §4):
  /// 1. If the semantic tier is ready ([isSemanticReady]) *and* the project has
  ///    stored vectors ([SemanticContextRetriever.hasProjectMaterial]), attempt
  ///    semantic retrieval. On a non-empty result, fit it to the [budget] (when
  ///    set) and return it — this is the preferred grounding (Req 1, 7.2).
  /// 2. If the semantic tier is not ready/empty, or its [retrieve] throws, or it
  ///    returns nothing usable, fall through to the keyword retriever. A thrown
  ///    error is swallowed (recoverable, non-blocking) and reported once via
  ///    [onSemanticError] (Req 7.1, 7.2, 7.4).
  /// 3. The keyword result (possibly empty) is returned as the fallback; an
  ///    empty result leaves the assistant to answer chat-only (Req 7.3).
  ///
  /// This method never throws for a retrieval reason: every tier failure is
  /// caught and degraded, so the assistant always has a working path (Req 7).
  @override
  Future<List<RetrievedPassage>> retrieve(String query) async {
    if (await _semanticAvailable()) {
      try {
        final List<RetrievedPassage> semantic = await _semantic.retrieve(query);
        if (semantic.isNotEmpty) {
          return _applyBudget(semantic);
        }
        // Semantic returned nothing usable: degrade to keyword rather than pad
        // the grounding with a weak semantic set (Req 7.2). This is the normal
        // "no meaning-close match" path, not an error, so [onSemanticError] is
        // deliberately not called here.
      } catch (error) {
        // A query-time semantic failure (model load/embed error, index read
        // error) is recoverable and non-blocking: swallow it, report it once so
        // the wiring layer can set a transient status, and fall back to keyword
        // grounding rather than break the conversation (Req 7.4).
        onSemanticError?.call(error);
      }
    }

    // Fallback tier: keyword grounding, which needs no embedding model or built
    // index. May itself be empty, in which case the assistant answers chat-only
    // (existing 3.5 behaviour, Req 7.1, 7.3).
    return _keyword.retrieve(query);
  }

  /// Whether the semantic tier should be attempted for a query: the embedding
  /// model is ready ([isSemanticReady]) *and* the project has at least one
  /// stored embedding ([SemanticContextRetriever.hasProjectMaterial]).
  ///
  /// A `false` here (model not downloaded, index empty / not yet built) routes
  /// straight to the keyword fallback without touching the embedding runtime, so
  /// the assistant never blocks on the missing model or an empty index (Req 7.1,
  /// 7.2). A partial index still returns `true` because it holds ≥1 vector, and
  /// the composite tries semantic then falls back per query (Req 7.2).
  Future<bool> _semanticAvailable() async {
    if (!isSemanticReady()) return false;
    return _semantic.hasProjectMaterial();
  }

  /// Fits [passages] to the grounding [budget] when one is configured, returning
  /// the highest-scoring passages that fit the model's window in descending
  /// order (whole chunks only); returns [passages] unchanged when no budget is
  /// set (design §"Retrieval Budget", Req 5).
  List<RetrievedPassage> _applyBudget(List<RetrievedPassage> passages) {
    final RetrievalBudget? budget = this.budget;
    if (budget == null) return passages;
    return budget.fit(passages).included;
  }

  /// Whether the Active_Project has any searchable material at all, across both
  /// tiers — the OR of the semantic vector index and the keyword passage index
  /// (Req 5.5, 7).
  ///
  /// Preserving the emptiness semantics of both tiers means a caller seeing an
  /// empty [retrieve] result can still tell an *empty project* (neither tier has
  /// material) apart from a *no-match query* (material exists in at least one
  /// tier but none was relevant), so the assistant reports "no project material
  /// to search" only when the project is genuinely empty. Runs fully offline
  /// over the Active_Project only (Req 5.3, 8.4).
  @override
  Future<bool> hasProjectMaterial() async {
    // The two checks are independent (a vector count and a keyword-index build),
    // so run them concurrently and OR the results.
    final List<bool> results = await Future.wait<bool>(<Future<bool>>[
      _semantic.hasProjectMaterial(),
      _keyword.hasProjectMaterial(),
    ]);
    return results.any((bool hasMaterial) => hasMaterial);
  }

  /// The default [isSemanticReady] gate: always ready, so the composite relies
  /// solely on the index-present check and the per-query try/catch. The wiring
  /// layer overrides this with the real embedding-model readiness signal.
  static bool _alwaysReady() => true;
}
