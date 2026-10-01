/// Builds and delivers export files (PDF and DOCX) from a selected, ordered
/// list of [ExportableDocument]s as a DOCX (Microsoft Word) file.
///
/// Layout contract:
/// - each document's **title** is rendered as a heading;
/// - each of its **blocks** follows as a body paragraph, preserving its
///   paragraph style (headings, bullet / numbered list items) and each run's
///   inline formatting (bold, italic, underline, strikethrough);
/// - a **page break** separates one document from the next, so every document
///   starts on a fresh page.
///
/// The DOCX is assembled as a minimal OpenXML (WordprocessingML) ZIP with the
/// `archive` package and delivered either by an injected [DocxDelivery] (the
/// desktop Save As flow, see `export_location_service.dart`) or, by default,
/// the platform-specific `saveBytes` helper (a browser download on web).
library;

import 'dart:convert';

import 'package:archive/archive.dart';

import 'exportable_document.dart';
import 'save_bytes_io.dart' if (dart.library.html) 'save_bytes_web.dart'
    as saver;

/// Delivers the built `.docx` [bytes] under the suggested [fileName]. Returns
/// a description of where the file landed (a full path on desktop), or `null`
/// when the user cancelled (nothing was saved).
typedef DocxDelivery = Future<String?> Function(
  List<int> bytes,
  String fileName,
);

/// The `.docx` MIME type.
const String docxMimeType =
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

/// The result of an export: whether it succeeded, was cancelled by the user,
/// and where the file landed (for the confirmation message).
class ExportResult {
  final bool success;
  final bool cancelled;
  final String location;
  final String? errorMessage;

  const ExportResult.ok(this.location)
      : success = true,
        cancelled = false,
        errorMessage = null;

  const ExportResult.cancelled()
      : success = false,
        cancelled = true,
        location = '',
        errorMessage = null;

  const ExportResult.failed(this.errorMessage)
      : success = false,
        cancelled = false,
        location = '';
}

/// Generates and delivers export files. Stateless; construct once and reuse.
class DocumentExporter {
  const DocumentExporter();

  /// Exports [documents] (in the given order) to a `.docx` named [baseFileName]
  /// (without extension). Returns an [ExportResult] describing the outcome.
  ///
  /// [deliver] chooses where the file goes; when omitted the platform
  /// `saveBytes` helper is used. A `null` from [deliver] means the user
  /// cancelled, reported as [ExportResult.cancelled].
  Future<ExportResult> export({
    required List<ExportableDocument> documents,
    required String baseFileName,
    DocxDelivery? deliver,
  }) async {
    try {
      final List<int> bytes = _buildDocx(documents);
      final String fileName = '$baseFileName.docx';
      final String? location = deliver != null
          ? await deliver(bytes, fileName)
          : await saver.saveBytes(bytes, fileName, docxMimeType);
      if (location == null) return const ExportResult.cancelled();
      return ExportResult.ok(location);
    } catch (e) {
      return ExportResult.failed('Export failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // DOCX (minimal WordprocessingML package)
  // ---------------------------------------------------------------------------

  /// Assembles a minimal, valid `.docx` (OpenXML) package as ZIP bytes. Each
  /// document's title is a `Heading1` paragraph, each paragraph a `Normal`
  /// paragraph, and a page-break paragraph separates documents.
  List<int> _buildDocx(List<ExportableDocument> documents) {
    final String documentXml = _buildDocumentXml(documents);

    final Archive archive = Archive()
      ..addFile(_utf8File('[Content_Types].xml', _contentTypesXml))
      ..addFile(_utf8File('_rels/.rels', _rootRelsXml))
      ..addFile(_utf8File('word/document.xml', documentXml))
      ..addFile(_utf8File('word/_rels/document.xml.rels', _documentRelsXml))
      ..addFile(_utf8File('word/numbering.xml', _numberingXml))
      ..addFile(_utf8File('word/styles.xml', _stylesXml));

    final List<int>? encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw StateError('Failed to encode the .docx archive.');
    }
    return encoded;
  }

  ArchiveFile _utf8File(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    return ArchiveFile(name, bytes.length, bytes);
  }

  /// The `word/document.xml` body: title heading + formatted body paragraphs
  /// per document, with a page break between documents. Each body block keeps
  /// its paragraph style (heading / list item / normal) and every run keeps its
  /// inline formatting (bold / italic / underline / strikethrough).
  String _buildDocumentXml(List<ExportableDocument> documents) {
    final StringBuffer body = StringBuffer();

    for (int i = 0; i < documents.length; i++) {
      final ExportableDocument doc = documents[i];

      // Page break before every document except the first, so each starts on a
      // new page.
      if (i > 0) {
        body.write(
          '<w:p><w:r><w:br w:type="page"/></w:r></w:p>',
        );
      }

      // Title as Heading1.
      body.write(
        '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
        '<w:r><w:t xml:space="preserve">${_xmlEscape(doc.title)}</w:t></w:r></w:p>',
      );

      if (doc.blocks.isEmpty) {
        body.write(
          '<w:p><w:r><w:rPr><w:i/></w:rPr>'
          '<w:t xml:space="preserve">(This document is empty.)</w:t></w:r></w:p>',
        );
      } else {
        for (final ExportBlock block in doc.blocks) {
          body.write(_paragraphXml(block));
        }
      }
    }

    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body>$body'
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" '
        'w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>'
        '</w:body></w:document>';
  }

  /// Renders one [ExportBlock] as a `<w:p>` with the appropriate paragraph
  /// properties (heading style, or list numbering) followed by its formatted
  /// runs.
  String _paragraphXml(ExportBlock block) {
    final StringBuffer p = StringBuffer('<w:p>');

    final String pPr = _paragraphPropsXml(block);
    if (pPr.isNotEmpty) p.write(pPr);

    for (final ExportRun run in block.runs) {
      p.write(_runXml(run));
    }

    p.write('</w:p>');
    return p.toString();
  }

  /// The `<w:pPr>` for a block: a heading style for headings, or list numbering
  /// for list items. Body paragraphs need no properties.
  String _paragraphPropsXml(ExportBlock block) {
    switch (block.style) {
      case ExportBlockStyle.heading:
        final int level = block.headingLevel.clamp(1, 6);
        // Body headings start at Heading2 so they sit below the document title
        // (Heading1) in Word's outline.
        final int styleLevel = (level + 1).clamp(2, 6);
        return '<w:pPr><w:pStyle w:val="Heading$styleLevel"/></w:pPr>';
      case ExportBlockStyle.bulletItem:
        // numId 1 -> bullet list (see numbering.xml).
        return '<w:pPr><w:pStyle w:val="ListParagraph"/>'
            '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>';
      case ExportBlockStyle.numberedItem:
        // numId 2 -> ordered list (see numbering.xml).
        return '<w:pPr><w:pStyle w:val="ListParagraph"/>'
            '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr>';
      case ExportBlockStyle.normal:
        return '';
    }
  }

  /// Renders one [ExportRun] as a `<w:r>` carrying its inline run properties
  /// (`<w:b/>`, `<w:i/>`, `<w:u .../>`, `<w:strike/>`) when set.
  String _runXml(ExportRun run) {
    final StringBuffer rPr = StringBuffer();
    if (run.bold) rPr.write('<w:b/>');
    if (run.italic) rPr.write('<w:i/>');
    if (run.underline) rPr.write('<w:u w:val="single"/>');
    if (run.strikethrough) rPr.write('<w:strike/>');

    final String rPrXml = rPr.isEmpty ? '' : '<w:rPr>$rPr</w:rPr>';
    return '<w:r>$rPrXml<w:t xml:space="preserve">'
        '${_xmlEscape(run.text)}</w:t></w:r>';
  }

  /// Escapes the five XML predefined entities so document text is safe inside
  /// the WordprocessingML markup.
  String _xmlEscape(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static const String _contentTypesXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '<Override PartName="/word/styles.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
      '<Override PartName="/word/numbering.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>'
      '</Types>';

  static const String _rootRelsXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
      'Target="word/document.xml"/>'
      '</Relationships>';

  static const String _documentRelsXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" '
      'Target="styles.xml"/>'
      '<Relationship Id="rId2" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" '
      'Target="numbering.xml"/>'
      '</Relationships>';

  static const String _stylesXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
      '<w:name w:val="Normal"/></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading1">'
      '<w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr>'
      '<w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading2">'
      '<w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:spacing w:before="200" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr>'
      '<w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading3">'
      '<w:name w:val="heading 3"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:spacing w:before="180" w:after="90"/><w:outlineLvl w:val="2"/></w:pPr>'
      '<w:rPr><w:b/><w:sz w:val="26"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading4">'
      '<w:name w:val="heading 4"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:spacing w:before="160" w:after="80"/><w:outlineLvl w:val="3"/></w:pPr>'
      '<w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading5">'
      '<w:name w:val="heading 5"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:spacing w:before="140" w:after="70"/><w:outlineLvl w:val="4"/></w:pPr>'
      '<w:rPr><w:b/><w:sz w:val="23"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading6">'
      '<w:name w:val="heading 6"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:spacing w:before="120" w:after="60"/><w:outlineLvl w:val="5"/></w:pPr>'
      '<w:rPr><w:b/><w:sz w:val="22"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="ListParagraph">'
      '<w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:ind w:left="720"/></w:pPr></w:style>'
      '</w:styles>';

  /// The `word/numbering.xml` part: one bullet definition (numId 1) and one
  /// ordered/decimal definition (numId 2), referenced by list paragraphs.
  static const String _numberingXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      // Abstract bullet list.
      '<w:abstractNum w:abstractNumId="0">'
      '<w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val="\u2022"/>'
      '<w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>'
      '</w:abstractNum>'
      // Abstract ordered (decimal) list.
      '<w:abstractNum w:abstractNumId="1">'
      '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/>'
      '<w:lvlText w:val="%1."/>'
      '<w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>'
      '</w:abstractNum>'
      // Concrete instances.
      '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
      '<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>'
      '</w:numbering>';
}
