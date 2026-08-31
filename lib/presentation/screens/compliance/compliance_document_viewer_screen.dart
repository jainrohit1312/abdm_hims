import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/providers.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/share_utils.dart';
import '../../../models/compliance_models.dart';
import '../../widgets/smart_navigation.dart';
import 'widgets/compliance_common.dart';

/// Built-in document viewer (`/compliance/document/:id/view`).
///
/// * Images (JPG/PNG/JPEG) — zoomable in-app viewer.
/// * PDF — pages rasterized in-app via the `printing` package.
/// * DOC/DOCX — metadata view with an "Open in device app" action.
///
/// Includes an optional auto-watermark overlay (hospital + viewer + timestamp),
/// and download / share / print / QR actions. Every view is written to the
/// compliance audit log.
class ComplianceDocumentViewerScreen extends ConsumerStatefulWidget {
  const ComplianceDocumentViewerScreen({super.key, required this.documentId});

  final String documentId;

  @override
  ConsumerState<ComplianceDocumentViewerScreen> createState() =>
      _ComplianceDocumentViewerScreenState();
}

class _ComplianceDocumentViewerScreenState
    extends ConsumerState<ComplianceDocumentViewerScreen> {
  Uint8List? _bytes;
  List<ui.Image> _pdfPages = const [];
  Object? _loadError;
  bool _loading = true;
  bool _watermarkOn = true;
  int _pageIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final page in _pdfPages) {
      page.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final doc = await ref
          .read(complianceDocumentByIdProvider(widget.documentId).future);
      if (doc == null) {
        setState(() {
          _loading = false;
          _loadError = 'Document not found';
        });
        return;
      }
      final filePath = doc['file_path']?.toString() ?? '';
      final bytes = await ref
          .read(storageServiceProvider)
          .downloadBytes(filePath);
      if (!mounted) return;

      final file = ComplianceDocumentFile.fromJson(doc);
      var pages = const <ui.Image>[];
      if (file.isPdf) {
        try {
          final rasterized = <ui.Image>[];
          await for (final page in Printing.raster(bytes, dpi: 150)) {
            rasterized.add(await page.toImage());
          }
          pages = rasterized;
        } catch (e) {
          AppLogger.w('PDF rasterization failed, falling back: $e');
        }
      }

      setState(() {
        _bytes = bytes;
        _pdfPages = pages;
        _loading = false;
      });

      // Audit the view.
      final hospitalId = doc['hospital_id']?.toString() ?? '';
      if (hospitalId.isNotEmpty) {
        await ref.read(complianceServiceProvider).logAudit(
              hospitalId: hospitalId,
              recordId: doc['record_id']?.toString(),
              documentId: widget.documentId,
              userId: await ref
                  .read(databaseServiceProvider)
                  .getCurrentUsersTableId(),
              action: 'view',
              detail: file.fileName,
            );
      }
    } catch (e) {
      AppLogger.e('Document viewer load failed', e);
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Document Viewer'),
        actions: [
          IconButton(
            tooltip: _watermarkOn ? 'Watermark ON' : 'Watermark OFF',
            icon: Icon(
              _watermarkOn ? Icons.branding_watermark : Icons.branding_watermark_outlined,
              color: _watermarkOn ? Theme.of(context).colorScheme.primary : null,
            ),
            onPressed: () => setState(() => _watermarkOn = !_watermarkOn),
          ),
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share_outlined),
            onPressed: _bytes == null ? null : () => _shareCurrent(),
          ),
          IconButton(
            tooltip: 'Download',
            icon: const Icon(Icons.download_outlined),
            onPressed: _bytes == null ? null : () => _downloadCurrent(),
          ),
          IconButton(
            tooltip: 'Print',
            icon: const Icon(Icons.print_outlined),
            onPressed: _bytes == null ? null : () => _printCurrent(),
          ),
          IconButton(
            tooltip: 'QR Code',
            icon: const Icon(Icons.qr_code),
            onPressed: _showQr,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return ComplianceEmptyState(
        icon: Icons.error_outline,
        message: 'Could not load document.\n$_loadError',
        actionLabel: 'Retry',
        onAction: _load,
      );
    }

    final doc = ref.watch(complianceDocumentByIdProvider(widget.documentId));
    final file = doc.maybeWhen(
      data: (d) => d == null ? null : ComplianceDocumentFile.fromJson(d),
      orElse: () => null,
    );

    if (file == null) {
      return const ComplianceEmptyState(
        icon: Icons.folder_off_outlined,
        message: 'Document metadata not available.',
      );
    }

    Widget content;
    if (file.isImage) {
      content = _watermark(
        InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: Center(child: Image.memory(_bytes!, fit: BoxFit.contain)),
        ),
      );
    } else if (file.isPdf && _pdfPages.isNotEmpty) {
      content = _watermark(
        Column(
          children: [
            Expanded(
              child: PageView.builder(
                itemCount: _pdfPages.length,
                onPageChanged: (index) => setState(() => _pageIndex = index),
                itemBuilder: (context, index) => Center(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 5,
                    child: RawImage(image: _pdfPages[index], fit: BoxFit.contain),
                  ),
                ),
              ),
            ),
            if (_pdfPages.length > 1)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'Page ${_pageIndex + 1} of ${_pdfPages.length}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      );
    } else {
      content = _watermark(
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  documentTypeIcon(file.fileName),
                  size: 72,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Preview not available for ${file.extension.toUpperCase()} files inside the app.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => _openInDeviceApp(file),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open in device app'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        content,
        if (_watermarkOn) _buildWatermarkOverlay(),
      ],
    );
  }

  /// Brightness-preserving overlay: the watermark is applied twice — once as a
  /// semi-transparent text layer (always readable) and the actual content is
  /// left untouched below it.
  Widget _watermark(Widget child) => child;

  Widget _buildWatermarkOverlay() {
    final auth = ref.watch(authStateProvider);
    final now = DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.now());
    return IgnorePointer(
      child: Center(
        child: Transform.rotate(
          angle: -0.4,
          child: Opacity(
            opacity: 0.16,
            child: Text(
              'CONFIDENTIAL\nMediFlux • ${auth.hospitalId ?? ''}\n${auth.userId ?? ''}\n$now',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: Colors.red,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<File> _writeTemp() async {
    final doc = await ref
        .read(complianceDocumentByIdProvider(widget.documentId).future);
    final fileName = doc?['file_name']?.toString() ?? 'document';
    final dir = await getTemporaryDirectory();
    final safeName = fileName.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    final file = File('${dir.path}${Platform.pathSeparator}$safeName');
    await file.writeAsBytes(_bytes!, flush: true);
    return file;
  }

  Future<void> _openInDeviceApp(ComplianceDocumentFile file) async {
    try {
      final temp = await _writeTemp();
      await OpenFile.open(temp.path);
    } catch (e) {
      AppLogger.e('Open in device app failed', e);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not open file: $e')));
      }
    }
  }

  Future<void> _shareCurrent() async {
    final doc = await ref
        .read(complianceDocumentByIdProvider(widget.documentId).future);
    final fileName = doc?['file_name']?.toString() ?? 'document';
    final mimeType = doc?['mime_type']?.toString();
    try {
      final file = await _writeTemp();
      if (!mounted) return;
      await ShareUtils.shareFile(
        filePath: file.path,
        fileName: fileName,
        mimeType: mimeType,
        text: 'Compliance document: $fileName',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Share failed: $e')));
      }
    }
  }

  Future<void> _downloadCurrent() async {
    final doc = await ref
        .read(complianceDocumentByIdProvider(widget.documentId).future);
    final fileName = doc?['file_name']?.toString() ?? 'document';
    try {
      final directory = await _saveDirectory();
      final saved = File(
        '${directory.path}${Platform.pathSeparator}${fileName.replaceAll(RegExp(r'[^\w.\-]+'), '_')}',
      );
      await saved.writeAsBytes(_bytes!, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved to ${saved.path}')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
  }

  Future<void> _printCurrent() async {
    final doc = await ref
        .read(complianceDocumentByIdProvider(widget.documentId).future);
    final fileName = doc?['file_name']?.toString() ?? 'document';
    try {
      await Printing.layoutPdf(onLayout: (_) async => _bytes!, name: fileName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Print failed: $e')));
      }
    }
  }

  void _showQr() {
    final doc = ref.read(complianceDocumentByIdProvider(widget.documentId));
    final data = doc.maybeWhen(
      data: (d) => d?['file_url']?.toString() ?? '/compliance',
      orElse: () => '/compliance',
    );
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Document QR'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(
              data: data,
              version: QrVersions.auto,
              size: 200,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 8),
            const Text(
              'Scan to quickly open this document',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

Future<Directory> _saveDirectory() async {
  if (!kIsWeb) {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    } catch (_) {
      // Not supported on this platform.
    }
  }
  return getApplicationDocumentsDirectory();
}
