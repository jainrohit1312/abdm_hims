import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../app/providers.dart';
import '../../../core/utils/share_utils.dart';
import '../../widgets/app_refresh_button.dart';
import '../../widgets/smart_navigation.dart';
import 'widgets/report_card.dart';
import 'widgets/share_options_sheet.dart';

/// `/reports/:id` — ek report ki detail: metadata header, AI summary,
/// summary statistics cards aur data table. Bottom bar par Download + Share.
class ReportsDetailScreen extends ConsumerStatefulWidget {
  const ReportsDetailScreen({super.key, required this.reportId});

  final String reportId;

  @override
  ConsumerState<ReportsDetailScreen> createState() =>
      _ReportsDetailScreenState();
}

class _ReportsDetailScreenState extends ConsumerState<ReportsDetailScreen> {
  bool _busy = false;

  Rect _shareOrigin() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Rect.zero;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  String _fileName(Map<String, dynamic> report) {
    final title = report['title']?.toString() ?? 'report';
    final format = report['file_format']?.toString() ?? 'pdf';
    return '${title.replaceAll(RegExp(r'[^\w\- ]+'), '').trim()}.$format';
  }

  String get _safeTitle {
    return 'report_${widget.reportId}';
  }

  @override
  Widget build(BuildContext context) {
    final reportAsync = ref.watch(reportDetailProvider(widget.reportId));

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Report Details'),
        actions: [
          AppRefreshButton(
            onRefresh: () =>
                ref.invalidate(reportDetailProvider(widget.reportId)),
          ),
        ],
      ),
      body: reportAsync.when(
        skipLoadingOnReload: true,
        data: (report) {
          if (report == null) {
            return const _ReportNotFound();
          }
          return _ReportDetailBody(
            report: report,
            busy: _busy,
            onDownload: () => _download(report),
            onShare: () => _openShareSheet(report),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          error: error,
          onRetry: () => ref.invalidate(reportDetailProvider(widget.reportId)),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Share actions
  // ---------------------------------------------------------------------------

  Future<void> _openShareSheet(Map<String, dynamic> report) {
    return ShareOptionsSheet.show(
      context,
      report: report,
      onWhatsApp: () => _shareWhatsApp(report),
      onEmail: () => _shareEmail(report),
      onCopyText: () => _copyText(report),
      onMoreApps: () => _shareMoreApps(report),
      onDownload: () => _download(report),
      onPrint: () => _print(report),
    );
  }

  Future<void> _shareWhatsApp(Map<String, dynamic> report) async {
    await _runBusy(() async {
      final text = ShareUtils.generateShareText(report);
      final filePath = await _ensureLocalFile(report);
      await ShareUtils.shareViaWhatsApp(
        filePath: filePath,
        fileName: filePath == null ? null : _fileName(report),
        message: text,
        mimeType: ShareUtils.mimeTypeForFormat(
          report['file_format']?.toString(),
        ),
        sharePositionOrigin: _shareOrigin(),
      );
    });
  }

  Future<void> _shareEmail(Map<String, dynamic> report) async {
    await _runBusy(() async {
      final text = ShareUtils.generateShareText(report);
      final filePath = await _ensureLocalFile(report);
      await ShareUtils.shareViaEmail(
        filePath: filePath,
        fileName: filePath == null ? null : _fileName(report),
        subject: report['title']?.toString() ?? 'Report',
        body: text,
        mimeType: ShareUtils.mimeTypeForFormat(
          report['file_format']?.toString(),
        ),
        sharePositionOrigin: _shareOrigin(),
      );
    });
  }

  Future<void> _copyText(Map<String, dynamic> report) async {
    final text = ShareUtils.generateShareText(report);
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report summary copied to clipboard')),
      );
    }
  }

  Future<void> _shareMoreApps(Map<String, dynamic> report) async {
    await _runBusy(() async {
      final filePath = await _ensureLocalFile(report);
      if (filePath != null) {
        await ShareUtils.shareFile(
          filePath: filePath,
          fileName: _fileName(report),
          mimeType: ShareUtils.mimeTypeForFormat(
            report['file_format']?.toString(),
          ),
          text: ShareUtils.generateShareText(report),
          subject: report['title']?.toString(),
          sharePositionOrigin: _shareOrigin(),
        );
      } else {
        await ShareUtils.shareText(
          ShareUtils.generateShareText(report),
          subject: report['title']?.toString(),
          sharePositionOrigin: _shareOrigin(),
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Download / print
  // ---------------------------------------------------------------------------

  Future<void> _download(Map<String, dynamic> report) async {
    await _runBusy(() async {
      final filePath = await _ensureLocalFile(report);
      if (filePath == null) {
        _showSnack('No file available for this report yet.');
        return;
      }
      await OpenFile.open(filePath);
      _showSnack('Report downloaded to $filePath');
    });
  }

  Future<void> _print(Map<String, dynamic> report) async {
    await _runBusy(() async {
      final bytes = await _buildPdfBytes(report);
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    });
  }

  /// `file_url` se file download karta hai; URL missing ho to report data se
  /// locally ek PDF generate karta hai. Dono cases mein local file path milta
  /// hai (share/open/print ke liye).
  Future<String?> _ensureLocalFile(Map<String, dynamic> report) async {
    final url = report['file_url']?.toString();
    if (url != null && url.trim().isNotEmpty) {
      try {
        return await ShareUtils.downloadFile(
          url: url.trim(),
          fileName: _fileName(report),
        );
      } catch (e) {
        _showSnack('Download failed: $e');
        return null;
      }
    }

    // Fallback: data se PDF bana kar temp mein save karo.
    try {
      final bytes = await _buildPdfBytes(report);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$_safeTitle.pdf');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (e) {
      _showSnack('Could not generate PDF: $e');
      return null;
    }
  }

  Future<Uint8List> _buildPdfBytes(Map<String, dynamic> report) async {
    final doc = pw.Document();
    final title = report['title']?.toString() ?? 'Untitled Report';
    final type = ReportVisuals.labelForType(report['report_type']?.toString());
    final status = ReportVisuals.labelForStatus(report['status']?.toString());
    final generatedBy =
        report['generated_by_name']?.toString() ??
        report['generated_by']?.toString() ??
        'System';
    final aiSummary = (report['ai_summary']?.toString() ?? '').trim();
    final summaryEntries = ReportVisuals.summaryEntries(report, limit: 20);
    final table = _TableData.from(report['data']);

    doc.addPage(
      pw.MultiPage(
        pageFormat: pdf.PdfPageFormat.a4,
        build: (context) => [
          pw.Header(
            level: 0,
            child: pw.Text(
              'HIMS — Hospital Information Management System',
              style: pw.TextStyle(fontSize: 9, color: pdf.PdfColors.grey700),
            ),
          ),
          pw.Text(
            title,
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            '$type  •  $status  •  Generated by $generatedBy',
            style: pw.TextStyle(fontSize: 10, color: pdf.PdfColors.grey700),
          ),
          pw.SizedBox(height: 16),
          if (aiSummary.isNotEmpty) ...[
            pw.Text(
              'AI Summary',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.Text(aiSummary, style: const pw.TextStyle(fontSize: 11)),
            pw.SizedBox(height: 16),
          ],
          if (summaryEntries.isNotEmpty) ...[
            pw.Text(
              'Key Highlights',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headers: ['Metric', 'Value'],
              data: summaryEntries.map((e) => [e.key, e.value]).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              headerDecoration: pw.BoxDecoration(color: pdf.PdfColors.grey300),
              cellStyle: const pw.TextStyle(fontSize: 10),
            ),
            pw.SizedBox(height: 16),
          ],
          if (table != null && table.rows.isNotEmpty) ...[
            pw.Text(
              'Detailed Data',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headers: table.columns,
              data: table.rows,
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              headerDecoration: pw.BoxDecoration(color: pdf.PdfColors.grey300),
              cellStyle: const pw.TextStyle(fontSize: 9),
            ),
          ],
          pw.SizedBox(height: 24),
          pw.Text(
            'Generated on ${DateTime.now()}',
            style: pw.TextStyle(fontSize: 9, color: pdf.PdfColors.grey600),
          ),
        ],
      ),
    );

    return Uint8List.fromList(await doc.save());
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _showSnack('Action failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Report detail body — header, AI summary, stats grid aur data table.
class _ReportDetailBody extends StatelessWidget {
  const _ReportDetailBody({
    required this.report,
    required this.busy,
    required this.onDownload,
    required this.onShare,
  });

  final Map<String, dynamic> report;
  final bool busy;
  final VoidCallback onDownload;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = report['report_type']?.toString();
    final typeColor = ReportVisuals.colorForType(type);
    final title = report['title']?.toString() ?? 'Untitled Report';
    final aiSummary = (report['ai_summary']?.toString() ?? '').trim();
    final summaryEntries = ReportVisuals.summaryEntries(report, limit: 20);
    final table = _TableData.from(report['data']);
    final createdAt = DateTime.tryParse(report['created_at']?.toString() ?? '');
    final dateFrom = report['date_from']?.toString();
    final dateTo = report['date_to']?.toString();
    final generatedBy =
        report['generated_by_name']?.toString() ??
        report['generated_by']?.toString();

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              // Header card
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: typeColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              ReportVisuals.iconForType(type),
                              color: typeColor,
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  ReportVisuals.labelForType(type),
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: typeColor,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          ReportStatusBadge(
                            status: report['status']?.toString(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _MetaRow(
                        icon: Icons.event_outlined,
                        label: 'Period',
                        value: '$dateFrom  →  $dateTo',
                      ),
                      if (createdAt != null) ...[
                        const SizedBox(height: 8),
                        _MetaRow(
                          icon: Icons.schedule,
                          label: 'Generated At',
                          value: createdAt.toLocal().toString(),
                        ),
                      ],
                      if (generatedBy != null && generatedBy.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _MetaRow(
                          icon: Icons.person_outline,
                          label: 'Generated By',
                          value: generatedBy,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // AI summary
              if (aiSummary.isNotEmpty) ...[
                _SectionTitle(
                  icon: Icons.auto_awesome,
                  title: 'AI Summary (DeepSeek)',
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 8),
                Card(
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.35,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      aiSummary,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Summary statistics
              if (summaryEntries.isNotEmpty) ...[
                _SectionTitle(
                  icon: Icons.bar_chart,
                  title: 'Summary Statistics',
                  color: theme.colorScheme.secondary,
                ),
                const SizedBox(height: 8),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 1.7,
                  ),
                  itemCount: summaryEntries.length,
                  itemBuilder: (context, index) {
                    final entry = summaryEntries[index];
                    return _StatCard(label: entry.key, value: entry.value);
                  },
                ),
                const SizedBox(height: 16),
              ],

              // Data table
              if (table != null && table.rows.isNotEmpty) ...[
                _SectionTitle(
                  icon: Icons.table_chart_outlined,
                  title: 'Detailed Data',
                  color: theme.colorScheme.tertiary,
                ),
                const SizedBox(height: 8),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(8),
                    child: DataTable(
                      headingRowColor: WidgetStatePropertyAll(
                        theme.colorScheme.surfaceContainerHighest,
                      ),
                      columns: [
                        for (final column in table.columns)
                          DataColumn(label: Text(column)),
                      ],
                      rows: [
                        for (final row in table.rows)
                          DataRow(
                            cells: [
                              for (final cell in row) DataCell(Text(cell)),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
                if (table.truncated) ...[
                  const SizedBox(height: 6),
                  Center(
                    child: Text(
                      'Showing first ${table.rows.length} rows',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        // Bottom action bar
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : onDownload,
                    icon: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download),
                    label: const Text('Download'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : onShare,
                    icon: const Icon(Icons.share),
                    label: const Text('Share'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.color,
  });

  final IconData icon;
  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.primary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// `data` JSONB ko tabular form mein parse karta hai.
///
/// Expected shape: `List<Map<String, dynamic>>` (har row ek object). Sirf
/// pehle [maxRows] rows aur [maxColumns] columns UI/PDF mein dikhaye jaate
/// hain.
class _TableData {
  _TableData({
    required this.columns,
    required this.rows,
    this.truncated = false,
  });

  static const int maxRows = 20;
  static const int maxColumns = 6;

  final List<String> columns;
  final List<List<String>> rows;
  final bool truncated;

  static _TableData? from(dynamic data) {
    if (data is! List || data.isEmpty) return null;

    final objects = <Map>[];
    for (final item in data) {
      if (item is Map) objects.add(item);
    }
    if (objects.isEmpty) {
      // Primitive list — single column table.
      final rows = <List<String>>[];
      for (var i = 0; i < data.length && i < maxRows; i++) {
        rows.add([data[i]?.toString() ?? '']);
      }
      return _TableData(
        columns: const ['Value'],
        rows: rows,
        truncated: data.length > maxRows,
      );
    }

    // Union of keys (order preserved from first occurrence).
    final keys = <String>[];
    for (final object in objects) {
      for (final key in object.keys) {
        if (!keys.contains(key.toString()) && keys.length < maxColumns) {
          keys.add(key.toString());
        }
      }
      if (keys.length >= maxColumns) break;
    }

    final rows = <List<String>>[];
    for (var i = 0; i < objects.length && i < maxRows; i++) {
      final object = objects[i];
      rows.add([for (final key in keys) object[key]?.toString() ?? '']);
    }

    return _TableData(
      columns: keys,
      rows: rows,
      truncated: objects.length > maxRows,
    );
  }
}

class _ReportNotFound extends StatelessWidget {
  const _ReportNotFound();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          const Text('Report not found.'),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(
              'Failed to load report\n$error',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
