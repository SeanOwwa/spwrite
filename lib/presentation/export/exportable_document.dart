/// A minimal, presentation-ready snapshot of a document for export.
///
/// The export dialog builds these from the workspace state (title + a
/// structured, formatting-preserving view of the content) and hands a selected,
/// ordered list to the [DocumentExporter]. Keeping the exporter dependent on
/// this tiny value type (rather than the full domain `Document` + codec) keeps
/// the file builders pure and easy to reason about: the title becomes a
/// heading, each block a body paragraph, with a page break between documents.
///
/// Unlike the earlier plain-text model, the body is carried as a list of
/// [ExportBlock]s, each holding its paragraph-level style (normal / heading /
/// list item) and an ordered list of [ExportRun]s that preserve the inline
/// formatting the editor applied (bold, italic, underline, strikethrough). This
/// is what lets the .docx export mirror the editor's formatting rather than
/// flattening it to plain text.
library;

import 'package:flutter/foundation.dart';

/// The paragraph-level style of an [ExportBlock].
///
/// Mirrors the block-level constructs the editor / Markdown codec support so
/// the exporter can map each to the appropriate WordprocessingML paragraph
/// style or numbering.
enum ExportBlockStyle {
  /// An ordinary body paragraph.
  normal,

  /// A heading. The level (1..6) is carried on the block itself.
  heading,

  /// A bullet (unordered) list item.
  bulletItem,

  /// A numbered (ordered) list item.
  numberedItem,
}

/// A run of text sharing a single set of inline attributes.
///
/// A paragraph is a sequence of runs; splitting on attribute boundaries is what
/// lets, e.g., a **bold** word sit inside an otherwise plain sentence.
@immutable
class ExportRun {
  /// The run's text. Never contains a newline (paragraph breaks are modelled by
  /// separate [ExportBlock]s).
  final String text;

  /// Whether this run is bold.
  final bool bold;

  /// Whether this run is italic.
  final bool italic;

  /// Whether this run is underlined.
  final bool underline;

  /// Whether this run is struck through.
  final bool strikethrough;

  const ExportRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
  });
}

/// One paragraph of a document: its block style (+ heading level) and its runs.
@immutable
class ExportBlock {
  /// The paragraph-level style.
  final ExportBlockStyle style;

  /// The heading level (1..6) when [style] is [ExportBlockStyle.heading];
  /// ignored otherwise. Defaults to 1.
  final int headingLevel;

  /// The ordered runs making up this paragraph. May be empty for a blank line
  /// (which callers typically drop).
  final List<ExportRun> runs;

  const ExportBlock({
    required this.style,
    this.headingLevel = 1,
    required this.runs,
  });

  /// A convenience for a plain, unformatted paragraph of [text].
  factory ExportBlock.plain(String text) => ExportBlock(
        style: ExportBlockStyle.normal,
        runs: <ExportRun>[ExportRun(text: text)],
      );
}

@immutable
class ExportableDocument {
  /// The document's display title, used as the heading for its section. Falls
  /// back to a placeholder upstream when the stored title is blank.
  final String title;

  /// The document body as an ordered list of formatted [ExportBlock]s. Empty
  /// for a document with no content.
  final List<ExportBlock> blocks;

  const ExportableDocument({
    required this.title,
    required this.blocks,
  });
}
