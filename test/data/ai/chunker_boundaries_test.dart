// Unit tests for chunking boundaries in DocumentChunker (ai_feature_3.6 task
// 3.3).
//
// Feature: ai_feature_3.6 — On-device semantic retrieval (RAG).
// Validates: Requirements 4.1, 4.8
//
// The property test (task 3.2) pins the hashing facet across many inputs; these
// example-based unit tests pin the concrete boundary behaviors of the chunker's
// slicing so a regression in the windowing math is caught with a readable,
// hand-computed expectation. Each group targets one boundary rule from the
// implementation (lib/data/ai/chunker.dart) and the design's "Chunking model":
//
//   1. Documents split on paragraph/heading boundaries (blank lines), not
//      mid-paragraph, and pack greedily up to ~maxChunkChars (Req 4.1).
//   2. A standalone title chunk is index 0 when the title is non-blank, and is
//      absent when the title is blank (design §"Chunking model").
//   3. Adjacent content chunks share an ~overlapRatio (15%) overlap window so a
//      boundary-spanning fact stays retrievable (Req 4.1).
//   4. A single paragraph longer than maxChunkChars (no blank line to break on)
//      is hard-split into bounded slices (Req 4.8).
//   5. An empty/blank title with blank content yields no chunks.
//   6. A near-maxContentLength document still chunks without error (Req 4.1).
//   7. Characters produce one compact Name/Role/Notes chunk; an empty character
//      yields no chunks; over-long notes are hard-split (Req 4.8).
//
// Conventions follow the repo's example-based unit tests (see
// vector_codec_ranking_test.dart): flutter_test, `group`/`test`, and
// hand-computed expectations narrated inline.

import 'package:flutter_test/flutter_test.dart';

import 'package:spwrite/data/ai/chunker.dart';
import 'package:spwrite/domain/character.dart';
import 'package:spwrite/domain/document.dart';

/// A fixed epoch so constructed value objects are deterministic; the chunker
/// ignores timestamps, so any stable instant works.
final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// Builds a [Document] with the given [title]/[content]; other fields are fixed
/// because the chunker only reads id, title, and content.
Document _doc({
  String id = 'doc-1',
  required String title,
  required String content,
}) {
  return Document(
    id: id,
    title: title,
    content: content,
    projectId: 'project-1',
    folderId: null,
    createdAt: _epoch,
    modifiedAt: _epoch,
  );
}

/// Builds a [Character] with the given fields; the chunker only reads id, name,
/// role, and notes.
Character _character({
  String id = 'char-1',
  String name = '',
  String role = '',
  String notes = '',
}) {
  return Character(
    id: id,
    projectId: 'project-1',
    name: name,
    role: role,
    notes: notes,
    image: null,
    createdAt: _epoch,
    modifiedAt: _epoch,
  );
}

/// A paragraph of exactly [length] identical characters, so packing math is
/// exact and predictable.
String _para(String ch, int length) => ch * length;

void main() {
  const DocumentChunker chunker = DocumentChunker();
  const int maxChars = DocumentChunker.maxChunkChars; // 800

  group('title chunk (Req 4.1, design §"Chunking model")', () {
    test('a non-blank title becomes the standalone chunk at index 0', () {
      final Document document = _doc(title: 'The Great Journey', content: '');

      final List<SourceChunk> chunks = chunker.chunkDocument(document);

      expect(chunks, hasLength(1));
      expect(chunks.first.chunkIndex, 0);
      expect(chunks.first.text, 'The Great Journey');
      expect(chunks.first.sourceType, ChunkSourceType.document);
      expect(chunks.first.sourceTitle, 'The Great Journey');
    });

    test('the title chunk precedes the body chunks in index order', () {
      final Document document = _doc(
        title: 'Chapter One',
        content: 'A short opening paragraph of body text.',
      );

      final List<SourceChunk> chunks = chunker.chunkDocument(document);

      expect(chunks, hasLength(2));
      // Index 0 is the title; index 1 is the single body chunk.
      expect(chunks[0].chunkIndex, 0);
      expect(chunks[0].text, 'Chapter One');
      expect(chunks[1].chunkIndex, 1);
      expect(chunks[1].text, 'A short opening paragraph of body text.');
    });

    test('a blank title contributes no title chunk (body only)', () {
      final Document document = _doc(
        title: '   ',
        content: 'Body without a real title.',
      );

      final List<SourceChunk> chunks = chunker.chunkDocument(document);

      // Only the body chunk; the whitespace title is not emitted.
      expect(chunks, hasLength(1));
      expect(chunks.first.chunkIndex, 0);
      expect(chunks.first.text, 'Body without a real title.');
      // The source label falls back to the untitled placeholder for citation.
      expect(chunks.first.sourceTitle, 'Untitled document');
    });
  });

  group('paragraph/heading boundary splitting (Req 4.1)', () {
    test('paragraphs separated by a blank line pack into one chunk when small',
        () {
      // Two short paragraphs well under the 800-char budget stay together,
      // joined by the paragraph separator.
      final Document document = _doc(
        title: '',
        content: 'First paragraph.\n\nSecond paragraph.',
      );

      final List<SourceChunk> chunks = chunker.chunkDocument(document);

      expect(chunks, hasLength(1));
      expect(chunks.first.text, 'First paragraph.\n\nSecond paragraph.');
    });

    test('a Markdown heading + body split on the blank line between them', () {
      final Document document = _doc(
        title: '',
        content: '# Heading\n\nThe body under the heading.',
      );

      final List<SourceChunk> chunks = chunker.chunkDocument(document);

      // They fit within one chunk together but the blank line is the boundary
      // that would separate them if the budget were exceeded; here they pack.
      expect(chunks, hasLength(1));
      expect(chunks.first.text, '# Heading\n\nThe body under the heading.');
    });

    test('paragraphs are split on the boundary when the budget is exceeded',
        () {
      // Two ~500-char paragraphs (1000 + separator > 800) cannot share a chunk,
      // so the boundary between them starts a new chunk rather than cutting a
      // paragraph in the middle.
      final String p1 = _para('a', 500);
      final String p2 = _para('b', 500);
      final Document document = _doc(title: '', content: '$p1\n\n$p2');

      final List<SourceChunk> chunks = chunker.chunkDocument(document);

      // Two chunks: the second is seeded with an overlap window from the first.
      expect(chunks.length, 2);
      // First chunk is exactly the first paragraph (no mid-paragraph cut).
      expect(chunks[0].text, p1);
      // Second chunk ends with the whole of the second paragraph intact.
      expect(chunks[1].text.endsWith(p2), isTrue);
      // No chunk grossly exceeds the budget beyond one paragraph + overlap.
      for (final SourceChunk chunk in chunks) {
        expect(chunk.text.length, lessThanOrEqualTo(maxChars + 200));
      }
    });
  });

  group('overlap window between adjacent chunks (Req 4.1)', () {
    test('the next chunk is seeded with the tail of the previous one', () {
      // Distinguishable paragraphs so the overlap is observable: the first is
      // all "a", the second all "b". The second chunk should begin with a run
      // of "a" (the ~120-char overlap tail carried from chunk 0).
      final String p1 = _para('a', 700);
      final String p2 = _para('b', 700);
      final Document document = _doc(title: '', content: '$p1\n\n$p2');

      final List<SourceChunk> chunks = chunker.chunkDocument(document);

      expect(chunks.length, greaterThanOrEqualTo(2));
      // ~15% of 800 = 120 overlap characters seed the front of chunk 1.
      const int overlap = 120;
      expect(chunks[1].text.startsWith('a' * overlap), isTrue,
          reason: 'The next chunk must carry the trailing overlap window of '
              'the previous chunk so a boundary-spanning fact stays '
              'retrievable (Req 4.1).');
      // The overlap ratio constant matches the derived character count.
      expect(
        (DocumentChunker.maxChunkChars * DocumentChunker.overlapRatio).round(),
        overlap,
      );
    });
  });

  group('hard-split of an over-long paragraph (Req 4.8)', () {
    test('a single paragraph longer than maxChunkChars is split into slices',
        () {
      // One 2000-char paragraph with no blank line to break on must be
      // hard-split into contiguous <=800-char slices.
      final String huge = _para('x', 2000);
      final Document document = _doc(title: '', content: huge);

      final List<SourceChunk> chunks = chunker.chunkDocument(document);

      expect(chunks.length, greaterThanOrEqualTo(3),
          reason: '2000 chars / 800 -> at least 3 slices.');
      for (final SourceChunk chunk in chunks) {
        expect(chunk.text.length, lessThanOrEqualTo(maxChars),
            reason: 'No hard-split slice may exceed the chunk budget.');
      }
      // Chunk indices are sequential from 0.
      for (int i = 0; i < chunks.length; i++) {
        expect(chunks[i].chunkIndex, i);
      }
      // The slices, concatenated, reconstruct the original paragraph (no data
      // lost across the hard split of a single-character paragraph).
      final String rejoined = chunks.map((SourceChunk c) => c.text).join();
      expect(rejoined, huge);
    });
  });

  group('empty / blank input yields no chunks', () {
    test('an empty title and blank content produce zero chunks', () {
      final Document document = _doc(title: '', content: '   \n\n  \t ');

      final List<SourceChunk> chunks = chunker.chunkDocument(document);

      expect(chunks, isEmpty);
    });
  });

  group('near-maxContentLength document still chunks (Req 4.1)', () {
    test('a large multi-paragraph document chunks without error', () {
      // Build a document from many blank-line-separated paragraphs totalling a
      // large body; the chunker must produce bounded, sequentially-indexed
      // chunks and never emit an over-budget chunk (beyond one paragraph +
      // overlap seed).
      final StringBuffer body = StringBuffer();
      for (int i = 0; i < 200; i++) {
        body.write(_para('p', 300));
        body.write('\n\n');
      }
      final Document document =
          _doc(title: 'Big Document', content: body.toString());

      final List<SourceChunk> chunks = chunker.chunkDocument(document);

      expect(chunks.length, greaterThan(1));
      // Title chunk first.
      expect(chunks.first.chunkIndex, 0);
      expect(chunks.first.text, 'Big Document');
      // Sequential indices with no gaps.
      for (int i = 0; i < chunks.length; i++) {
        expect(chunks[i].chunkIndex, i);
      }
      // Each chunk stays within a paragraph + overlap of the budget.
      for (final SourceChunk chunk in chunks) {
        expect(chunk.text.length, lessThanOrEqualTo(maxChars + 200));
      }
    });
  });

  group('character chunking (Req 4.8)', () {
    test('name, role, and notes combine into one labeled chunk', () {
      final Character character = _character(
        name: 'Ada',
        role: 'Protagonist',
        notes: 'A brilliant engineer.',
      );

      final List<SourceChunk> chunks = chunker.chunkCharacter(character);

      expect(chunks, hasLength(1));
      final SourceChunk chunk = chunks.first;
      expect(chunk.sourceType, ChunkSourceType.character);
      expect(chunk.chunkIndex, 0);
      expect(chunk.sourceTitle, 'Ada');
      expect(
        chunk.text,
        'Name: Ada\nRole: Protagonist\nNotes: A brilliant engineer.',
      );
    });

    test('only the populated fields appear in the combined chunk', () {
      final Character character = _character(name: 'Ada', role: '', notes: '');

      final List<SourceChunk> chunks = chunker.chunkCharacter(character);

      expect(chunks, hasLength(1));
      expect(chunks.first.text, 'Name: Ada');
    });

    test('an empty character (no name/role/notes) yields no chunks', () {
      final Character character = _character();

      final List<SourceChunk> chunks = chunker.chunkCharacter(character);

      expect(chunks, isEmpty);
    });

    test('over-long notes are hard-split into multiple ordered chunks', () {
      // Notes alone exceeding the 800-char budget forces a hard split of the
      // combined block into bounded, sequentially-indexed chunks.
      final Character character = _character(
        name: 'Ada',
        notes: _para('n', 2000),
      );

      final List<SourceChunk> chunks = chunker.chunkCharacter(character);

      expect(chunks.length, greaterThanOrEqualTo(3));
      for (int i = 0; i < chunks.length; i++) {
        expect(chunks[i].chunkIndex, i);
        expect(chunks[i].text.length, lessThanOrEqualTo(maxChars));
        expect(chunks[i].sourceTitle, 'Ada');
      }
    });
  });
}
