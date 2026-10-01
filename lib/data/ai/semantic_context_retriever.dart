/// Data layer: the Tier-2 semantic [ContextRetriever] that grounds the
/// assistant in the writer's own material by *meaning* rather than word overlap
/// (design §3 "SemanticContextRetriever", Req 1, 2, 5).
///
/// Where the Tier-1 [KeywordContextRetriever] ranks passages by lexical term
/// overlap, [SemanticContextRetriever] embeds the [query] with the on-device
/// [EmbeddingModel] and compares that query vector against the project's stored
/// chunk vectors by cosine similarity, so a passage whose wording differs from
/// the question can still surface as long as its *meaning* is close (Req 1.1,
/// 1.2). It is a drop-in for the same [ContextRetriever] seam, so the state and
/// presentation layers are unchanged and the composite retriever can pick
/// between semantic and keyword grounding (Req 1.3, 7.5).
///
/// **How [retrieve] works** (design §3, steps 1–5):
/// 1. Embed the query through the injected [EmbeddingModel] (the model applies
///    any task-instruction prefix such as `search_query:` internally, so raw
///    text is passed here), and normalize it so cosine reduces to a dot product
///    (design §"Embedding encoding").
/// 2. Stream the project's stored chunk vectors from [ChunkEmbeddingRepository]
///    in bounded pages via [ChunkEmbeddingRepository.scanProject], never
///    deserializing the whole index at once (Req 2.5, 8.4), scoring each chunk
///    with [VectorCodec] cosine while keeping only a bounded set of the best
///    candidates.
/// 3. Apply the relevance floor [minSimilarity]: a chunk below it contributes
///    nothing, so a weak match never pads the grounding (Req 5.5).
/// 4. Return the top-[topN] surviving chunks as [RetrievedPassage]s (text +
///    `sourceId` + `sourceTitle` + `score`) in descending similarity, scoped to
///    [projectId] because the scan itself is project-scoped (Req 1.4, 1.5).
/// 5. Order deterministically so repeated identical queries yield a stable set:
///    by descending score, then ascending `(sourceId, chunkIndex)` as the
///    tie-break, and finally the stable chunk `id`, since cosine over the same
///    stored vectors is reproducible each call (Req 1.6).
///
/// **Robustness (behind the seam).** A stored row whose vector length does not
/// match the query embedding's [EmbeddingModel.dimension] — a corrupt/mis-shaped
/// BLOB — is skipped rather than allowed to crash the scan;
/// [ChunkEmbeddingRepository.scanProject] already drops rows whose BLOB is not a
/// whole number of Float32s, and this retriever additionally guards on the
/// decoded vector length (Req 7.4).
///
/// **Stale-model index (Req 7.4; design §"Error Handling" — Dimension
/// mismatch).** Each stored row is tagged with the `model_id` / `dim` that
/// produced it. When the embedding model has changed (an app update swaps
/// bge-small for another model, say), the project's stored vectors were produced
/// by a *different* model and can no longer be meaningfully compared to a query
/// this model embeds — the numbers still have a length, but the geometry is a
/// different space. This retriever detects that condition by comparing every
/// scanned row's [StoredChunkEmbedding.modelId] / [StoredChunkEmbedding.dim]
/// against the current [EmbeddingModel.modelId] / [EmbeddingModel.dimension]:
/// a mismatching row is *treated as invalid for cosine* and skipped, and the
/// project is **flagged for reindex** via the optional [onStaleIndexDetected]
/// callback (fired at most once per [retrieve]). Signalling is recoverable and
/// non-blocking — the retriever does not throw, delete, or rebuild anything
/// itself; it simply skips the stale rows (so the scan naturally yields no
/// semantic grounding and the composite retriever falls back to keyword until
/// the reindex the callback triggers rebuilds the index) and lets the state
/// layer own the actual rebuild and any surfaced status (tasks 9, 12, 13).
///
/// Query-time failures (model load error, index read error) are still allowed to
/// **throw**, honoring the [ContextRetriever] contract so the composite
/// retriever can degrade to keyword or chat-only grounding rather than break
/// (Req 7.4). A stale index is deliberately *not* an error: it is an expected,
/// self-healing condition, so it is signalled rather than thrown.
///
/// **Emptiness (Req 5.5).** [hasProjectMaterial] reports whether the project has
/// any stored chunk vector at all, backed by
/// [ChunkEmbeddingRepository.countForProject], letting a caller tell an
/// *unindexed / empty* project apart from a *no-match* query — the former means
/// "no project material to search", the latter "material exists but none was
/// relevant".
library;

import '../../domain/ai/context_retriever.dart';
import '../../domain/ai/embedding_model.dart';
import 'chunk_embedding_repository.dart';
import 'vector_codec.dart';

/// Signalled when [SemanticContextRetriever.retrieve] finds that the project's
/// stored vectors were produced by a *different* embedding model than the one
/// now in use (their `model_id` / `dim` no longer match), so the index is stale
/// and needs rebuilding (design §"Error Handling" — Dimension mismatch, Req
/// 7.4).
///
/// The retriever calls this at most once per query, *after* skipping the stale
/// rows, and never blocks on it: the callback is the seam by which the state /
/// indexer layer (tasks 9, 12, 13) triggers a recoverable, non-blocking reindex
/// of the given project and surfaces any status. The retriever itself neither
/// deletes nor rebuilds — it only reports.
typedef StaleIndexCallback = void Function(String projectId);

/// A semantic [ContextRetriever] that ranks the Active_Project's stored chunk
/// vectors by cosine similarity to an embedded query.
///
/// Construction is cheap and does no I/O: the query embedding and the paged
/// vector scan happen on [retrieve]. The retriever is scoped to [projectId] and
/// every read goes through [ChunkEmbeddingRepository] with that id, so no other
/// project's material can appear in results (Req 1.5, 8.4).
class SemanticContextRetriever implements ContextRetriever {
  /// The maximum number of passages [retrieve] returns — a hard cap on the
  /// grounding handed to the Local Model. Defaults to `5`, matching the Tier-1
  /// keyword retriever's `_topK` and the design's "roughly 3–5 chunks fit" note;
  /// the retrieval-budget calculator (task 8) derives a tighter cap from the
  /// chat model's `contextSize`/`maxTokens` and passes it as [topN] (Req 5.1,
  /// 5.2).
  static const int defaultTopN = 5;

  /// The default relevance floor: a chunk whose cosine similarity to the query
  /// is below this contributes no grounding (Req 5.5). Cosine of two L2-unit
  /// vectors lies in `[-1, 1]`; this modest positive floor keeps only chunks
  /// with a real positive signal while still admitting the meaning-close matches
  /// semantic retrieval exists to surface. The composite/budget layer may pass a
  /// tuned value via [minSimilarity].
  static const double defaultMinSimilarity = 0.25;

  /// The embedding runtime used to turn the query into a vector (Req 1.1). Only
  /// the query is embedded here; chunk vectors were embedded at index time and
  /// are read back already normalized.
  final EmbeddingModel _embeddingModel;

  /// The project-scoped vector index this retriever scans and counts (Req 1.5,
  /// 2.5, 8.4).
  final ChunkEmbeddingRepository _embeddings;

  /// The Active_Project this retriever is scoped to. Only this project's stored
  /// vectors are scanned and counted (Req 1.5, 8.4).
  final String projectId;

  /// The maximum number of passages [retrieve] returns (see [defaultTopN]).
  final int topN;

  /// The relevance floor applied to every candidate (see [defaultMinSimilarity],
  /// Req 5.5).
  final double minSimilarity;

  /// Called at most once per [retrieve] when the scan encounters vectors this
  /// model did not produce (stale `model_id` / `dim`), so the state / indexer
  /// layer can trigger a recoverable, non-blocking reindex of [projectId] (Req
  /// 7.4). Optional: when null, stale rows are still skipped, they are just not
  /// reported.
  final StaleIndexCallback? _onStaleIndexDetected;

  /// Creates a retriever over [embeddingModel] and [embeddings], scoped to
  /// [projectId]. No I/O happens here; the query is embedded and the index
  /// scanned on [retrieve].
  ///
  /// [topN] caps how many passages are returned (defaults to [defaultTopN]) and
  /// [minSimilarity] is the relevance floor (defaults to [defaultMinSimilarity]).
  ///
  /// [onStaleIndexDetected] is an optional non-blocking signal invoked when the
  /// scan finds vectors produced by a different embedding model, so the caller
  /// can flag [projectId] for reindex (Req 7.4).
  SemanticContextRetriever({
    required EmbeddingModel embeddingModel,
    required ChunkEmbeddingRepository embeddings,
    required this.projectId,
    this.topN = defaultTopN,
    this.minSimilarity = defaultMinSimilarity,
    StaleIndexCallback? onStaleIndexDetected,
  })  : _embeddingModel = embeddingModel,
        _embeddings = embeddings,
        _onStaleIndexDetected = onStaleIndexDetected;

  /// Returns the most semantically relevant Project-Context passages for
  /// [query], ordered by descending similarity, or an empty list when no chunk
  /// clears the [minSimilarity] floor (Req 1.2, 1.4, 5.5).
  ///
  /// Embeds and normalizes the query, then pages the project's stored vectors
  /// through [ChunkEmbeddingRepository.scanProject], scoring each with
  /// [VectorCodec.dot] over the two unit vectors (cosine), keeping only chunks
  /// at or above [minSimilarity], and returning the top-[topN] in the
  /// deterministic order described on the class (Req 1.6, 2.5).
  ///
  /// A query with no usable text (empty or whitespace) yields an empty list
  /// without touching the index. Throws if the embedding model or the index read
  /// fails, so the composite retriever can fall back (Req 7.4).
  @override
  Future<List<RetrievedPassage>> retrieve(String query) async {
    if (query.trim().isEmpty) {
      return const <RetrievedPassage>[];
    }

    // Embed the query and normalize it so cosine similarity against the stored
    // (already-normalized) chunk vectors is a plain dot product. A failure here
    // propagates so the composite retriever can degrade (Req 7.4). Embedding
    // also ensures the model is loaded, so its modelId/dimension are now stable
    // and can be compared against each stored row's tag below.
    final List<double> rawQueryVector = await _embeddingModel.embed(query);
    final List<double> queryVector = VectorCodec.normalize(rawQueryVector);
    final int queryDim = queryVector.length;
    if (queryDim == 0) {
      return const <RetrievedPassage>[];
    }

    // The id/dimension of the model now in use. Any stored row tagged with a
    // different model produced its vector in a different embedding space and
    // cannot be compared here, so it is treated as stale (design §"Error
    // Handling" — Dimension mismatch, Req 7.4).
    final String currentModelId = _embeddingModel.modelId;
    final int currentDim = _embeddingModel.dimension;

    // Set when at least one stored row was produced by a different embedding
    // model, so the project can be flagged for reindex exactly once after the
    // scan completes (Req 7.4).
    bool staleIndexDetected = false;

    // Accumulate every clearing candidate across pages, then rank once. The
    // stored vectors for one project are small (design §"Scale/Memory"), and the
    // paged scan already bounds peak memory by never deserializing the whole
    // index at once (Req 2.5); we keep only the compact scored candidates, not
    // the raw vectors, so this list stays small.
    final List<RetrievedPassage> candidates = <RetrievedPassage>[];

    await for (final List<StoredChunkEmbedding> batch
        in _embeddings.scanProject(projectId)) {
      for (final StoredChunkEmbedding stored in batch) {
        // Stale-model detection (Req 7.4): a row whose declared model_id/dim was
        // produced by a *different* embedding model lives in a different vector
        // space, so cosine against this query is meaningless. Skip it and flag
        // the project for reindex; the retriever never deletes or rebuilds, it
        // only reports (the state/indexer layer owns the rebuild).
        if (stored.modelId != currentModelId || stored.dim != currentDim) {
          staleIndexDetected = true;
          continue;
        }

        // Skip a corrupt or otherwise mis-shaped row: even with a matching tag,
        // a decoded vector whose length differs from the query embedding's
        // cannot be compared, so drop it rather than crash the scan (Req 7.4).
        if (stored.embedding.length != queryDim) continue;

        final double score = VectorCodec.dot(queryVector, stored.embedding);
        // Apply the relevance floor: below it, contribute nothing rather than
        // pad the grounding with weak matches (Req 5.5).
        if (score < minSimilarity) continue;

        candidates.add(RetrievedPassage(
          text: stored.text,
          sourceId: stored.sourceId,
          sourceTitle: stored.sourceTitle,
          score: score,
        ));
        // Remember the tie-break key alongside the passage for a stable sort.
        _tieBreak[candidates.length - 1] = _ChunkKey(
          sourceId: stored.sourceId,
          chunkIndex: stored.chunkIndex,
          id: stored.id,
        );
      }
    }

    // Signal a stale-model index exactly once per query, after the scan, so the
    // state/indexer layer can trigger a recoverable, non-blocking reindex of
    // this project. Fired regardless of whether any valid rows survived, since a
    // partially-migrated index (some current, some stale rows) still needs
    // rebuilding. The retriever does not block on or rebuild anything itself
    // (Req 7.4).
    if (staleIndexDetected) {
      _onStaleIndexDetected?.call(projectId);
    }

    if (candidates.isEmpty) {
      return const <RetrievedPassage>[];
    }

    // Deterministic ordering (Req 1.6): descending score, then ascending
    // (sourceId, chunkIndex), then the stable chunk id, so equal-scoring chunks
    // always come back in the same order and repeated identical queries yield a
    // stable set.
    final List<int> order =
        List<int>.generate(candidates.length, (int i) => i);
    order.sort((int a, int b) {
      final int byScore =
          candidates[b].score.compareTo(candidates[a].score);
      if (byScore != 0) return byScore;
      return _tieBreak[a]!.compareTo(_tieBreak[b]!);
    });

    final int take = order.length < topN ? order.length : topN;
    final List<RetrievedPassage> ranked = <RetrievedPassage>[
      for (int i = 0; i < take; i++) candidates[order[i]],
    ];
    _tieBreak.clear();
    return List<RetrievedPassage>.unmodifiable(ranked);
  }

  /// Per-candidate tie-break keys, indexed by position in `candidates` during a
  /// single [retrieve] call, then cleared. Kept off [RetrievedPassage] because
  /// the domain value object carries only citation fields, not index-internal
  /// ordering keys.
  final Map<int, _ChunkKey> _tieBreak = <int, _ChunkKey>{};

  /// Whether the Active_Project has any stored chunk vector at all, backed by
  /// [ChunkEmbeddingRepository.countForProject] (Req 2.5, 5.5).
  ///
  /// Lets a caller seeing an empty [retrieve] result tell an *unindexed / empty*
  /// project (nothing stored) apart from a *no-match* query (vectors exist but
  /// none cleared the relevance floor), so the assistant reports "no project
  /// material to search" only for the former. Runs fully offline over the
  /// Active_Project only (Req 1.5, 8.4).
  @override
  Future<bool> hasProjectMaterial() async {
    return (await _embeddings.countForProject(projectId)) > 0;
  }
}

/// The deterministic tie-break key for a candidate chunk: `(sourceId,
/// chunkIndex)` ascending with the stable chunk `id` as a final discriminator,
/// so equal-scoring passages order identically on every call (Req 1.6).
class _ChunkKey implements Comparable<_ChunkKey> {
  final String sourceId;
  final int chunkIndex;
  final String id;

  const _ChunkKey({
    required this.sourceId,
    required this.chunkIndex,
    required this.id,
  });

  @override
  int compareTo(_ChunkKey other) {
    final int bySource = sourceId.compareTo(other.sourceId);
    if (bySource != 0) return bySource;
    final int byIndex = chunkIndex.compareTo(other.chunkIndex);
    if (byIndex != 0) return byIndex;
    return id.compareTo(other.id);
  }
}
