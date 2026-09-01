import 'dart:typed_data';

import 'web_file_download_stub.dart'
    if (dart.library.js_interop) 'web_file_download_web.dart' as impl;

/// Browser-safe file download helper used by the Reports module.
///
/// On Flutter Web this triggers a native browser download of [bytes] with the
/// given [fileName]. On native platforms this is a no-op stub (the Download
/// button uses the existing `dart:io` / `open_file` path there).
abstract final class WebFileDownload {
  static Future<void> downloadBytes(Uint8List bytes, String fileName) =>
      impl.downloadBytes(bytes, fileName);
}
