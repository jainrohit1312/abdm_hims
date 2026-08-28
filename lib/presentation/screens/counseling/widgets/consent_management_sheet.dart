import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:signature/signature.dart';

import '../../../../core/utils/pdf_font_helper.dart';
import '../../../../services/counseling_recording_service.dart';

/// Consent management bottom sheet.
///
/// * Auto-generated consent form (patient / UHID / hospital / doctor / date)
/// * Download PDF for physical signature
/// * Digital signature pad
/// * Upload signed consent via camera or gallery
/// * Status tracking (Pending / Signed / Expired) + version + timestamp
Future<void> showCounselingConsentSheet(
  BuildContext context, {
  required CounselingRecordingService recordingService,
  required String patientName,
  required String uhid,
  required String hospitalName,
  required String doctorName,
}) {
  final consent = recordingService.ensureConsent(
    patientName: patientName,
    uhid: uhid,
    hospitalName: hospitalName,
    doctorName: doctorName,
  );

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) =>
        _ConsentSheet(recordingService: recordingService, consent: consent),
  );
}

class _ConsentSheet extends ConsumerStatefulWidget {
  const _ConsentSheet({required this.recordingService, required this.consent});

  final CounselingRecordingService recordingService;
  final CounselingConsentDraft consent;

  @override
  ConsumerState<_ConsentSheet> createState() => _ConsentSheetState();
}

class _ConsentSheetState extends ConsumerState<_ConsentSheet> {
  final SignatureController _signatureController = SignatureController(
    penStrokeWidth: 3,
    penColor: Colors.black,
    exportBackgroundColor: Colors.white,
  );

  final ImagePicker _picker = ImagePicker();
  bool _isGeneratingPdf = false;
  bool _isPickingImage = false;

  CounselingConsentDraft get consent => widget.consent;
  CounselingRecordingService get service => widget.recordingService;

  @override
  void dispose() {
    _signatureController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateLabel = DateFormat('dd MMM yyyy').format(consent.generatedAt);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Row(
              children: [
                Icon(
                  Icons.fact_check_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Counseling Consent Form',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _ConsentStatusChip(status: consent.status),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Version ${consent.version} • Generated ${DateFormat('dd MMM yyyy, hh:mm a').format(consent.generatedAt)}',
              style: theme.textTheme.bodySmall,
            ),
            if (consent.signedAt != null)
              Text(
                'Signed ${DateFormat('dd MMM yyyy, hh:mm a').format(consent.signedAt!)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            const SizedBox(height: 16),

            // -- consent details -------------------------------------------------
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'INFORMED CONSENT FOR AUDIO/VIDEO COUNSELING RECORDING',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _ConsentField(
                      label: 'Patient Name',
                      value: consent.patientName,
                    ),
                    _ConsentField(label: 'UHID', value: consent.uhid),
                    _ConsentField(
                      label: 'Hospital',
                      value: consent.hospitalName,
                    ),
                    _ConsentField(label: 'Doctor', value: consent.doctorName),
                    _ConsentField(label: 'Date', value: dateLabel),
                    const SizedBox(height: 8),
                    Text(
                      'The patient has been informed that this counseling session '
                      'may be recorded (audio and/or video), that the recording is '
                      'stored securely and used only for clinical documentation, and '
                      'that GPS location is captured for session verification.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // -- actions ---------------------------------------------------------
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _isGeneratingPdf ? null : _downloadPdf,
                  icon: _isGeneratingPdf
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.picture_as_pdf),
                  label: Text(
                    _isGeneratingPdf ? 'Preparing...' : 'Download PDF',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _isPickingImage
                      ? null
                      : () => _pickSignedCopy(ImageSource.camera),
                  icon: _isPickingImage
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.camera_alt_outlined),
                  label: const Text('Upload Signed (Camera)'),
                ),
                OutlinedButton.icon(
                  onPressed: _isPickingImage
                      ? null
                      : () => _pickSignedCopy(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Upload Signed (Gallery)'),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // -- digital signature pad ------------------------------------------
            Text(
              'Digital Signature',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outline),
                borderRadius: BorderRadius.circular(12),
                color: Colors.white,
              ),
              clipBehavior: Clip.antiAlias,
              child: Signature(
                controller: _signatureController,
                height: 180,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => _signatureController.clear(),
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: const Text('Clear'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () async {
                    if (_signatureController.isEmpty) {
                      _toast('Please draw a signature first.', isError: true);
                      return;
                    }
                    final png = await _signatureController.toPngBytes();
                    if (png == null) {
                      _toast('Could not export signature.', isError: true);
                      return;
                    }
                    setState(() {});
                    service.markConsentSigned(signaturePng: png);
                    _toast('Consent signed digitally (v${consent.version}).');
                  },
                  icon: const Icon(Icons.draw_outlined),
                  label: const Text('Sign Consent'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // -- signed preview --------------------------------------------------
            if (consent.signaturePng != null || consent.signedImagePath != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Signed Copy',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (consent.signaturePng != null)
                        Image.memory(consent.signaturePng!, height: 120),
                      if (consent.signedImagePath != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Uploaded: ${consent.signedImagePath!.split('/').last}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _downloadPdf() async {
    setState(() => _isGeneratingPdf = true);
    try {
      final bytes = await _buildConsentPdf();
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name:
            'counseling_consent_${consent.patientName}_v${consent.version}.pdf',
      );
    } catch (e) {
      _toast('PDF failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isGeneratingPdf = false);
    }
  }

  Future<Uint8List> _buildConsentPdf() async {
    await PDFFontHelper.loadFonts();

    final pdf = pw.Document();
    final dateLabel = DateFormat('dd MMM yyyy').format(consent.generatedAt);

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) => pw.Padding(
          padding: const pw.EdgeInsets.all(40),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Center(
                child: PDFFontHelper.text(
                  consent.hospitalName.isEmpty
                      ? 'Hospital'
                      : consent.hospitalName,
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 8),
              pw.Center(
                child: PDFFontHelper.text(
                  'INFORMED CONSENT FOR AUDIO/VIDEO COUNSELING RECORDING',
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 24),
              _pdfField('Patient Name', consent.patientName),
              _pdfField('UHID', consent.uhid),
              _pdfField('Hospital', consent.hospitalName),
              _pdfField('Doctor', consent.doctorName),
              _pdfField('Date', dateLabel),
              pw.SizedBox(height: 24),
              PDFFontHelper.text(
                'The patient has been informed that this counseling session '
                'may be recorded (audio and/or video), that the recording is '
                'stored securely and used only for clinical documentation, and '
                'that GPS location is captured for session verification.',
                fontSize: 11,
              ),
              pw.SizedBox(height: 40),
              PDFFontHelper.text(
                'Patient / Guardian Signature: ___________________________',
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
              ),
              pw.SizedBox(height: 24),
              PDFFontHelper.text(
                'Doctor Signature: ___________________________    Date: _____________',
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
              ),
              pw.SizedBox(height: 24),
              if (consent.signaturePng != null) ...[
                PDFFontHelper.text(
                  'Digital Signature (v${consent.version}):',
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                ),
                pw.SizedBox(height: 8),
                pw.Image(pw.MemoryImage(consent.signaturePng!), height: 90),
              ],
            ],
          ),
        ),
      ),
    );

    return pdf.save();
  }

  pw.Widget _pdfField(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 120,
            child: PDFFontHelper.text(
              '$label:',
              fontSize: 11,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.Expanded(
            child: PDFFontHelper.text(
              value.isEmpty ? 'N/A' : value,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickSignedCopy(ImageSource source) async {
    setState(() => _isPickingImage = true);
    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: 80,
        maxWidth: 1600,
      );
      if (picked == null) return;
      service.markConsentSigned(signedImagePath: picked.path);
      _toast('Signed consent uploaded (v${consent.version}).');
    } catch (e) {
      _toast('Could not upload signed copy: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isPickingImage = false);
    }
  }

  void _toast(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}

class _ConsentField extends StatelessWidget {
  const _ConsentField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              '$label:',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? 'N/A' : value,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConsentStatusChip extends StatelessWidget {
  const _ConsentStatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, icon) = switch (status) {
      'signed' => (Colors.green, Icons.check_circle),
      'expired' => (theme.colorScheme.error, Icons.timer_off_outlined),
      _ => (Colors.orange, Icons.pending_outlined),
    };
    return Chip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(status.toUpperCase()),
      labelStyle: theme.textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.bold,
      ),
      visualDensity: VisualDensity.compact,
    );
  }
}
