/// Domain layer: the [ContextRetriever] abstraction over offline Project-Context
/// search, and the [RetrievedPassage] value object it returns.
///
/// Grounded answers work by retrieving the most relevant passages from the
/// Active_Project's material — its documents (titles + content) and characters
/// (name, role, notes) — and handing them to the Local Model as grounding, so
/// the reply reflects the writer's own text (Req 5.1, 5.2).
///
/// The state layer (`AiAssistantState`) depends only on this interface, never on
/// the concrete retrieval strategy, so the first-release keyword ranker
/// (`KeywordContextRetriever`) can later be swapped for an embedding-based
/// retriever without touching the state or presentation layers. Retrieval runs
/// fully on-device and never transmits the writer's content off the machine
/// (Req 5.3).
library;

/// A single passage surfaced from the Project Context, carrying the [text] that
/// grounds an answer plus a lightweight reference to where it came from, so the
/// assistant can cite the source and the writer can trust and locate the
/// material (Req 5.2, 5.4).
///
/// It names the source [id] (the document or character identifier) and a
/// human-readable [title] (the document title or character name) for display as
/// a source hint, and carries a [score] measuring how relevant the passage is to
/// the query so callers can order or threshold results (higher is more
/// relevant).
///
/// Like the other domain value objects ([ChatMessage], [Character]), a passage
/// is immutable and supports value equality and [copyWith].
class RetrievedPassage {
  /// The passage text handed to the Local Model as grounding.
  final String text;

  /// Identifier of the source document or character this passage came from.
  final String sourceId;

  /// Human-readable label for the source (document title or character name),
  /// shown in the source hint (Req 5.4).
  final String sourceTitle;

  /// How relevant this passage is to the query (higher is more relevant). Used
  /// by callers to rank and threshold results; defaults to `0.0`.
  final double score;

  const RetrievedPassage({
    required this.text,
    required this.sourceId,
    required this.sourceTitle,
    this.score = 0.0,
  });

  /// Returns a copy with the given fields replaced.
  RetrievedPassage copyWith({
    String? text,
    String? sourceId,
    String? sourceTitle,
    double? score,
  }) {
    return RetrievedPassage(
      text: text ?? this.text,
      sourceId: sourceId ?? this.sourceId,
      sourceTitle: sourceTitle ?? this.sourceTitle,
      score: score ?? this.score,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RetrievedPassage &&
        other.text == text &&
        other.sourceId == sourceId &&
        other.sourceTitle == sourceTitle &&
        other.score == score;
  }

  @override
  int get hashCode => Object.hash(text, sourceId, sourceTitle, score);

  @override
  String toString() {
    return 'RetrievedPassage(sourceId: $sourceId, sourceTitle: $sourceTitle, '
        'score: $score, text.length: ${text.length})';
  }
}

/// Abstracts "query → ranked Project-Context passages" so the state layer never
/// depends on a concrete retrieval strategy (Req 5.1, 5.2).
///
/// Implementations search only the Active_Project's material and operate fully
/// offline, never transmitting the writer's content off the device (Req 5.3,
/// 5.6). When nothing relevant is found — including an empty project with no
/// documents or characters — [retrieve] returns an empty list so the assistant
/// can still chat and report that it found no project material (Req 5.5).
abstract class ContextRetriever {
  /// Returns the most relevant Project-Context passages for [query], ordered by
  /// descending relevance ([RetrievedPassage.score]), or an empty list when no
  /// relevant material is found (Req 5.2, 5.4, 5.5).
  ///
  /// Runs fully offline over the Active_Project only (Req 5.3, 5.6).
  Future<List<RetrievedPassage>> retrieve(String query);

  /// Whether the Active_Project has any searchable material at all — i.e. at
  /// least one document or character contributes an indexed passage.
  ///
  /// An empty result from [retrieve] is ambiguous: it can mean either the
  /// project has no material to search (a brand-new project with no documents
  /// or characters) or that the project has material but nothing matched this
  /// particular query. Callers use this to tell the two apart, so the assistant
  /// can still chat and honestly report that it found *no project material to
  /// search* only when the project is genuinely empty (Req 5.5).
  ///
  /// Runs fully offline over the Active_Project only (Req 5.3, 5.6). The default
  /// treats a retriever as always having material; index-backed implementations
  /// override this to reflect their actual contents.
  Future<bool> hasProjectMaterial() async => true;
}
