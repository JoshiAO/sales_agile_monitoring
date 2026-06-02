import 'dart:typed_data';
// The following import is web-only. Analyzer in non-web contexts may not resolve
// it; ignore the URI check here because this file is conditionally exported
// only for web builds.
// ignore: uri_does_not_exist
import 'dart:js_util' as js_util;

void downloadFile(String filename, List<int> bytes) {
  final uint8 = Uint8List.fromList(bytes);
  final blobConstructor = js_util.getProperty(js_util.globalThis, 'Blob');
  final blob = js_util.callConstructor(blobConstructor, [js_util.jsify([uint8])]);
  final url = js_util.callMethod(js_util.getProperty(js_util.globalThis, 'URL'), 'createObjectURL', [blob]);
  final document = js_util.getProperty(js_util.globalThis, 'document');
  final body = js_util.getProperty(document, 'body');
  final anchor = js_util.callMethod(document, 'createElement', ['a']);
  js_util.setProperty(anchor, 'href', url);
  js_util.setProperty(anchor, 'download', filename);
  js_util.callMethod(body, 'appendChild', [anchor]);
  js_util.callMethod(anchor, 'click', []);
  js_util.callMethod(body, 'removeChild', [anchor]);
  js_util.callMethod(js_util.getProperty(js_util.globalThis, 'URL'), 'revokeObjectURL', [url]);
}
