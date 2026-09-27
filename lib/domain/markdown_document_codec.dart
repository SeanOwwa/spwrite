/// Domain layer: [MarkdownDocumentCodec], the single testable seam that
/// isolates Quill Delta <-> Markdown conversion.
///
/// The WYSIWYG editor operates on a Quill [Delta], but documents are persisted
/// as a portable Markdown source string. This codec is a thin wrapper over the
/// `markdown_quill` package's converters so the editor and the state layer
/// depend on one place for both directions of the conversion.
library;

import 'package:flutter_quill/quill_delta.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:markdown_quill/markdown_quill.dart';

/// Converts between the editor's Quill [Delta] representation and the Markdown
/// source string that is persisted as a Document's Content.
///
/// The codec is deliberately restricted to the supported formatting feature
/// set — bold, italic, headings, ordered lists, unordered lists, and links.
/// The restricted editor toolbar only ever produces these constructs, so the
/// codec never needs to strip anything: whatever the toolbar emits maps
/// one-to-one onto the Markdown the codec produces (and vice versa).
///
/// The underlying `markdown_quill` converters are stateless with respect to a
/// single conversion call, so they are constructed once and reused as fields.
class MarkdownDocumentCodec {
  /// Creates a codec with reusable converters.
  ///
  /// The [MarkdownToDelta] converter requires a `markdown` [md.Document] that
  /// defines how the Markdown source is parsed. GitHub Flavored Markdown covers
  /// the supported feature set (headings, emphasis, ordered/unordered lists,
  /// links); `encodeHtml: false` keeps raw text intact rather than
  /// HTML-escaping it, since the output feeds the editor rather than a browser.
  MarkdownDocumentCodec()
      : _deltaToMarkdown = DeltaToMarkdown(),
        _markdownToDelta = MarkdownToDelta(
          markdownDocument: md.Document(
            encodeHtml: false,
            extensionSet: md.ExtensionSet.gitHubFlavored,
          ),
        );

  final DeltaToMarkdown _deltaToMarkdown;
  final MarkdownToDelta _markdownToDelta;

  /// Converts a Quill [Delta] to its Markdown source string.
  ///
  /// Used on save to compute the persisted Content (Req 15.1) and to measure
  /// the prospective source length before applying an edit (Req 15.3, 15.4).
  /// Restricted to the supported feature set (bold, italic, headings,
  /// ordered/unordered lists, links) — the only constructs the toolbar emits.
  String deltaToMarkdown(Delta delta) => _deltaToMarkdown.convert(delta);

  /// Converts a Markdown source string back into a Quill [Delta].
  ///
  /// Used on load to render stored Markdown into the editor (Req 15.2).
  /// Restricted to the supported feature set (bold, italic, headings,
  /// ordered/unordered lists, links).
  Delta markdownToDelta(String markdown) => _markdownToDelta.convert(markdown);
}
