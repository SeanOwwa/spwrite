// Property test for incremental-safe chunk hashing (ai_feature_3.6 task 3.2).
//
// Feature: ai_feature_3.6 — On-device semantic retrieval (RAG).
// Property 8 (hashing facet): identical chunk text yields an identical
// contentHash; any single-character change yields a different hash. Chunk ids
// are stable for the same (sourceId, chunkIndex). This is the invariant the
// incremental reindex diff relies on: unchanged chunks hash identically and are
// never re-embedded, while a changed chunk hashes differently and is re-embedded
// (design §"Chunking model", §Testing Strategy — Content hashing).
//
// **Validates: Requirements 4.2**
//
// Strategy: exercise DocumentChunker's pure, static hashing surface directly —
// `contentHashOf(text)` (the per-chunk content hash over chunk text) and
// `chunkId(sourceId, chunkIndex)` (the stable id derived from source + position).
// Working at the static surface keeps the property focused on the hashing facet
// itself rather than the chunking that feeds it.
//
// Text is generated from a list of single characters drawn from a small, varied
// pool (ASCII letters/digits, whitespace including chunk-boundary blank lines,
// Markdown punctuation, and a couple of multi-byte unicode code points) so
// single-character edits land on realistic chunk content. Following the repo's
// kiri_check convention (see hierarchy_roundtrip_property_test.dart), each
// property uses `property(...) { forAll(...) }` with a bounded `maxExamples` and
// `combineN(...).map(...)` records for multi-argument generators.
//
// Properties asserted:
//   1. Determinism: hashing the same text twice yields the same hash.
//   2a. Substitution: replacing one character with a different one changes the
//       hash.
//   2b. Insertion: inserting one character changes the hash.
//   2c. Deletion: removing one character changes the hash.
//   3. Id stability: chunkId is deterministic for a given (sourceId, chunkIndex),
//      and distinct positions or sources yield distinct ids.

import 'package:kiri_check/kiri_check.dart';
import 'package:test/test.dart';

import 'package:spwrite/data/ai/chunker.dart';

/// A generated single-character edit against a base text: the base characters,
/// an edit position, and an index selecting a replacement/insertion character.
typedef EditSpec = ({List<String> chars, int posSelector, int charSelector});

/// A generated chunk id case: two source ids and two chunk indices, used to
/// assert determinism and distinctness of [DocumentChunker.chunkId].
typedef IdSpec = ({int sourceSelector, int otherSourceSelector, int index, int otherIndex});

void main() {
  // A varied character pool so generated text and single-character edits cover
  // letters, digits, whitespace (including the blank-line chunk boundary),
  // Markdown punctuation, and multi-byte unicode.
  const List<String> alphabet = <String>[
    'a', 'b', 'c', 'd', 'e', 'X', 'Z',
    '0', '1', '9',
    ' ', '\n', '\t',
    '#', '-', '*', '.', ':',
    'é', // a multi-byte code point.
    '你',
  ];

  // A small pool of source ids (UUID-ish and varied) for the id-stability
  // property; includes near-duplicates so the (sourceId, chunkIndex) separator
  // is exercised.
  const List<String> sourceIds = <String>[
    'doc-1',
    'doc-2',
    'doc-10',
    '11111111-1111-4111-8111-111111111111',
    'char-1',
    '',
  ];

  // A single character drawn from the alphabet, as a one-element string.
  Arbitrary<int> charIdx() => integer(min: 0, max: alphabet.length - 1);

  // Base chunk text: 1..400 characters. minLength 1 keeps every text non-empty
  // so a single-character change is always well-defined.
  Arbitrary<List<String>> chars() =>
      list(charIdx().map((int i) => alphabet[i]), minLength: 1, maxLength: 400);

  Arbitrary<EditSpec> editSpec() => combine3(
        chars(),
        // Position selector, reduced modulo the text length at build time.
        integer(min: 0, max: 4095),
        charIdx(),
      ).map(
        (r) => (chars: r.$1, posSelector: r.$2, charSelector: r.$3),
      );

  Arbitrary<IdSpec> idSpec() => combine4(
        integer(min: 0, max: sourceIds.length - 1),
        integer(min: 0, max: sourceIds.length - 1),
        integer(min: 0, max: 5000),
        integer(min: 0, max: 5000),
      ).map(
        (r) => (
          sourceSelector: r.$1,
          otherSourceSelector: r.$2,
          index: r.$3,
          otherIndex: r.$4,
        ),
      );

  // ---------------------------------------------------------------------------
  // Property 1: identical text hashes identically (determinism).
  // ---------------------------------------------------------------------------
  property('identical chunk text yields an identical contentHash', () {
    forAll(chars(), (List<String> chs) {
      final String text = chs.join();
      expect(
        DocumentChunker.contentHashOf(text),
        DocumentChunker.contentHashOf(text),
        reason: 'Hashing the same text twice must yield the same hash so '
            'unchanged chunks are never re-embedded (Req 4.2).',
      );
    }, maxExamples: 200);
  });

  // ---------------------------------------------------------------------------
  // Property 2a: a single-character SUBSTITUTION yields a different hash.
  //
  // Pick a position; replace the character there with a different one (advance
  // through the alphabet until it differs) so the edit is a genuine change.
  // ---------------------------------------------------------------------------
  property('a single-character substitution yields a different hash', () {
    forAll(editSpec(), (EditSpec spec) {
      final List<String> original = List<String>.of(spec.chars);
      final int pos = spec.posSelector % original.length;

      // Choose a replacement that differs from the character currently at pos.
      String replacement = alphabet[spec.charSelector];
      int probe = spec.charSelector;
      while (replacement == original[pos]) {
        probe = (probe + 1) % alphabet.length;
        replacement = alphabet[probe];
      }

      final List<String> mutated = List<String>.of(original)..[pos] = replacement;

      expect(
        DocumentChunker.contentHashOf(mutated.join()),
        isNot(equals(DocumentChunker.contentHashOf(original.join()))),
        reason: 'Substituting one character must change the content hash so a '
            'changed chunk is re-embedded (Req 4.2).',
      );
    }, maxExamples: 200);
  });

  // ---------------------------------------------------------------------------
  // Property 2b: a single-character INSERTION yields a different hash.
  // ---------------------------------------------------------------------------
  property('a single-character insertion yields a different hash', () {
    forAll(editSpec(), (EditSpec spec) {
      final List<String> original = List<String>.of(spec.chars);
      // Insertion index in [0, length]; a length longer by one is inherently a
      // change regardless of which character is inserted.
      final int pos = spec.posSelector % (original.length + 1);
      final String inserted = alphabet[spec.charSelector];

      final List<String> mutated = List<String>.of(original)..insert(pos, inserted);

      expect(
        DocumentChunker.contentHashOf(mutated.join()),
        isNot(equals(DocumentChunker.contentHashOf(original.join()))),
        reason: 'Inserting one character must change the content hash (Req 4.2).',
      );
    }, maxExamples: 200);
  });

  // ---------------------------------------------------------------------------
  // Property 2c: a single-character DELETION yields a different hash.
  //
  // Only meaningful when there is more than one character, since deleting the
  // sole character of a length-1 text would leave the empty string (still a
  // different hash, but we guard to keep the mutation a clean single-char
  // deletion of a non-empty result).
  // ---------------------------------------------------------------------------
  property('a single-character deletion yields a different hash', () {
    forAll(editSpec(), (EditSpec spec) {
      final List<String> original = List<String>.of(spec.chars);
      final int pos = spec.posSelector % original.length;

      final List<String> mutated = List<String>.of(original)..removeAt(pos);

      expect(
        DocumentChunker.contentHashOf(mutated.join()),
        isNot(equals(DocumentChunker.contentHashOf(original.join()))),
        reason: 'Removing one character must change the content hash (Req 4.2).',
      );
    }, maxExamples: 200);
  });

  // ---------------------------------------------------------------------------
  // Property 3: chunk ids are stable for the same (sourceId, chunkIndex), and
  // distinct positions or sources yield distinct ids.
  // ---------------------------------------------------------------------------
  property('chunk ids are stable for the same (sourceId, chunkIndex)', () {
    forAll(idSpec(), (IdSpec spec) {
      final String sourceId = sourceIds[spec.sourceSelector];
      final String otherSource = sourceIds[spec.otherSourceSelector];
      final int index = spec.index;
      final int otherIndex = spec.otherIndex;

      // Deterministic: same (sourceId, chunkIndex) → same id, every time.
      expect(
        DocumentChunker.chunkId(sourceId, index),
        DocumentChunker.chunkId(sourceId, index),
        reason: 'chunkId must be deterministic so an incremental reindex '
            'updates a row in place rather than orphaning it (Req 4.2).',
      );

      // Different chunk index within the same source → different id.
      if (index != otherIndex) {
        expect(
          DocumentChunker.chunkId(sourceId, index),
          isNot(equals(DocumentChunker.chunkId(sourceId, otherIndex))),
          reason: 'Distinct chunk positions within a source must map to '
              'distinct ids.',
        );
      }

      // Different source, same index → different id.
      if (sourceId != otherSource) {
        expect(
          DocumentChunker.chunkId(sourceId, index),
          isNot(equals(DocumentChunker.chunkId(otherSource, index))),
          reason: 'Distinct sources must map to distinct chunk ids at the same '
              'position.',
        );
      }
    }, maxExamples: 200);
  });
}
