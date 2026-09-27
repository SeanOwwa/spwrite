// Property test for the Markdown round-trip (writing-app-v2 task 4.2).
//
// Feature: writing-app-v2, Property 12: For any editor document restricted to the supported formatting set (bold, italic, headings, ordered lists, unordered lists, links), converting it to the stored Markdown source and then loading that Markdown back into the editor yields formatting equivalent to what was stored; equivalently, re-serializing the loaded document to Markdown reproduces the same Markdown source (idempotence after the store step).
//
// **Validates: Requirements 15.1, 15.2, 15.5**
//
// Strategy (idempotence-after-store formulation): building random *valid*
// Quill Deltas by hand is error-prone, so instead we generate random Markdown
// *source* strings restricted to the supported feature set (bold, italic,
// headings, ordered/unordered lists, links) and drive them through the codec.
//
// The store step normalizes input Markdown, so the first pass may change the
// text (e.g. `-` list markers, spacing). We therefore do NOT assert the input
// survives unchanged. Instead we assert the codec is idempotent *after* the
// first store pass:
//
//   delta  = markdownToDelta(m0)      // load generated source
//   md1    = deltaToMarkdown(delta)   // the stored source
//   delta2 = markdownToDelta(md1)     // load the stored source
//   md2    = deltaToMarkdown(delta2)  // re-serialize
//   assert md2 == md1
//
// This is exactly "re-serializing the loaded document to Markdown reproduces
// the same Markdown source (idempotence after the store step)".
//
// Documents are assembled by joining 1..6 randomly chosen snippets — each
// snippet covering one supported construct — with blank lines ('\n\n').

import 'package:kiri_check/kiri_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spwrite/domain/markdown_document_codec.dart';

void main() {
  // Representative snippets covering each supported formatting construct.
  // Each is a self-contained block; blocks are joined with blank lines.
  const List<String> snippetPool = <String>[
    'plain paragraph text',
    'text with **bold** word',
    'text with *italic* word',
    'a [link](https://example.com)',
    '# Heading one',
    '## Heading two',
    '### Heading three',
    '- item a\n- item b',
    '1. first\n2. second',
  ];

  final MarkdownDocumentCodec codec = MarkdownDocumentCodec();

  // A generated document: 1..6 snippets joined with blank lines.
  Arbitrary<String> markdownSource() => list(
        constantFrom(snippetPool),
        minLength: 1,
        maxLength: 6,
      ).map((List<String> blocks) => blocks.join('\n\n'));

  property('Property 12: Markdown round-trip idempotence after store', () {
    forAll(
      markdownSource(),
      (String m0) {
        // Store step: load the generated source, then serialize it. This is the
        // canonical stored source `md1`.
        final delta = codec.markdownToDelta(m0);
        final String md1 = codec.deltaToMarkdown(delta);

        // Second round trip over the already-stored source.
        final delta2 = codec.markdownToDelta(md1);
        final String md2 = codec.deltaToMarkdown(delta2);

        // Idempotence after the store step: re-serializing the loaded document
        // reproduces the same Markdown source.
        expect(
          md2,
          equals(md1),
          reason: 'Codec not idempotent after store step.\n'
              'input m0:\n$m0\n---\nmd1 (stored):\n$md1\n---\nmd2:\n$md2',
        );
      },
      maxExamples: 100,
    );
  });
}
