import 'dart:typed_data';

/// Native (non-web) implementation of the browser download helper.
///
/// `WebFileDownload.downloadBytes` is only invoked on Flutter Web, so this
/// stub is intentionally unreachable on Android / Windows / Linux. It exists
/// purely so the conditional import in `web_file_download.dart` always has a
/// valid implementation to bind to.
Future<void> downloadBytes(Uint8List bytes, String fileName) async {
  throw UnsupportedError('Browser downloads are only supported on the web.');
}
