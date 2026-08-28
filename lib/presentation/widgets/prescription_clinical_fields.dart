import 'package:flutter/material.dart';

/// Prescription ke clinical sections (History / Investigations / Advice) ka
/// shared controller.
///
/// Unified Prescription Module ke structure ke according data collect karta
/// hai:
///
///   history         = { chief_complaints, history_presenting_illness,
///                       past_history, personal_history, family_history,
///                       allergies, examination_findings, diagnosis, vitals }
///   investigations  = { lab_tests[], radiology[], other_investigations[] }
///   advice          = { follow_up_date, dietary_advice, activity_advice,
///                       other_advice }
///
/// OPD Consultation (tabs) aur standalone Doctor Prescription screen dono isi
/// controller + fields ka use karte hain. IPD prescription mein ye sections
/// use nahi hote (sirf medicines).
class PrescriptionClinicalController {
  // -- History ------------------------------------------------------------
  final chiefComplaints = TextEditingController();
  final historyPresentingIllness = TextEditingController();
  final pastHistory = TextEditingController();
  final personalHistory = TextEditingController();
  final familyHistory = TextEditingController();
  final allergies = TextEditingController();
  final examinationFindings = TextEditingController();
  final diagnosis = TextEditingController();

  // -- Vitals (history ke andar extra context) ----------------------------
  final bp = TextEditingController();
  final pulse = TextEditingController();
  final temp = TextEditingController();
  final spo2 = TextEditingController();
  final weight = TextEditingController();

  // -- Investigations ------------------------------------------------------
  final labOther = TextEditingController();
  final radiologyOther = TextEditingController();
  final otherInvestigations = TextEditingController();

  final Set<String> labTests = <String>{};
  final Set<String> radiology = <String>{};

  // -- Advice --------------------------------------------------------------
  final followUpDate = TextEditingController();
  final dietaryAdvice = TextEditingController();
  final activityAdvice = TextEditingController();
  final otherAdvice = TextEditingController();

  static const List<String> labTestOptions = [
    'CBC',
    'Blood Sugar',
    'HbA1c',
    'LFT',
    'KFT',
    'Lipid Profile',
    'Thyroid',
    'Urine Routine',
    'CRP',
    'ESR',
  ];

  static const List<String> radiologyInvestigationOptions = [
    'X-Ray',
    'USG',
    'CT Scan',
    'MRI',
    'ECG',
    'Echo',
  ];

  /// True jab koi bhi clinical detail bhari ho (OPD validation ke liye).
  bool get hasClinicalData {
    final sections = toUnifiedJson();
    return sections['history'] is Map &&
            (sections['history'] as Map).isNotEmpty ||
        sections['investigations'] is Map &&
            (sections['investigations'] as Map).isNotEmpty ||
        sections['advice'] is Map && (sections['advice'] as Map).isNotEmpty;
  }

  // ---------------------------------------------------------------------------
  // Serialisation
  // ---------------------------------------------------------------------------

  /// Unified module ke teen section maps: `history`, `investigations`,
  /// `advice`. Sirf bhare hue fields include hote hain.
  Map<String, dynamic> toUnifiedJson() {
    return {
      'history': _historyToJson(),
      'investigations': _investigationsToJson(),
      'advice': _adviceToJson(),
    };
  }

  Map<String, dynamic> _historyToJson() {
    final history = <String, dynamic>{};

    void put(String key, TextEditingController controller) {
      final text = controller.text.trim();
      if (text.isNotEmpty) history[key] = text;
    }

    put('chief_complaints', chiefComplaints);
    put('history_presenting_illness', historyPresentingIllness);
    put('past_history', pastHistory);
    put('personal_history', personalHistory);
    put('family_history', familyHistory);
    put('allergies', allergies);
    put('examination_findings', examinationFindings);
    put('diagnosis', diagnosis);

    final vitals = <String, dynamic>{};
    void putVital(String key, TextEditingController controller) {
      final text = controller.text.trim();
      if (text.isNotEmpty) vitals[key] = text;
    }

    putVital('bp', bp);
    putVital('pulse', pulse);
    putVital('temp', temp);
    putVital('spo2', spo2);
    putVital('weight', weight);
    if (vitals.isNotEmpty) history['vitals'] = vitals;

    return history;
  }

  Map<String, dynamic> _investigationsToJson() {
    final investigations = <String, dynamic>{};

    final labs = <String>[...labTests];
    final labOtherText = labOther.text.trim();
    if (labOtherText.isNotEmpty) {
      labs.addAll(_splitCommaSeparated(labOtherText));
    }
    if (labs.isNotEmpty) investigations['lab_tests'] = labs;

    final imaging = <String>[...radiology];
    final radiologyOtherText = radiologyOther.text.trim();
    if (radiologyOtherText.isNotEmpty) {
      imaging.addAll(_splitCommaSeparated(radiologyOtherText));
    }
    if (imaging.isNotEmpty) investigations['radiology'] = imaging;

    final others = _splitCommaSeparated(otherInvestigations.text.trim());
    if (others.isNotEmpty) investigations['other_investigations'] = others;

    return investigations;
  }

  Map<String, dynamic> _adviceToJson() {
    final advice = <String, dynamic>{};

    void put(String key, TextEditingController controller) {
      final text = controller.text.trim();
      if (text.isNotEmpty) advice[key] = text;
    }

    put('follow_up_date', followUpDate);
    put('dietary_advice', dietaryAdvice);
    put('activity_advice', activityAdvice);
    put('other_advice', otherAdvice);

    return advice;
  }

  /// Legacy `clinical_notes` map (backward compatibility for old prints and
  /// any older DB row). Unified `toUnifiedJson()` ko hi canonical source
  /// maano.
  Map<String, dynamic> toJson() {
    final notes = <String, dynamic>{};

    final history = _historyToJson();
    final investigations = _investigationsToJson();
    final advice = _adviceToJson();

    if (history.isNotEmpty) {
      notes['chief_complaints'] = history['chief_complaints'] ?? '';
      notes['hopi'] = history['history_presenting_illness'] ?? '';
      notes['past_history'] = history['past_history'] ?? '';
      notes['personal_family_history'] = [
        history['personal_history'] ?? '',
        history['family_history'] ?? '',
      ].where((e) => e.toString().trim().isNotEmpty).join(' • ');
      notes['drug_allergy'] = history['allergies'] ?? '';
      notes['examination'] = history['examination_findings'] ?? '';
      notes['diagnosis'] = history['diagnosis'] ?? '';
      notes['vitals'] = history['vitals'] ?? <String, dynamic>{};
    }

    if (investigations.isNotEmpty) {
      final legacyInvestigations = <String, dynamic>{};
      if ((investigations['lab_tests'] as List?)?.isNotEmpty == true) {
        legacyInvestigations['blood'] = investigations['lab_tests'];
      }
      if ((investigations['radiology'] as List?)?.isNotEmpty == true) {
        legacyInvestigations['radiology'] = investigations['radiology'];
      }
      if ((investigations['other_investigations'] as List?)?.isNotEmpty ==
          true) {
        legacyInvestigations['previous_findings'] =
            (investigations['other_investigations'] as List).join(', ');
      }
      if (legacyInvestigations.isNotEmpty) {
        notes['investigations'] = legacyInvestigations;
      }
    }

    if (advice.isNotEmpty) {
      notes['advice'] = [
        advice['dietary_advice'] ?? '',
        advice['activity_advice'] ?? '',
        advice['other_advice'] ?? '',
      ].where((e) => e.toString().trim().isNotEmpty).join(' • ');
      notes['follow_up'] = [
        advice['follow_up_date'] ?? '',
      ].where((e) => e.toString().trim().isNotEmpty).join(' • ');
    }

    return notes;
  }

  /// "CBC, LFT" jaise comma separated input ko clean list mein todta hai.
  List<String> _splitCommaSeparated(String input) {
    if (input.trim().isEmpty) return const [];
    return input
        .split(RegExp(r'[,\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  void dispose() {
    chiefComplaints.dispose();
    historyPresentingIllness.dispose();
    pastHistory.dispose();
    personalHistory.dispose();
    familyHistory.dispose();
    allergies.dispose();
    examinationFindings.dispose();
    diagnosis.dispose();
    bp.dispose();
    pulse.dispose();
    temp.dispose();
    spo2.dispose();
    weight.dispose();
    labOther.dispose();
    radiologyOther.dispose();
    otherInvestigations.dispose();
    followUpDate.dispose();
    dietaryAdvice.dispose();
    activityAdvice.dispose();
    otherAdvice.dispose();
  }
}

/// History / Vitals / Diagnosis sections (main flow + More History Options).
class PrescriptionHistoryFields extends StatelessWidget {
  final PrescriptionClinicalController controller;

  const PrescriptionHistoryFields({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Complaints & History', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                TextFormField(
                  controller: controller.chiefComplaints,
                  maxLines: 3,
                  decoration: _fieldDecoration(
                    'Chief Complaints (C/O)',
                    hint: 'e.g. Fever since 3 days, headache',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: controller.historyPresentingIllness,
                  maxLines: 3,
                  decoration: _fieldDecoration(
                    'History of Present Illness (HOPI)',
                    hint: 'Since when, progression, associated symptoms',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildVitalsCard(theme),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Provisional Diagnosis',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: controller.diagnosis,
                  maxLines: 2,
                  decoration: _fieldDecoration(
                    'Diagnosis',
                    hint: 'e.g. Acute pharyngitis',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const PageStorageKey('more-history-options'),
            title: const Text('More History Options'),
            subtitle: const Text(
              'Past / Personal / Family / Allergy / Examination — optional',
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: controller.pastHistory,
                      maxLines: 2,
                      decoration: _fieldDecoration(
                        'Past History',
                        hint: 'DM / HTN / TB / Surgery / previous illness',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: controller.personalHistory,
                      maxLines: 2,
                      decoration: _fieldDecoration(
                        'Personal History',
                        hint: 'Diet, sleep, habits, occupation',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: controller.familyHistory,
                      maxLines: 2,
                      decoration: _fieldDecoration(
                        'Family History',
                        hint: 'Relevant illness in family',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: controller.allergies,
                      maxLines: 2,
                      decoration: _fieldDecoration(
                        'Allergies / Drug Reactions',
                        hint: 'Known drug/food allergies',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: controller.examinationFindings,
                      maxLines: 2,
                      decoration: _fieldDecoration(
                        'Examination Findings (G/E + Systemic)',
                        hint: 'Pallor, icterus, CVS, RS, CNS, local exam',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVitalsCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Vitals', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                _vitalField('BP', controller.bp, hint: '120/80'),
                const SizedBox(width: 8),
                _vitalField('Pulse', controller.pulse, hint: '72'),
                const SizedBox(width: 8),
                _vitalField('Temp', controller.temp, hint: '98.6'),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _vitalField('SpO₂', controller.spo2, hint: '98'),
                const SizedBox(width: 8),
                _vitalField('Weight', controller.weight, hint: '70 kg'),
                const Spacer(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _vitalField(
    String label,
    TextEditingController textController, {
    String? hint,
  }) {
    return Expanded(
      child: TextFormField(
        controller: textController,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }
}

/// Advice + Follow-up section (unified `advice` JSONB).
class PrescriptionAdviceFollowUpFields extends StatelessWidget {
  final PrescriptionClinicalController controller;

  const PrescriptionAdviceFollowUpFields({
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Advice & Follow-up', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextFormField(
              controller: controller.followUpDate,
              decoration: _fieldDecoration(
                'Follow-up Date',
                hint: 'e.g. After 5 days / 28-08-2026 / With reports',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller.dietaryAdvice,
              maxLines: 2,
              decoration: _fieldDecoration(
                'Dietary Advice',
                hint: 'Diet restrictions, fluids, nutrition',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller.activityAdvice,
              maxLines: 2,
              decoration: _fieldDecoration(
                'Activity Advice',
                hint: 'Rest, exercise, work restrictions',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller.otherAdvice,
              maxLines: 2,
              decoration: _fieldDecoration(
                'Other Advice',
                hint: 'Precautions, warning signs, hygiene',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Investigations section (lab + radiology chips + other investigations).
class PrescriptionInvestigationsFields extends StatefulWidget {
  final PrescriptionClinicalController controller;

  const PrescriptionInvestigationsFields({
    super.key,
    required this.controller,
  });

  @override
  State<PrescriptionInvestigationsFields> createState() =>
      _PrescriptionInvestigationsFieldsState();
}

class _PrescriptionInvestigationsFieldsState
    extends State<PrescriptionInvestigationsFields> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Lab Tests Advised',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                _buildChips(
                  controller.labTests,
                  PrescriptionClinicalController.labTestOptions,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: controller.labOther,
                  decoration: _fieldDecoration(
                    'Other lab tests',
                    hint: 'Any other test... (comma separated)',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Radiology / Imaging Advised',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                _buildChips(
                  controller.radiology,
                  PrescriptionClinicalController.radiologyInvestigationOptions,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: controller.radiologyOther,
                  decoration: _fieldDecoration(
                    'Other radiology / imaging',
                    hint: 'Any other imaging... (comma separated)',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Other Investigations',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: controller.otherInvestigations,
                  maxLines: 2,
                  decoration: _fieldDecoration(
                    'Other investigations',
                    hint: 'e.g. PFT, EEG, biopsy — comma separated',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChips(Set<String> selected, List<String> options) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final option in options)
          FilterChip(
            label: Text(option),
            selected: selected.contains(option),
            onSelected: (_) {
              setState(() {
                if (!selected.remove(option)) selected.add(option);
              });
            },
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

InputDecoration _fieldDecoration(String label, {String? hint}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
  );
}
