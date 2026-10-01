/// Data layer: the pure, deterministic [DocumentChunker] that slices the
/// Active_Project's documents and characters into bounded, overlap-aware
/// [SourceChunk]s ready to be embedded into the local vector index (design
/// §"Chunking model", Req 4.1, 4.8).
///
/// Chunking is the granularity at which the semantic path stores and retrieves
/// meaning: a long document is split into ~800-char paragraph/heading-aware
/// windows so a query can surface just the relevant passage rather than the
/// whole file, adjacent windows share a small (~15%) overlap so a fact spanning
/// a boundary is still retrievable, and an over-long paragraph with no blank
/// line to break on is hard-split so no single chunk is unwieldy. The document
/// title contributes a small standalone chunk for locatability, and a character
/// contributes one compact chunk built from its name, role, and notes —
/// mirroring the 3.5 [KeywordContextRetriever] chunking intent so the semantic
/// and keyword paths cover the same material.
///
/// Each emitted chunk carries the metadata the vector index needs downstream: a
/// stable [SourceChunk.id] derived from `(sourceId, chunkIndex)`, its
/// zero-based [SourceChunk.chunkIndex] (the deterministic tie-break key for
/// retrieval, Req 1.6), its source identity for citation (Req 1.4), and a
/// per-chunk [SourceChunk.contentHash] over the chunk text. The content hash is
/// what makes incremental reindex cheap (Req 4.2): identical chunk text yields
/// an identical hash and a single character change yields a different one, so
/// the indexer can diff current chunks against stored hashes and re-embed only
/// what actually changed.
///
/// This class is intentionally pure: it performs no I/O, touches no database or
/// embedding runtime, and depends only on the domain [Document]/[Character]
/// value objects, so it can be unit- and property-tested in isolation and lands
/// before the repository and indexer that consume it.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/character.dart';
import '../../domain/document.dart';

/// The kind of Active_Project material a [SourceChunk] was cut from, mirroring
/// the `source_type` column of the `ai_chunk_embeddings` table
/// ('document' | 'character').
enum ChunkSourceType {
  /// A chunk cut from a [Document] (its title or a slice of its content).
  document,

  /// The single compact chunk built from a [Character]'s name, role, and notes.
  character;

  /// The stored string form persisted in the vector index's `source_type`
  /// column.
  String get storageValue => name;
}

/// A single bounded, embeddable slice of Active_Project material together with
/// the metadata the local vector index needs to store, cite, scope, and
/// incrementally reindex it (design §"Chunking model").
///
/// A chunk is the unit at which the semantic path embeds and retrieves content.
/// Its [text] is the passage handed to the embedding model; [sourceId] and
/// [sourceTitle] identify the document/character it came from (for scoping and
/// citation, Req 1.4, 1.5); [chunkIndex] is its zero-based order within the
/// source and the deterministic retrieval tie-break key (Req 1.6); [id] is a
/// stable identifier derived from `(sourceId, chunkIndex)`; and [contentHash]
/// is a hash of [text] used to detect whether this chunk changed since it was
/// last indexed (Req 4.2).
class SourceChunk {
  /// Stable identifier for this chunk, derived from `(sourceId, chunkIndex)`.
  ///
  /// Because it depends only on the source and the chunk's position within it,
  /// re-chunking the same source produces the same ids for the same positions,
  /// so an incremental reindex updates a row in place rather than orphaning it.
  final String id;

  /// Identifier of the source document or character this chunk came from.
  final String sourceId;

  /// Whether this chunk came from a document or a character.
  final ChunkSourceType sourceType;

  /// Human-readable label for the source (document title or character display
  /// name), carried so a grounded answer can cite it (Req 1.4).
  final String sourceTitle;

  /// Zero-based order of this chunk within its source. Also the deterministic
  /// tie-break key when two chunks score equally at retrieval time (Req 1.6).
  final int chunkIndex;

  /// The passage text handed to the embedding model as the unit of meaning.
  final String text;

  /// A hash of [text] used to detect change for incremental reindex: identical
  /// text hashes identically, and any single-character change hashes
  /// differently, so unchanged chunks are never re-embedded (Req 4.2).
  final String contentHash;

  const SourceChunk({
    required this.id,
    required this.sourceId,
    required this.sourceType,
    required this.sourceTitle,
    required this.chunkIndex,
    required this.text,
    required this.contentHash,
  });

  @override
  String toString() {
    return 'SourceChunk(id: $id, sourceId: $sourceId, '
        'sourceType: ${sourceType.storageValue}, chunkIndex: $chunkIndex, '
        'text.length: ${text.length}, contentHash: $contentHash)';
  }
}

/// A pure, deterministic chunker that slices documents and characters into
/// bounded, overlap-aware [SourceChunk]s for the local vector index (Req 4.1,
/// 4.8).
///
/// The chunker performs no I/O; a caller reads sources through the existing
/// repositories and passes the value objects here. Chunking is deterministic:
/// the same source always yields the same chunks, ids, and content hashes, so
/// re-chunking is safe to diff for incremental reindex.
class DocumentChunker {
  /// Target character budget for a single document content chunk, matching the
  /// 3.5 keyword retriever's ~800-char passage size so the semantic and keyword
  /// paths cover the same granularity (design §"Chunking model").
  static const int maxChunkChars = 800;

  /// Fraction of a chunk carried over into the next as an overlap window (~15%),
  /// so a fact spanning a paragraph boundary is still retrievable from at least
  /// one chunk (design §"Chunking model").
  static const double overlapRatio = 0.15;

  /// The character budget reserved for the standalone title chunk. A title is
  /// short by construction; this only guards a pathologically long title.
  static const int _maxTitleChars = 200;

  /// Number of overlap characters carried between adjacent content chunks,
  /// derived from [maxChunkChars] and [overlapRatio] (e.g. 800 × 0.15 = 120).
  static const int _overlapChars = 120;

  const DocumentChunker();

  /// Chunks [document] into an ordered list of [SourceChunk]s: a small
  /// standalone title chunk (when the title is non-blank) followed by
  /// paragraph/heading-aware content chunks (~[maxChunkChars] each, with an
  /// ~[overlapRatio] overlap window, over-long paragraphs hard-split).
  ///
  /// Chunk indices are assigned sequentially from `0` in emission order, so the
  /// title chunk (when present) is index `0` and the body chunks follow. A
  /// document with an empty title and blank content yields no chunks.
  List<SourceChunk> chunkDocument(Document document) {
    final String rawTitle = document.title.trim();
    final String sourceTitle =
        rawTitle.isEmpty ? 'Untitled document' : rawTitle;

    final List<String> texts = <String>[];

    // A small title chunk for locatability (design §"Chunking model"). Kept
    // only when the title carries real text, so an untitled document does not
    // contribute an empty placeholder chunk.
    if (rawTitle.isNotEmpty) {
      texts.add(_truncate(rawTitle, _maxTitleChars));
    }

    texts.addAll(_chunkContent(document.content));

    return _assemble(
      sourceId: document.id,
      sourceType: ChunkSourceType.document,
      sourceTitle: sourceTitle,
      texts: texts,
    );
  }

  /// Builds the single compact chunk for [character] from its name, role, and
  /// notes, or an empty list when the character has no searchable text at all.
  ///
  /// The chunk text combines the populated fields into a labeled block (matching
  /// the 3.5 `_passageForCharacter` shape) so the embedding captures any of
  /// them, and the source label is the character's display name for citation
  /// (Req 1.4). A character whose notes alone exceed [maxChunkChars] is
  /// hard-split into multiple ordered chunks so no chunk is unwieldy (Req 4.8).
  List<SourceChunk> chunkCharacter(Character character) {
    final String name = character.name.trim();
    final String role = character.role.trim();
    final String notes = character.notes.trim();

    final List<String> parts = <String>[
      if (name.isNotEmpty) 'Name: $name',
      if (role.isNotEmpty) 'Role: $role',
      if (notes.isNotEmpty) 'Notes: $notes',
    ];
    if (parts.isEmpty) return const <SourceChunk>[];

    final String combined = parts.join('\n');
    final List<String> texts = combined.length <= maxChunkChars
        ? <String>[combined]
        : _hardSplit(combined);

    return _assemble(
      sourceId: character.id,
      sourceType: ChunkSourceType.character,
      sourceTitle: character.displayName,
      texts: texts,
    );
  }

  /// Splits [content] into ~[maxChunkChars] paragraph/heading-aware chunks with
  /// an ~[overlapRatio] overlap window between adjacent chunks.
  ///
  /// Content is first broken on blank lines (paragraphs and Markdown headings);
  /// paragraphs are then packed greedily into chunks up to [maxChunkChars],
  /// carrying the trailing [_overlapChars] of the previous chunk into the start
  /// of the next so a fact straddling a boundary stays retrievable. A single
  /// paragraph longer than [maxChunkChars] (no blank line to break on) is
  /// hard-split into contiguous slices. Blank/whitespace content yields nothing.
  List<String> _chunkContent(String content) {
    final List<String> paragraphs = <String>[];
    for (final String paragraph in content.split(RegExp(r'\n\s*\n'))) {
      final String trimmed = paragraph.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.length <= maxChunkChars) {
        paragraphs.add(trimmed);
      } else {
        paragraphs.addAll(_hardSplit(trimmed));
      }
    }
    if (paragraphs.isEmpty) return const <String>[];

    final List<String> chunks = <String>[];
    final StringBuffer current = StringBuffer();

    void flush() {
      final String text = current.toString().trim();
      if (text.isNotEmpty) chunks.add(text);
      current.clear();
    }

    for (final String paragraph in paragraphs) {
      final int separator = current.isEmpty ? 0 : 2; // the '\n\n' join cost.
      final bool wouldOverflow =
          current.length + separator + paragraph.length > maxChunkChars;

      if (current.isNotEmpty && wouldOverflow) {
        final String finished = current.toString().trim();
        chunks.add(finished);
        current.clear();
        // Seed the next chunk with an overlap window from the tail of the one
        // just finished so boundary-spanning facts remain retrievable.
        final String overlap = _tail(finished, _overlapChars);
        if (overlap.isNotEmpty) current.write(overlap);
      }

      if (current.isNotEmpty) current.write('\n\n');
      current.write(paragraph);

      // A single paragraph can be up to maxChunkChars; combined with an overlap
      // seed it may momentarily exceed the budget. Emit immediately so no chunk
      // grossly exceeds the target.
      if (current.length >= maxChunkChars) {
        flush();
      }
    }
    flush();

    return chunks;
  }

  /// Turns ordered chunk [texts] for one source into [SourceChunk]s, assigning
  /// sequential [SourceChunk.chunkIndex]es from `0`, a stable id derived from
  /// `(sourceId, chunkIndex)`, and a per-chunk content hash over the text.
  List<SourceChunk> _assemble({
    required String sourceId,
    required ChunkSourceType sourceType,
    required String sourceTitle,
    required List<String> texts,
  }) {
    final List<SourceChunk> chunks = <SourceChunk>[];
    for (int index = 0; index < texts.length; index++) {
      final String text = texts[index];
      chunks.add(SourceChunk(
        id: chunkId(sourceId, index),
        sourceId: sourceId,
        sourceType: sourceType,
        sourceTitle: sourceTitle,
        chunkIndex: index,
        text: text,
        contentHash: contentHashOf(text),
      ));
    }
    return List<SourceChunk>.unmodifiable(chunks);
  }

  /// The stable id for the chunk at [chunkIndex] of [sourceId]: a SHA-256 over
  /// the pair, so the same source position always maps to the same row id and
  /// an incremental reindex updates in place rather than orphaning rows.
  static String chunkId(String sourceId, int chunkIndex) {
    final Digest digest =
        sha256.convert(utf8.encode('$sourceId\u0000$chunkIndex'));
    return digest.toString();
  }

  /// The per-chunk content hash: a SHA-256 hex digest over the chunk [text].
  ///
  /// Deterministic and collision-resistant enough for change detection:
  /// identical text hashes identically and any single-character change hashes
  /// differently, which is exactly what the incremental-reindex diff needs
  /// (Req 4.2).
  static String contentHashOf(String text) {
    return sha256.convert(utf8.encode(text)).toString();
  }

  /// Hard-splits an over-long [text] into contiguous slices of at most
  /// [maxChunkChars] characters — a last resort for a single huge paragraph (or
  /// character notes) with no blank-line boundary to chunk on (Req 4.8).
  List<String> _hardSplit(String text) {
    final List<String> slices = <String>[];
    for (int start = 0; start < text.length; start += maxChunkChars) {
      final int end = (start + maxChunkChars) < text.length
          ? start + maxChunkChars
          : text.length;
      final String slice = text.substring(start, end).trim();
      if (slice.isNotEmpty) slices.add(slice);
    }
    return slices;
  }

  /// Returns the trailing [count] characters of [text] (the whole string when it
  /// is shorter), used to seed the overlap window of the next chunk.
  String _tail(String text, int count) {
    if (text.length <= count) return text;
    return text.substring(text.length - count).trimLeft();
  }

  /// Returns [text] unchanged when within [limit], otherwise its first [limit]
  /// characters — used to bound a pathologically long title chunk.
  String _truncate(String text, int limit) {
    return text.length <= limit ? text : text.substring(0, limit).trim();
  }
}
