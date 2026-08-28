import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/utils/logger.dart';

class StorageService {
  final SupabaseClient _client;
  static const String _bucketName = 'hims-storage';

  StorageService(this._client);

  Future<String> uploadFile({
    required String path,
    required File file,
    String? bucketName,
  }) async {
    try {
      final bucket = bucketName ?? _bucketName;
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_${path.split('/').last}';
      final fullPath = '$path/$fileName';
      
      await _client.storage.from(bucket).upload(
            fullPath,
            file,
            fileOptions: const FileOptions(upsert: true),
          );
      
      final publicUrl = _client.storage.from(bucket).getPublicUrl(fullPath);
      return publicUrl;
    } catch (e) {
      AppLogger.e('Error uploading file', e);
      rethrow;
    }
  }

  /// Web-safe binary upload (works on Flutter web + native).
  ///
  /// [bytes] is the raw file content, [fileName] is the original file name.
  /// Returns the public URL of the uploaded object.
  Future<String> uploadBytes({
    required String path,
    required Uint8List bytes,
    required String fileName,
    String? bucketName,
  }) async {
    try {
      final bucket = bucketName ?? _bucketName;
      final safeName = _sanitizeFileName(fileName);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fullPath = '$path/${timestamp}_$safeName';

      await _client.storage.from(bucket).uploadBinary(
            fullPath,
            bytes,
            fileOptions: const FileOptions(upsert: true),
          );

      return _client.storage.from(bucket).getPublicUrl(fullPath);
    } catch (e) {
      AppLogger.e('Error uploading bytes', e);
      rethrow;
    }
  }

  String _sanitizeFileName(String fileName) {
    final cleaned = fileName
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    return cleaned.isEmpty ? 'file' : cleaned;
  }

  Future<String> uploadPatientPhoto(String patientId, File file) async {
    return uploadFile(path: 'patients/$patientId', file: file);
  }

  Future<String> uploadDocument(String category, String id, File file) async {
    return uploadFile(path: '$category/$id', file: file);
  }

  Future<List<String>> listFiles(String path, {String? bucketName}) async {
    try {
      final bucket = bucketName ?? _bucketName;
      final files = await _client.storage.from(bucket).list(path: path);
      return files.map((f) => f.name).toList();
    } catch (e) {
      AppLogger.e('Error listing files', e);
      return [];
    }
  }

  Future<void> deleteFile(String path, {String? bucketName}) async {
    try {
      final bucket = bucketName ?? _bucketName;
      await _client.storage.from(bucket).remove([path]);
    } catch (e) {
      AppLogger.e('Error deleting file', e);
      rethrow;
    }
  }

  /// Downloads a storage object's raw bytes (web-safe, cross-platform).
  Future<Uint8List> downloadBytes(
    String path, {
    String? bucketName,
  }) async {
    try {
      final bucket = bucketName ?? _bucketName;
      return await _client.storage.from(bucket).download(path);
    } catch (e) {
      AppLogger.e('Error downloading file bytes', e);
      rethrow;
    }
  }

  /// Deletes a storage object by its public URL (or raw storage path).
  ///
  /// The public URL of `hims-storage` objects contains `/object/public/`
  /// followed by the raw path; this method normalizes both forms.
  Future<void> removeByUrl(String urlOrPath, {String? bucketName}) async {
    try {
      final bucket = bucketName ?? _bucketName;
      var path = urlOrPath;
      final publicMarker = '/object/public/$bucket/';
      final index = urlOrPath.indexOf(publicMarker);
      if (index != -1) {
        path = urlOrPath.substring(index + publicMarker.length);
      } else {
        final signedMarker = '/object/sign/$bucket/';
        final signedIndex = urlOrPath.indexOf(signedMarker);
        if (signedIndex != -1) {
          path = urlOrPath.substring(signedIndex + signedMarker.length);
        }
      }
      await _client.storage.from(bucket).remove([path]);
    } catch (e) {
      AppLogger.e('Error deleting file by url', e);
      rethrow;
    }
  }

  String getPublicUrl(String path, {String? bucketName}) {
    final bucket = bucketName ?? _bucketName;
    return _client.storage.from(bucket).getPublicUrl(path);
  }

  Future<File> downloadFile(String path, String fileName) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$fileName');
      await _client.storage.from(_bucketName).download(path).then((bytes) {
        file.writeAsBytesSync(bytes);
      });
      return file;
    } catch (e) {
      AppLogger.e('Error downloading file', e);
      rethrow;
    }
  }
}