import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'logger.dart';

/// Reports Module — file/text sharing helpers.
///
/// Ye utilities WhatsApp, Gmail (mailto), system share-sheet aur file-open
/// actions ko wrap karte hain taaki screens ko platform details se deal na
/// karna pade.
class ShareUtils {
  ShareUtils._();

  // ---------------------------------------------------------------------------
  // MIME helpers
  // ---------------------------------------------------------------------------

  /// `pdf`, `xlsx`, `csv` jaise report formats ke liye MIME type.
  static String mimeTypeForFormat(String? format) {
    switch (format?.toLowerCase().trim()) {
      case 'pdf':
        return 'application/pdf';
      case 'xlsx':
      case 'xls':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'csv':
        return 'text/csv';
      default:
        return 'application/octet-stream';
    }
  }

  static String _basename(String path) {
    final segments = path.replaceAll('\\', '/').split('/');
    return segments.isNotEmpty ? segments.last : path;
  }

  // ---------------------------------------------------------------------------
  // Generic file / text share
  // ---------------------------------------------------------------------------

  /// Kisi bhi installed app ke saath file share karo (system share-sheet).
  static Future<void> shareFile({
    required String filePath,
    String? fileName,
    String? mimeType,
    String? text,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }

    final xFile = XFile(
      filePath,
      mimeType: mimeType ?? mimeTypeForFormat(null),
      name: fileName ?? _basename(filePath),
    );
    await Share.shareXFiles(
      [xFile],
      subject: subject,
      text: text,
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  /// Simple text share (copy ho ya koi bhi messaging app).
  static Future<void> shareText(
    String text, {
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    await Share.share(
      text,
      subject: subject,
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  // ---------------------------------------------------------------------------
  // WhatsApp
  // ---------------------------------------------------------------------------

  /// WhatsApp par share karta hai. Returns `true` jab WhatsApp launch hua.
  ///
  /// * Text-only share: `whatsapp://send?text=...` deep link use hota hai.
  /// * File ke saath: WhatsApp ka official URL-scheme file attachments support
  ///   nahi karta, isliye system share-sheet khul jaati hai jahan se user
  ///   WhatsApp choose kar sakta hai (sabse reliable Flutter-only approach).
  /// * WhatsApp installed nahi hone par bhi system share-sheet fallback chalta
  ///   hai, taaki user kisi aur app se share kar sake.
  static Future<bool> shareViaWhatsApp({
    String? filePath,
    String? fileName,
    String? message,
    String? mimeType,
    Rect? sharePositionOrigin,
  }) async {
    final text = (message ?? '').trim();

    // Text-only → direct WhatsApp deep-link.
    if (filePath == null || filePath.trim().isEmpty) {
      final encoded = Uri.encodeComponent(
        text.isEmpty ? 'Sharing a report 📊' : text,
      );
      for (final scheme in ['whatsapp://send?text=', 'https://wa.me/?text=']) {
        final uri = Uri.parse('$scheme$encoded');
        if (await canLaunchUrl(uri)) {
          return launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      }
      // WhatsApp nahi mila — system share-sheet se text share kar do.
      await shareText(
        text.isEmpty ? 'Sharing a report 📊' : text,
        sharePositionOrigin: sharePositionOrigin,
      );
      return true;
    }

    // File ke saath: WhatsApp deep-link text share karega, par attachment ke
    // liye system share-sheet hi bharosemand hai.
    final encoded = Uri.encodeComponent(
      text.isEmpty ? 'Sharing report: ${fileName ?? 'report'}' : text,
    );
    final uri = Uri.parse('whatsapp://send?text=$encoded');
    if (await canLaunchUrl(uri)) {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) return true;
    }

    // Fallback: file ko system share-sheet se share karo (WhatsApp/Gmail sab
    // wahan listed hote hain).
    await shareFile(
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType,
      text: text,
      sharePositionOrigin: sharePositionOrigin,
    );
    return true;
  }

  // ---------------------------------------------------------------------------
  // Email / Gmail
  // ---------------------------------------------------------------------------

  /// Email (Gmail) share karta hai `mailto:` deep-link se.
  ///
  /// Note: `mailto:` scheme attachments support nahi karta; jab [filePath] di
  /// ho to file system share-sheet se share hoti hai (user Gmail choose kar
  /// sakta hai) aur subject/body pre-filled text ke roop mein jaati hai.
  static Future<bool> shareViaEmail({
    String? filePath,
    String? fileName,
    String? recipientEmail,
    String? subject,
    String? body,
    String? mimeType,
    Rect? sharePositionOrigin,
  }) async {
    final recipient = recipientEmail?.trim() ?? '';
    final mailSubject = subject?.trim() ?? '';
    final mailBody = body?.trim() ?? '';

    final params = <String, String>{
      if (recipient.isNotEmpty) 'to': recipient,
      if (mailSubject.isNotEmpty) 'subject': mailSubject,
      if (mailBody.isNotEmpty) 'body': mailBody,
    };

    if (filePath == null || filePath.trim().isEmpty) {
      if (params.isEmpty) {
        // Recipient/subject/body kuch nahi — default Gmail compose khol do.
        final gmailUri = Uri.parse('googlegmail://co');
        if (await canLaunchUrl(gmailUri)) {
          return launchUrl(gmailUri, mode: LaunchMode.externalApplication);
        }
      }
      final uri = Uri(
        scheme: 'mailto',
        query: params.isEmpty
            ? null
            : params.entries
                  .map(
                    (e) =>
                        '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
                  )
                  .join('&'),
      );
      if (await canLaunchUrl(uri)) {
        return launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      await shareText(
        mailBody.isEmpty ? mailSubject : '$mailSubject\n\n$mailBody',
        subject: mailSubject,
        sharePositionOrigin: sharePositionOrigin,
      );
      return true;
    }

    // File ke saath — share-sheet se share karo (Gmail attachment wahan se
    // handle hota hai).
    await shareFile(
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType,
      text: mailBody.isEmpty ? mailSubject : '$mailSubject\n\n$mailBody',
      subject: mailSubject,
      sharePositionOrigin: sharePositionOrigin,
    );
    return true;
  }

  // ---------------------------------------------------------------------------
  // Open / download
  // ---------------------------------------------------------------------------

  /// Local file ko device ke default viewer mein kholta hai.
  static Future<void> openFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }
    await OpenFile.open(filePath);
  }

  /// Remote `file_url` ko temporary directory mein download karke local path
  /// return karta hai (download → open/share/print ke liye).
  static Future<String> downloadFile({
    required String url,
    required String fileName,
  }) async {
    final dir = await getTemporaryDirectory();
    final safeName = fileName.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    final file = File('${dir.path}${Platform.pathSeparator}$safeName');

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Download failed with status ${response.statusCode}',
          uri: Uri.parse(url),
        );
      }
      await response.pipe(file.openWrite());
      return file.path;
    } catch (e) {
      AppLogger.e('Error downloading file', e);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Shareable text builder
  // ---------------------------------------------------------------------------

  /// Report ke baare mein ek formatted, emoji-rich share text banata hai —
  /// WhatsApp / Email / copy ke liye ready.
  static String generateShareText(Map<String, dynamic> report) {
    final title = report['title']?.toString() ?? 'Untitled Report';
    final type = _reportTypeLabel(report['report_type']?.toString());
    final status = _statusLabel(report['status']?.toString());
    final generatedBy =
        report['generated_by_name']?.toString() ??
        report['generated_by']?.toString() ??
        'System';
    final aiSummary = (report['ai_summary']?.toString() ?? '').trim();

    final dateFrom = _formatDate(report['date_from']);
    final dateTo = _formatDate(report['date_to']);
    final createdAt = _formatDateTime(report['created_at']);

    final buffer = StringBuffer()
      ..writeln('📊 *Report Summary*')
      ..writeln('──────────────────────')
      ..writeln('📌 *Title:* $title')
      ..writeln('🗂 *Type:* $type')
      ..writeln('📅 *Period:* $dateFrom  →  $dateTo')
      ..writeln('👤 *Generated By:* $generatedBy')
      ..writeln('🕒 *Generated At:* $createdAt')
      ..writeln('📈 *Status:* $status');

    final summary = _summaryHighlights(report['summary']);
    if (summary.isNotEmpty) {
      buffer
        ..writeln('')
        ..writeln('🔢 *Key Highlights*')
        ..writeln(summary);
    }

    if (aiSummary.isNotEmpty) {
      buffer
        ..writeln('')
        ..writeln('🤖 *AI Summary (DeepSeek)*')
        ..writeln(aiSummary);
    }

    buffer
      ..writeln('')
      ..writeln('Generated from MediFlux Hospital Software');

    return buffer.toString();
  }

  /// `summary` JSONB se short "label: value" lines banata hai.
  static String _summaryHighlights(dynamic summary) {
    final entries = <String, String>{};
    if (summary is Map) {
      for (final entry in summary.entries) {
        entries[entry.key.toString()] = entry.value?.toString() ?? '';
      }
    } else if (summary is List) {
      for (var i = 0; i < summary.length; i++) {
        final item = summary[i];
        if (item is Map) {
          final label =
              item['label'] ?? item['key'] ?? item['name'] ?? 'Item ${i + 1}';
          final value = item['value'] ?? item['count'] ?? item['total'] ?? '';
          entries[label.toString()] = value.toString();
        } else {
          entries['Item ${i + 1}'] = item?.toString() ?? '';
        }
      }
    }

    if (entries.isEmpty) return '';
    final buffer = StringBuffer();
    for (final entry in entries.entries.take(8)) {
      buffer.writeln('• ${entry.key}: ${entry.value}');
    }
    return buffer.toString().trimRight();
  }

  static String _reportTypeLabel(String? type) {
    switch (type?.toLowerCase().trim()) {
      case 'consultation':
        return 'Consultation';
      case 'patient':
        return 'Patient';
      case 'counseling':
        return 'Counseling';
      case 'doctor_performance':
      case 'doctor-performance':
        return 'Doctor Performance';
      case 'revenue':
        return 'Revenue';
      case 'followup':
      case 'follow_up':
        return 'Follow-up';
      default:
        return type == null || type.isEmpty ? 'General' : type;
    }
  }

  static String _statusLabel(String? status) {
    switch (status?.toLowerCase().trim()) {
      case 'ready':
        return 'Ready ✅';
      case 'generating':
        return 'Generating ⏳';
      case 'failed':
        return 'Failed ❌';
      default:
        return status == null || status.isEmpty ? 'Unknown' : status;
    }
  }

  static String _formatDate(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '');
    if (date == null) return '-';
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year}';
  }

  static String _formatDateTime(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '');
    if (date == null) return '-';
    final local = date.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final amPm = local.hour >= 12 ? 'PM' : 'AM';
    return '${_formatDate(local)} $hour:$minute $amPm';
  }
}
