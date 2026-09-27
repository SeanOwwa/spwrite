/// A minimal, presentation-ready snapshot of a document for export.
///
/// The export dialog builds these from the workspace state (title +
/// paragraph-split content) and hands a selected, ordered list to the
/// [DocumentExporter]. Keeping the exporter dependent on this tiny value type
/// (rather than the full domain `Document` + codec) keeps the file builders
/// pure and easy to reason about: title becomes a heading, each paragraph a
/// body block, with a page break between documents.
library;

import 'package:flutter/foundation.dart';

@immutable
class ExportableDocument {
  /// The document's display title, used as the heading for its section. Falls
  /// back to a placeholder upstream when the stored title is blank.
  final String title;

  /// The document body split into paragraphs (already flattened to plain text
  /// by the codec). May be empty for a document with no content.
  final List<String> paragraphs;

  const ExportableDocument({
    required this.title,
    required this.paragraphs,
  });
}
