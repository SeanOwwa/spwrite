/// Data layer: the Tier-1, fully-offline [ContextRetriever] that grounds the
/// assistant in the writer's own material by keyword search over an in-memory
/// passage index (design §5).
///
/// [KeywordContextRetriever] reads the Active_Project's documents (title +
/// Markdown content) and characters (name, role, notes) through the **existing**
/// [DocumentRepository] and [CharacterRepository] — the same content already in
/// SQLite — and splits it into small [_Passage]s tagged with their source
/// document/character title. It is scoped to a single project id, so content
/// from other projects is never surfaced (Req 5.1, 5.3, 5.6).
///
/// This file establishes the class shape and index-building responsibility, and
/// implements the lexical ranking (design §5, Tier 1): [retrieve] tokenizes the
/// query and each indexed passage, weights terms by inverse document frequency
/// across the index (a BM25-lite term-overlap score), and returns the top-k
/// passages by descending relevance, each carrying its source title.
///
/// For the empty-project case (Req 5.5), [hasProjectMaterial] reports whether
/// the built index holds any passage at all, letting callers tell a project
/// with no documents or characters apart from one whose material simply did not
/// match the query — so the assistant can still chat and honestly say it found
/// no project material to search.
///
/// The state layer depends only on the domain [ContextRetriever] interface, so
/// this concrete keyword ranker can later be swapped for an embedding-based
/// retriever without touching state or presentation (design §5, Tier 2).
library;

import 'dart:math' as math;

import '../../domain/ai/context_retriever.dart';
import '../../domain/character.dart';
import '../../domain/character_repository.dart';
import '../../domain/document.dart';
import '../../domain/document_repository.dart';

/// A single indexed unit of Project-Context material: a chunk of source [text]
/// tagged with the [sourceId] and human-readable [sourceTitle] it came from.
///
/// Passages are the granularity at which the retriever ranks and returns
/// content: a long document is split into several passages so a query can
/// surface just the relevant paragraph rather than the whole file, while a
/// character contributes a compact passage built from its name, role, and notes.
/// A passage is projected to the domain [RetrievedPassage] (with a relevance
/// score) when it is returned from [KeywordContextRetriever.retrieve].
class _Passage {
  /// The passage text handed to the Local Model as grounding.
  final String text;

  /// Identifier of the source document or character this passage came from.
  final String sourceId;

  /// Human-readable label for the source (document title or character name),
  /// shown as a source hint (Req 5.4).
  final String sourceTitle;

  const _Passage({
    required this.text,
    required this.sourceId,
    required this.sourceTitle,
  });

  /// Projects this passage to a domain [RetrievedPassage] with the given
  /// relevance [score] (assigned by the ranker in task 2.2).
  RetrievedPassage toRetrieved(double score) {
    return RetrievedPassage(
      text: text,
      sourceId: sourceId,
      sourceTitle: sourceTitle,
      score: score,
    );
  }
}

/// A fully-offline [ContextRetriever] that indexes the Active_Project's
/// documents and characters in memory and answers queries by keyword relevance.
///
/// Construction is cheap: the index is built lazily on the first [retrieve] call
/// (or an explicit [refresh]) so wiring the retriever into the state layer does
/// not touch the database until the assistant is actually used. The index is
/// scoped to [projectId]; the repositories are queried with that id so no other
/// project's material can appear in results (Req 5.6).
class KeywordContextRetriever implements ContextRetriever {
  /// The character budget for a single document passage. Document content is
  /// chunked on paragraph/heading boundaries and further split so no passage
  /// exceeds roughly this many characters, keeping each unit small enough to
  /// rank precisely and cheap to hand the model as grounding.
  static const int _maxPassageChars = 800;

  /// The maximum number of passages [retrieve] returns. Keeps the grounding
  /// handed to the Local Model compact — enough context to answer from the
  /// writer's own material without flooding the prompt (design §5, Req 5.2).
  static const int _topK = 5;

  /// The shortest token length kept during tokenization. Single- and
  /// two-character fragments (and the stopwords below) carry little signal, so
  /// dropping them sharpens term overlap without discarding meaningful words.
  static const int _minTokenLength = 3;

  /// BM25 term-frequency saturation. Higher values let repeated terms keep
  /// adding weight; a mid value diminishes the return of each extra occurrence.
  static const double _bm25K1 = 1.2;

  /// BM25 length-normalization strength. `0` ignores passage length; `1` fully
  /// normalizes by it. A mid value gently favors focused passages without
  /// unduly penalizing longer, still-relevant ones.
  static const double _bm25B = 0.75;

  /// Very common words that match almost any text and so add noise rather than
  /// signal. Dropped from both the query and passage token streams.
  static const Set<String> _stopwords = <String>{
    'the', 'and', 'are', 'was', 'were', 'for', 'that', 'this', 'with', 'have',
    'has', 'had', 'not', 'but', 'you', 'your', 'his', 'her', 'she', 'him',
    'they', 'them', 'their', 'what', 'which', 'who', 'whom', 'when', 'where',
    'why', 'how', 'about', 'from', 'into', 'onto', 'over', 'under', 'then',
    'than', 'there', 'here', 'been', 'being', 'does', 'did', 'doing', 'done',
    'would', 'could', 'should', 'will', 'shall', 'can', 'may', 'might', 'must',
  };

  /// Source of the project's documents (titles + content) (Req 5.1).
  final DocumentRepository _documents;

  /// Source of the project's characters (name, role, notes) (Req 5.1).
  final CharacterRepository _characters;

  /// The Active_Project this retriever is scoped to. Only this project's
  /// material is indexed and searched (Req 5.6).
  final String projectId;

  /// The in-memory passage index, or `null` until it has been built. Rebuilt by
  /// [refresh] and lazily populated by [_ensureIndexed] on first use.
  List<_Passage>? _passages;

  /// Creates a retriever over [documentRepository] and [characterRepository],
  /// scoped to [projectId]. No I/O happens here; the index is built on demand.
  KeywordContextRetriever({
    required DocumentRepository documentRepository,
    required CharacterRepository characterRepository,
    required this.projectId,
  })  : _documents = documentRepository,
        _characters = characterRepository;

  /// Returns the most relevant Project-Context passages for [query], ordered by
  /// descending relevance, or an empty list when no relevant material is found
  /// (Req 5.2, 5.4, 5.5).
  ///
  /// Ensures the in-memory index is built first, then ranks the passages against
  /// the query with a BM25-lite lexical scorer (tokenized term overlap weighted
  /// by inverse document frequency over the in-memory index) and returns the
  /// top-[_topK] positively-scored passages, each carrying its source title
  /// (Req 5.2, 5.4).
  ///
  /// A query with no usable terms (empty, whitespace, or only stopwords/short
  /// tokens), or an index in which nothing overlaps the query, yields an empty
  /// list so the assistant can still chat and report it found no relevant
  /// material (Req 5.5).
  @override
  Future<List<RetrievedPassage>> retrieve(String query) async {
    await _ensureIndexed();

    final List<_Passage> passages = _passages ?? const <_Passage>[];
    final List<String> queryTerms = _tokenize(query);
    if (passages.isEmpty || queryTerms.isEmpty) {
      return const <RetrievedPassage>[];
    }

    // Tokenize each passage once, deriving the per-passage term-frequency map,
    // its token length, and the corpus-wide document frequencies used for IDF.
    final List<Map<String, int>> termFrequencies =
        List<Map<String, int>>.filled(passages.length, const <String, int>{});
    final List<int> lengths = List<int>.filled(passages.length, 0);
    final Map<String, int> documentFrequencies = <String, int>{};

    for (int i = 0; i < passages.length; i++) {
      final List<String> tokens = _tokenize(passages[i].text);
      lengths[i] = tokens.length;

      final Map<String, int> counts = <String, int>{};
      for (final String token in tokens) {
        counts[token] = (counts[token] ?? 0) + 1;
      }
      termFrequencies[i] = counts;

      for (final String term in counts.keys) {
        documentFrequencies[term] = (documentFrequencies[term] ?? 0) + 1;
      }
    }

    final double averageLength = lengths.isEmpty
        ? 0.0
        : lengths.reduce((int a, int b) => a + b) / lengths.length;
    final int totalPassages = passages.length;

    // Score each passage, keeping only those the query positively overlaps.
    final List<RetrievedPassage> scored = <RetrievedPassage>[];
    for (int i = 0; i < passages.length; i++) {
      final double score = _bm25Score(
        queryTerms: queryTerms,
        termFrequencies: termFrequencies[i],
        passageLength: lengths[i],
        averageLength: averageLength,
        documentFrequencies: documentFrequencies,
        totalPassages: totalPassages,
      );
      if (score > 0.0) {
        scored.add(passages[i].toRetrieved(score));
      }
    }

    // Highest relevance first; take the top-k. A stable-enough ordering: ties
    // keep their index order because [List.sort] compares on score alone.
    scored.sort((RetrievedPassage a, RetrievedPassage b) =>
        b.score.compareTo(a.score));
    if (scored.length > _topK) {
      return List<RetrievedPassage>.unmodifiable(scored.sublist(0, _topK));
    }
    return List<RetrievedPassage>.unmodifiable(scored);
  }

  /// Computes the BM25-lite relevance of one passage to the [queryTerms].
  ///
  /// For each query term present in the passage, the term's contribution is its
  /// inverse document frequency (rarer terms across the index weigh more) times
  /// a saturating term-frequency factor normalized by the passage length
  /// relative to the corpus average ([_bm25K1], [_bm25B]). Terms absent from the
  /// passage contribute nothing, so a passage sharing no query term scores `0`.
  double _bm25Score({
    required List<String> queryTerms,
    required Map<String, int> termFrequencies,
    required int passageLength,
    required double averageLength,
    required Map<String, int> documentFrequencies,
    required int totalPassages,
  }) {
    if (passageLength == 0 || averageLength == 0.0) return 0.0;

    double score = 0.0;
    // Deduplicate query terms so repeating a word in the query does not
    // multiply its weight beyond its BM25 term-frequency contribution.
    for (final String term in queryTerms.toSet()) {
      final int termFrequency = termFrequencies[term] ?? 0;
      if (termFrequency == 0) continue;

      final int documentFrequency = documentFrequencies[term] ?? 0;
      final double idf = _idf(documentFrequency, totalPassages);
      if (idf <= 0.0) continue;

      final double numerator = termFrequency * (_bm25K1 + 1);
      final double denominator = termFrequency +
          _bm25K1 * (1 - _bm25B + _bm25B * (passageLength / averageLength));
      score += idf * (numerator / denominator);
    }
    return score;
  }

  /// The BM25 inverse-document-frequency weight for a term appearing in
  /// [documentFrequency] of [totalPassages] passages. Rarer terms score higher;
  /// the `+ 1` inside the log keeps the weight positive even for a term that
  /// appears in every passage, so ubiquitous words simply add little.
  double _idf(int documentFrequency, int totalPassages) {
    return math.log(
      1 + (totalPassages - documentFrequency + 0.5) / (documentFrequency + 0.5),
    );
  }

  /// Splits [text] into lowercase word tokens: lowercased, broken on any
  /// non-alphanumeric run, with empties, tokens shorter than [_minTokenLength],
  /// and [_stopwords] dropped. Shared by the query and every passage so the two
  /// token streams are directly comparable.
  List<String> _tokenize(String text) {
    if (text.isEmpty) return const <String>[];
    final List<String> tokens = <String>[];
    for (final String raw in text.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
      if (raw.length < _minTokenLength) continue;
      if (_stopwords.contains(raw)) continue;
      tokens.add(raw);
    }
    return tokens;
  }

  /// Whether the Active_Project has any searchable material at all — i.e. the
  /// in-memory index holds at least one passage drawn from a document or
  /// character (Req 5.5).
  ///
  /// Ensures the index is built first, then reports whether it is non-empty, so
  /// a caller seeing an empty [retrieve] result can tell an *empty project*
  /// (nothing indexed) apart from a *no-match query* (material exists but none
  /// overlapped the query) and report "no project material to search" only for
  /// the former. Runs fully offline over the Active_Project only (Req 5.3, 5.6).
  @override
  Future<bool> hasProjectMaterial() async {
    await _ensureIndexed();
    return (_passages ?? const <_Passage>[]).isNotEmpty;
  }

  /// Rebuilds the in-memory passage index from the Active_Project's current
  /// documents and characters, so subsequent searches reflect edits and
  /// additions (Req 5.7). Safe to call at any time; it fully replaces the
  /// previous index.
  Future<void> refresh() async {
    _passages = await _buildIndex();
  }

  /// Builds the index once if it has not been built yet. Repeated calls after
  /// the first are no-ops until [refresh] invalidates the index.
  Future<void> _ensureIndexed() async {
    if (_passages != null) return;
    _passages = await _buildIndex();
  }

  /// Reads the Active_Project's documents and characters through the existing
  /// repositories and flattens them into a single list of [_Passage]s.
  ///
  /// Both repositories are queried with [projectId], so the resulting index
  /// contains only this project's material (Req 5.1, 5.6) and the read never
  /// leaves the device (Req 5.3).
  Future<List<_Passage>> _buildIndex() async {
    final List<Document> documents = await _documents.getByProject(projectId);
    final List<Character> characters =
        await _characters.getAllForProject(projectId);

    final List<_Passage> passages = <_Passage>[];
    for (final Document document in documents) {
      passages.addAll(_passagesForDocument(document));
    }
    for (final Character character in characters) {
      final _Passage? passage = _passageForCharacter(character);
      if (passage != null) passages.add(passage);
    }
    return List<_Passage>.unmodifiable(passages);
  }

  /// Splits [document] into passages: the title contributes context and the
  /// Markdown content is chunked on blank-line (paragraph/heading) boundaries,
  /// with over-long chunks further split to stay within [_maxPassageChars].
  ///
  /// Passages carry the document's title as their source hint (Req 5.4), falling
  /// back to an "Untitled" label so an empty-titled document is still locatable.
  Iterable<_Passage> _passagesForDocument(Document document) {
    final String title = document.title.trim();
    final String sourceTitle = title.isEmpty ? 'Untitled document' : title;

    final List<_Passage> passages = <_Passage>[];
    for (final String chunk in _chunk(document.content)) {
      passages.add(_Passage(
        text: chunk,
        sourceId: document.id,
        sourceTitle: sourceTitle,
      ));
    }
    return passages;
  }

  /// Builds a single compact passage from [character]'s name, role, and notes,
  /// or `null` when the character has no searchable text at all.
  ///
  /// The passage text combines the fields into a labeled block so the ranker can
  /// match against any of them, and the source hint is the character's display
  /// name (Req 5.1, 5.4).
  _Passage? _passageForCharacter(Character character) {
    final String name = character.name.trim();
    final String role = character.role.trim();
    final String notes = character.notes.trim();

    final List<String> parts = <String>[
      if (name.isNotEmpty) 'Name: $name',
      if (role.isNotEmpty) 'Role: $role',
      if (notes.isNotEmpty) 'Notes: $notes',
    ];
    if (parts.isEmpty) return null;

    return _Passage(
      text: parts.join('\n'),
      sourceId: character.id,
      sourceTitle: character.displayName,
    );
  }

  /// Splits [content] into passage-sized text chunks on blank-line boundaries
  /// (paragraphs and Markdown headings), then hard-splits any paragraph longer
  /// than [_maxPassageChars] so no single passage is unwieldy. Blank/whitespace
  /// content yields no chunks.
  Iterable<String> _chunk(String content) {
    final List<String> chunks = <String>[];
    for (final String paragraph in content.split(RegExp(r'\n\s*\n'))) {
      final String trimmed = paragraph.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.length <= _maxPassageChars) {
        chunks.add(trimmed);
      } else {
        chunks.addAll(_hardSplit(trimmed));
      }
    }
    return chunks;
  }

  /// Splits an over-long [text] into contiguous slices of at most
  /// [_maxPassageChars] characters. A last resort for a single huge paragraph
  /// with no blank-line boundaries to chunk on.
  Iterable<String> _hardSplit(String text) sync* {
    for (int start = 0; start < text.length; start += _maxPassageChars) {
      final int end = (start + _maxPassageChars) < text.length
          ? start + _maxPassageChars
          : text.length;
      yield text.substring(start, end).trim();
    }
  }
}
