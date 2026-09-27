/// Native (desktop / mobile) implementation of [saveBytes]: writes the bytes to
/// a file in the app documents directory and returns its path. Used to deliver
/// the exported `.docx` on non-web builds. Selected via the conditional import
/// in `document_exporter.dart`.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Writes [bytes] to a file named [filename] in the app documents directory.
/// The [mimeType] is accepted for signature parity with the web
/// implementation but is not needed when writing to disk. Returns the full
/// file path for the confirmation message.
Future<String> saveBytes(
  List<int> bytes,
  String filename,
  String mimeType,
) async {
  final Directory dir = await getApplicationDocumentsDirectory();
  final File file = File('${dir.path}${Platform.pathSeparator}$filename');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
