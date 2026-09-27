/// Web implementation of [saveBytes]: triggers a browser download of the given
/// bytes by creating an in-memory Blob and clicking a temporary anchor. Used to
/// deliver the exported `.docx` on the web build (there is no filesystem to
/// save to). Selected via the conditional import in `document_exporter.dart`.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Downloads [bytes] as a file named [filename] with the given [mimeType].
/// Returns a short human-readable location description for the confirmation
/// message.
Future<String> saveBytes(
  List<int> bytes,
  String filename,
  String mimeType,
) async {
  final web.Blob blob = web.Blob(
    <JSUint8Array>[Uint8List.fromList(bytes).toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final String url = web.URL.createObjectURL(blob);
  final web.HTMLAnchorElement anchor =
      web.document.createElement('a') as web.HTMLAnchorElement
        ..href = url
        ..download = filename
        ..style.display = 'none';
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return 'your Downloads folder';
}
