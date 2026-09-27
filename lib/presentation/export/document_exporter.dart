/// Builds and delivers export files (PDF and DOCX) from a selected, ordered
/// list of [ExportableDocument]s as a DOCX (Microsoft Word) file.
///
/// Layout contract:
/// - each document's **title** is rendered as a heading;
/// - each of its **paragraphs** follows as body text;
/// - a **page break** separates one document from the next, so every document
///   starts on a fresh page.
///
/// The DOCX is assembled as a minimal OpenXML (WordprocessingML) ZIP with the
/// `archive` package and delivered via the platform-specific [saveBytes] helper
/// (a browser download on web, a saved file on desktop/mobile).
library;

import 'dart:convert';

import 'package:archive/archive.dart';

import 'exportable_document.dart';
import 'save_bytes_io.dart' if (dart.library.html) 'save_bytes_web.dart'
    as saver;

/// The result of an export: whether it succeeded and where the file landed
/// (for the confirmation message).
class ExportResult {
  final bool success;
  final String location;
  final String? errorMessage;

  const ExportResult.ok(this.location)
      : success = true,
        errorMessage = null;

  const ExportResult.failed(this.errorMessage)
      : success = false,
        location = '';
}

/// Generates and delivers export files. Stateless; construct once and reuse.
class DocumentExporter {
  const DocumentExporter();

  /// Exports [documents] (in the given order) to a `.docx` named [baseFileName]
  /// (without extension). Returns an [ExportResult] describing the outcome.
  Future<ExportResult> export({
    required List<ExportableDocument> documents,
    required String baseFileName,
  }) async {
    try {
      final List<int> bytes = _buildDocx(documents);
      final String location = await saver.saveBytes(
        bytes,
        '$baseFileName.docx',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
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

  /// The `word/document.xml` body: heading + body paragraphs per document, with
  /// a page break between documents.
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

      if (doc.paragraphs.isEmpty) {
        body.write(
          '<w:p><w:r><w:rPr><w:i/></w:rPr>'
          '<w:t xml:space="preserve">(This document is empty.)</w:t></w:r></w:p>',
        );
      } else {
        for (final String paragraph in doc.paragraphs) {
          body.write(
            '<w:p><w:r><w:t xml:space="preserve">'
            '${_xmlEscape(paragraph)}</w:t></w:r></w:p>',
          );
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
      '</w:styles>';
}
