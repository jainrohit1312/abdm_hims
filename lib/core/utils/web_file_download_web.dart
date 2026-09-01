import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

/// Flutter Web implementation of the browser download helper.
///
/// Builds a `data:application/pdf;base64,...` URL, attaches it to a temporary
/// `<a download>` element and clicks it. This triggers the browser's native
/// "save file" flow without relying on `dart:io`, `path_provider` or
/// `open_file` (none of which work on Flutter Web).
Future<void> downloadBytes(Uint8List bytes, String fileName) async {
  final window = globalContext;
  final document = window['document'] as JSObject?;
  if (document == null) {
    throw Exception('Browser document is not available.');
  }

  final anchor = document.callMethod<JSObject>(
    'createElement'.toJS,
    'a'.toJS,
  );
  final base64 = base64Encode(bytes);
  anchor['href'] = 'data:application/pdf;base64,$base64'.toJS;
  anchor['download'] = fileName.toJS;

  final body = document['body'] as JSObject?;
  body?.callMethod<JSAny?>('appendChild'.toJS, anchor);
  anchor.callMethod<JSAny?>('click'.toJS);
  body?.callMethod<JSAny?>('removeChild'.toJS, anchor);
}
