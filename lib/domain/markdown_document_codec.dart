/// Domain layer: [MarkdownDocumentCodec], the single testable seam that
/// isolates Quill Delta <-> Markdown conversion.
///
/// The WYSIWYG editor operates on a Quill [Delta], but documents are persisted
/// as a portable Markdown source string. This codec is a thin wrapper over the
/// `markdown_quill` package's converters so the editor and the state layer
/// depend on one place for both directions of the conversion.
library;

import 'package:flutter_quill/flutter_quill.dart' show Attribute, Node;
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
      : _deltaToMarkdown = DeltaToMarkdown(
          // Italic is written with `*` rather than the package default `_`:
          // CommonMark never treats an intraword `_` as emphasis, so italicising
          // part of a word ("un*believ*able") only round-trips with `*`.
          customTextAttrsHandlers: <String, CustomAttributeHandler>{
            Attribute.italic.key: CustomAttributeHandler(
              beforeContent: (Attribute<Object?> attribute, Node node,
                  StringSink output) {
                if (!_hasAttr(node.previous, attribute.key)) {
                  output.write('*');
                }
              },
              afterContent: (Attribute<Object?> attribute, Node node,
                  StringSink output) {
                if (!_hasAttr(node.next, attribute.key)) output.write('*');
              },
            ),
          },
        ),
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
  String deltaToMarkdown(Delta delta) => _deltaToMarkdown
      .convert(_protectWhitespace(_detachEdgeWhitespace(delta)));

  /// Converts a Markdown source string back into a Quill [Delta].
  ///
  /// Used on load to render stored Markdown into the editor (Req 15.2).
  /// Restricted to the supported feature set (bold, italic, headings,
  /// ordered/unordered lists, links).
  Delta markdownToDelta(String markdown) => _restoreWhitespace(
      _markdownToDelta.convert(repairLegacyEmphasis(markdown)));

  /// Whether [node] (a sibling inline node, possibly `null`) carries [key].
  static bool _hasAttr(Node? node, String key) =>
      node != null && node.style.attributes.containsKey(key);

  /// Inline styles whose Markdown delimiters must hug non-whitespace text.
  static const Set<String> _delimitedInlineKeys = <String>{'bold', 'italic'};

  /// Before saving: moves leading/trailing whitespace out of bold/italic runs.
  ///
  /// Selecting a sentence usually grabs the space after it, giving an italic
  /// run like "a sentence. ". Written as `*a sentence. *`, the closing
  /// delimiter follows a space, so CommonMark does not read it as emphasis and
  /// the reloaded text showed literal markers. Keeping the whitespace outside
  /// the run (`*a sentence.* `) is visually identical and round-trips.
  static Delta _detachEdgeWhitespace(Delta delta) {
    final Delta out = Delta();
    for (final Operation op in delta.toList()) {
      final Object? data = op.data;
      final Map<String, dynamic>? attrs = op.attributes;
      if (data is! String ||
          attrs == null ||
          !attrs.keys.any(_delimitedInlineKeys.contains)) {
        out.push(op);
        continue;
      }
      final Map<String, dynamic> plainAttrs = Map<String, dynamic>.of(attrs)
        ..removeWhere((String k, dynamic _) => _delimitedInlineKeys.contains(k));
      final Map<String, dynamic>? edgeAttrs =
          plainAttrs.isEmpty ? null : plainAttrs;

      final List<String> lines = data.split('\n');
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        final String core = line.trim();
        if (core.isEmpty) {
          if (line.isNotEmpty) out.insert(line, edgeAttrs);
        } else {
          final int start = line.indexOf(core);
          final String lead = line.substring(0, start);
          final String trail = line.substring(start + core.length);
          if (lead.isNotEmpty) out.insert(lead, edgeAttrs);
          out.insert(core, attrs);
          if (trail.isNotEmpty) out.insert(trail, edgeAttrs);
        }
        // A newline carries block attributes only; inline bold/italic on it
        // is meaningless and confuses the Markdown writer.
        if (i < lines.length - 1) out.insert('\n', edgeAttrs);
      }
    }
    return out;
  }

  /// Repairs emphasis saved by earlier versions, which wrote italic as `_…_`
  /// even when the run began or ended with whitespace (`_a sentence. _`).
  /// Markdown reads those underscores literally, so reopened documents showed
  /// them instead of italics. Such pairs are rewritten to `*a sentence.* `.
  ///
  /// Intraword pairs (`un_believ_able`) had the same problem and are repaired
  /// too. Only unescaped underscores are considered: the codec always escapes
  /// a literal underscore the writer typed as `\_`, so an unescaped one can
  /// only be an italic marker. Link destinations are left untouched, and a
  /// line with an odd number of markers is left as-is rather than guessed at.
  /// Rewriting an already-valid `_x_` to `*x*` is harmless (same meaning).
  static String repairLegacyEmphasis(String markdown) {
    if (!markdown.contains('_')) return markdown;
    return markdown.split('\n').map(_repairLine).join('\n');
  }

  static final RegExp _linkDestination = RegExp(r'\]\([^)]*\)');

  static String _repairLine(String line) {
    if (!line.contains('_')) return line;
    // Mark characters inside link destinations so their underscores are kept.
    final List<bool> masked = List<bool>.filled(line.length, false);
    for (final RegExpMatch m in _linkDestination.allMatches(line)) {
      for (int k = m.start; k < m.end; k++) {
        masked[k] = true;
      }
    }
    final List<int> marks = <int>[];
    for (int k = 0; k < line.length; k++) {
      if (line[k] != '_' || masked[k]) continue;
      int backslashes = 0;
      for (int j = k - 1; j >= 0 && line[j] == '\\'; j--) {
        backslashes++;
      }
      if (backslashes.isOdd) continue; // Escaped literal underscore.
      marks.add(k);
    }
    if (marks.length < 2 || marks.length.isOdd) return line;

    final StringBuffer out = StringBuffer();
    int cursor = 0;
    for (int p = 0; p + 1 < marks.length; p += 2) {
      final int open = marks[p];
      final int close = marks[p + 1];
      final String inner = line.substring(open + 1, close);
      final String core = inner.trim();
      if (core.isEmpty) continue;
      final int coreStart = inner.indexOf(core);
      out
        ..write(line.substring(cursor, open))
        ..write(inner.substring(0, coreStart))
        ..write('*')
        ..write(core)
        ..write('*')
        ..write(inner.substring(coreStart + core.length));
      cursor = close + 1;
    }
    out.write(line.substring(cursor));
    return out.toString();
  }

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
