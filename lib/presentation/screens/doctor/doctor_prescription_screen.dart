import 'package:flutter/material.dart';

import '../../widgets/prescription_clinical_fields.dart';
import '../../widgets/prescription_form.dart';
import '../../widgets/smart_navigation.dart';

/// Doctor e-prescription screen (full-screen mode).
///
/// Can be opened directly from OPD consultation:
///   context.push('/doctor/prescription?opdRegistrationId=...')
/// or from an IPD admission:
///   context.push('/doctor/prescription?patientId=...&ipdAdmissionId=...')
///
/// Is mode mein bhi ab poora prescription form hai — History / Vitals /
/// Diagnosis / Medicines / Investigations / Advice / Follow-up — aur
/// [DoctorPrescriptionForm] clinical controller ke through sab ek saath save
/// karta hai. Embedded use OPD Consultation ke Prescription tab ke liye hai.
class DoctorPrescriptionScreen extends StatefulWidget {
  final String? patientId;
  final String? opdRegistrationId;
  final String? ipdAdmissionId;
  final String? patientName;
  final String? uhid;

  const DoctorPrescriptionScreen({
    super.key,
    this.patientId,
    this.opdRegistrationId,
    this.ipdAdmissionId,
    this.patientName,
    this.uhid,
  });

  @override
  State<DoctorPrescriptionScreen> createState() =>
      _DoctorPrescriptionScreenState();
}

class _DoctorPrescriptionScreenState extends State<DoctorPrescriptionScreen> {
  final _formKey = GlobalKey<DoctorPrescriptionFormState>();
  final _clinicalController = PrescriptionClinicalController();

  @override
  void dispose() {
    _clinicalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Doctor Prescription'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload patient',
            onPressed: () => _formKey.currentState?.reload(),
          ),
        ],
      ),
      body: DoctorPrescriptionForm(
        key: _formKey,
        patientId: widget.patientId,
        opdRegistrationId: widget.opdRegistrationId,
        ipdAdmissionId: widget.ipdAdmissionId,
        patientName: widget.patientName,
        uhid: widget.uhid,
        clinicalController: _clinicalController,
      ),
    );
  }
}
