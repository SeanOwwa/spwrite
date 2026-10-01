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
  String deltaToMarkdown(Delta delta) =>
      _deltaToMarkdown.convert(_protectWhitespace(delta));

  /// Converts a Markdown source string back into a Quill [Delta].
  ///
  /// Used on load to render stored Markdown into the editor (Req 15.2).
  /// Restricted to the supported feature set (bold, italic, headings,
  /// ordered/unordered lists, links).
  Delta markdownToDelta(String markdown) =>
      _restoreWhitespace(_markdownToDelta.convert(markdown));

  /// Placeholder for whitespace Markdown would otherwise discard. A no-break
  /// space is not "blank" to a Markdown parser, so a line holding one survives
  /// as its own paragraph, and leading ones do not trigger an indented code
  /// block.
  static const String _nbsp = '\u00A0';

  /// Before saving: empty plain lines (pressing Enter twice) become a line
  /// holding [_nbsp], and leading spaces on plain lines (the editor's Tab
  /// indent) become [_nbsp]s. Markdown would otherwise collapse blank lines and
  /// read a 4+ space indent as a code block, so the writer's spacing vanished
  /// after a save and reload.
  static Delta _protectWhitespace(Delta delta) {
    final Delta out = Delta();
    bool atLineStart = true;
    for (final Operation op in delta.toList()) {
      final Object? data = op.data;
      if (data is! String) {
        out.push(op);
        atLineStart = false;
        continue;
      }
      final Map<String, dynamic>? attrs = op.attributes;
      int i = 0;
      while (i < data.length) {
        final int nl = data.indexOf('\n', i);
        final String segment =
            nl < 0 ? data.substring(i) : data.substring(i, nl);
        if (segment.isNotEmpty) {
          String text = segment;
          if (atLineStart) {
            final int lead = text.length - text.trimLeft().length;
            final String leading = text.substring(0, lead);
            if (lead > 0 && leading.replaceAll(' ', '').isEmpty) {
              text = _nbsp * lead + text.substring(lead);
            }
          }
          out.insert(text, attrs);
          atLineStart = false;
        }
        if (nl < 0) break;
        // A newline closes the line; its attributes are the block style.
        final Map<String, dynamic>? lineAttrs = attrs;
        if (atLineStart && (lineAttrs == null || lineAttrs.isEmpty)) {
          out.insert(_nbsp);
        }
        out.insert('\n', lineAttrs);
        atLineStart = true;
        i = nl + 1;
      }
    }
    return out;
  }

  /// After loading: undoes [_protectWhitespace]. A line that is only [_nbsp]
  /// becomes an empty line, and leading [_nbsp]s become regular spaces.
  static Delta _restoreWhitespace(Delta delta) {
    final Delta out = Delta();
    bool atLineStart = true;
    for (final Operation op in delta.toList()) {
      final Object? data = op.data;
      if (data is! String) {
        out.push(op);
        atLineStart = false;
        continue;
      }
      final Map<String, dynamic>? attrs = op.attributes;
      final StringBuffer buf = StringBuffer();
      for (int k = 0; k < data.length; k++) {
        final String ch = data[k];
        if (ch == '\n') {
          buf.write(ch);
          atLineStart = true;
        } else if (atLineStart && ch == _nbsp) {
          // Drop a lone placeholder (empty line); otherwise restore a space.
          final bool lineIsOnlyNbsp =
              (k + 1 >= data.length || data[k + 1] == '\n') &&
                  (k == 0 || data[k - 1] == '\n');
          if (!lineIsOnlyNbsp) buf.write(' ');
        } else {
          buf.write(ch);
          atLineStart = false;
        }
      }
      final String text = buf.toString();
      if (text.isNotEmpty) out.insert(text, attrs);
    }
    return out;
  }
}
