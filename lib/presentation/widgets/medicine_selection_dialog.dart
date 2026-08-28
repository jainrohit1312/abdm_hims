import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

// -----------------------------------------------------------------------------
// Shared medicine constants (used by the dialog and the prescription form)
// -----------------------------------------------------------------------------

/// Doctor ke select karne ke liye frequency options (inline chips).
const List<String> medicineFrequencyOptions = [
  'OD',
  'BD',
  'TDS',
  'QID',
  'HS',
  'BBF',
  'SOS',
  'STAT',
];

/// Frequency choose karne par auto-set hone wala dosage.
const Map<String, String> autoDosageByFrequency = {
  'OD': '1-0-0',
  'BD': '1-0-1',
  'TDS': '1-1-1',
  'QID': '1-1-1-1',
};

/// Duration ke quick options (inline dropdown).
const List<String> medicineDurationOptions = [
  '3 Days',
  '5 Days',
  '7 Days',
  '10 Days',
  '14 Days',
  '1 Month',
  'Custom',
];

/// Route options (unified prescription medicine structure).
const List<String> medicineRouteOptions = [
  'Oral',
  'IV',
  'IM',
  'SC',
  'Topical',
  'Inhalation',
  'Ophthalmic',
  'Otic',
  'Nasal',
  'Rectal',
  'Vaginal',
  'Sublingual',
  'Other',
];

/// Frequency ka human-readable description.
String medicineFrequencyDescription(String frequency) {
  switch (frequency.toLowerCase()) {
    case 'od':
      return 'Once a day';
    case 'bd':
      return 'Twice a day';
    case 'tds':
      return 'Three times a day';
    case 'qid':
      return 'Four times a day';
    case 'hs':
      return 'At bedtime';
    case 'bbf':
      return 'Before breakfast';
    case 'sos':
      return 'As needed';
    case 'stat':
      return 'Immediately';
    default:
      return '';
  }
}

/// Signature of the callback invoked every time the doctor taps
/// "Add & Continue" inside the popup. The map carries all fields required by
/// the prescription save flow:
/// medicine_name, generic_name, strength, dosage, frequency, duration,
/// instructions, custom_times.
typedef MedicineAddedCallback = void Function(Map<String, dynamic> medicine);

// -----------------------------------------------------------------------------
// Medicine selection popup
//
// Stays open after each addition so the doctor can keep adding medicines.
// The prescription list behind the dialog updates in real time through
// [MedicineAddedCallback]. "Done" (समाप्त) is the only button that closes it.
// -----------------------------------------------------------------------------

class MedicineSelectionDialog extends ConsumerStatefulWidget {
  const MedicineSelectionDialog({super.key, required this.onMedicineAdded});

  /// Called for every medicine added during this popup session.
  final MedicineAddedCallback onMedicineAdded;

  @override
  ConsumerState<MedicineSelectionDialog> createState() =>
      _MedicineSelectionDialogState();
}

class _MedicineSelectionDialogState
    extends ConsumerState<MedicineSelectionDialog> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  final _dosageController = TextEditingController(text: '1-0-0');
  final _customDurationController = TextEditingController();
  final _instructionsController = TextEditingController();

  Timer? _debounce;
  Timer? _successTimer;
  String _debouncedQuery = '';

  Map<String, dynamic>? _selectedMedicine;
  String _frequency = 'OD';
  String _duration = '5 Days';
  String _route = 'Oral';

  /// Medicines added during the current popup session.
  int _sessionAddedCount = 0;
  String? _lastAddedMessage;

  @override
  void initState() {
    super.initState();
    // Search field par focus le aao taaki doctor seedha type kar sake.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _successTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _dosageController.dispose();
    _customDurationController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      setState(() => _debouncedQuery = '');
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _debouncedQuery = query);
    });
  }

  void _clearSearch() {
    _debounce?.cancel();
    setState(() => _debouncedQuery = '');
  }

  // ---------------------------------------------------------------------------
  // Selection + form
  // ---------------------------------------------------------------------------

  void _onMedicinePicked(Map<String, dynamic> medicine) {
    _debounce?.cancel();
    setState(() {
      _selectedMedicine = medicine;
      _lastAddedMessage = null;

      // Form defaults reset for the newly picked medicine.
      _frequency = 'OD';
      _duration = '5 Days';
      _route = 'Oral';
      _dosageController.text = autoDosageByFrequency['OD'] ?? '1-0-0';
      _customDurationController.clear();
      _instructionsController.clear();

      // Search clear kar do — selected medicine neeche wale form card mein
      // dikh jata hai aur doctor seedha agla medicine search kar sakta hai.
      _debouncedQuery = '';
      _searchController.clear();
    });
  }

  void _selectFrequency(String frequency) {
    setState(() {
      _frequency = frequency;
      final autoDosage = autoDosageByFrequency[frequency];
      if (autoDosage != null) {
        _dosageController.text = autoDosage;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Add & Continue / Done
  // ---------------------------------------------------------------------------

  String get _resolvedDuration =>
      _duration == 'Custom' ? _customDurationController.text.trim() : _duration;

  void _addAndContinue() {
    final selected = _selectedMedicine;
    if (selected == null) {
      _showMessage('Select a medicine from the search results first.');
      return;
    }

    final dosage = _dosageController.text.trim();
    if (dosage.isEmpty) {
      _showMessage('Please enter the dosage.');
      return;
    }

    final duration = _resolvedDuration;
    if (duration.isEmpty) {
      _showMessage('Please enter the duration.');
      return;
    }

    final medicineName = selected['medicine_name']?.toString() ?? 'Medicine';
    final draft = <String, dynamic>{
      'medicine_name': medicineName,
      'generic_name': selected['generic_name']?.toString(),
      'strength': selected['strength']?.toString(),
      'dosage': dosage,
      'frequency': _frequency,
      'duration': duration,
      'route': _route,
      'instructions': _instructionsController.text.trim(),
      'custom_times': const <String>[],
    };

    // Parent prescription list isi waqt update hoti hai (popup ke peeche).
    widget.onMedicineAdded(draft);

    setState(() {
      _sessionAddedCount++;
      _lastAddedMessage = 'Added: $medicineName ($dosage • $_frequency • $duration)';
    });

    _successTimer?.cancel();
    _successTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _lastAddedMessage = null);
    });

    // Optional toast — popup ke peeche visible hota hai.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$medicineName added to prescription'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );

    _resetFormForNextMedicine();
  }

  /// Add ke baad form blank/default ho jata hai, popup khula rehta hai.
  void _resetFormForNextMedicine() {
    _debounce?.cancel();
    setState(() {
      _debouncedQuery = '';
      _selectedMedicine = null;
      _frequency = 'OD';
      _duration = '5 Days';
      _route = 'Oral';
      _dosageController.text = autoDosageByFrequency['OD'] ?? '1-0-0';
      _customDurationController.clear();
      _instructionsController.clear();
      _searchController.clear();
    });
    _searchFocusNode.requestFocus();
  }

  void _done() {
    Navigator.of(context).pop();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _medicineDisplay(Map<String, dynamic> medicine) {
    final name = medicine['medicine_name']?.toString() ?? 'Medicine';
    final strength = medicine['strength']?.toString() ?? '';
    return strength.isEmpty ? name : '$name ($strength)';
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    final searchAsync = _debouncedQuery.length >= 2
        ? ref.watch(
            medicineSearchProvider(
              MedicineSearchParams(
                query: _debouncedQuery,
                hospitalId: hospitalId,
              ),
            ),
          )
        : null;

    final medicinesCacheAsync = ref.watch(medicinesCacheProvider(hospitalId));
    final suggestions =
        searchAsync?.valueOrNull ?? const <Map<String, dynamic>>[];

    return Dialog(
      // Slightly translucent surface — peeche ki prescription list jhalakti
      // rehti hai jab doctor popup ke andar medicines add karta hai.
      backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.97),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height * 0.88,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(theme),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSearchField(theme, suggestions),
                    const SizedBox(height: 8),
                    if (_debouncedQuery.length >= 2)
                      ..._searchStatus(searchAsync)
                    else
                      _buildAllMedicinesList(theme, medicinesCacheAsync),
                    if (_selectedMedicine != null) ...[
                      const SizedBox(height: 12),
                      _buildSelectedMedicineForm(theme),
                    ],
                  ],
                ),
              ),
            ),
            if (_lastAddedMessage != null) _buildSuccessBanner(theme),
            const Divider(height: 1),
            _buildActions(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Icon(
              Icons.medication,
              size: 20,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add Medicine',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Search, set dose and keep adding',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (_sessionAddedCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$_sessionAddedCount '
                '${_sessionAddedCount == 1 ? 'medicine' : 'medicines'} added',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchField(
    ThemeData theme,
    List<Map<String, dynamic>> suggestions,
  ) {
    return RawAutocomplete<Map<String, dynamic>>(
      textEditingController: _searchController,
      focusNode: _searchFocusNode,
      displayStringForOption: _medicineDisplay,
      onSelected: _onMedicinePicked,
      optionsBuilder: (textEditingValue) {
        final query = textEditingValue.text.trim();
        if (query.length < 2) {
          return const Iterable<Map<String, dynamic>>.empty();
        }
        final lowerQuery = query.toLowerCase();
        // Server se aaye suggestions ko current text ke saath locally bhi
        // filter karo taaki stale suggestions na dikhein.
        return suggestions.where((medicine) {
          final name =
              medicine['medicine_name']?.toString().toLowerCase() ?? '';
          final generic =
              medicine['generic_name']?.toString().toLowerCase() ?? '';
          final brand =
              medicine['brand_name']?.toString().toLowerCase() ?? '';
          return name.contains(lowerQuery) ||
              generic.contains(lowerQuery) ||
              brand.contains(lowerQuery);
        });
      },
      fieldViewBuilder: (context, controller, focusNode, _) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: _onSearchChanged,
          decoration: InputDecoration(
            hintText: 'Type medicine / generic / brand name...',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear search',
                  onPressed: () {
                    controller.clear();
                    _clearSearch();
                  },
                );
              },
            ),
                      ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
                for (final medicine in options)
                  ListTile(
                    leading: CircleAvatar(
                      radius: 18,
                      backgroundColor: theme.colorScheme.secondaryContainer,
                      child: Icon(
                        Icons.medication,
                        size: 18,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                    title: Text(
                      medicine['medicine_name']?.toString() ?? 'Medicine',
                    ),
                    subtitle: Text(
                      [
                        if (medicine['strength'] != null)
                          medicine['strength'].toString(),
                        if (medicine['generic_name'] != null)
                          medicine['generic_name'].toString(),
                        if (medicine['brand_name'] != null)
                          medicine['brand_name'].toString(),
                      ].join(' • '),
                    ),
                    onTap: () => onSelected(medicine),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _searchStatus(
    AsyncValue<List<Map<String, dynamic>>>? searchAsync,
  ) {
    if (searchAsync == null) return const <Widget>[];

    if (searchAsync.isLoading && !searchAsync.hasValue) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ];
    }

    if (searchAsync.hasError) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('Search failed: ${searchAsync.error}'),
        ),
      ];
    }

    final results = searchAsync.valueOrNull ?? const <Map<String, dynamic>>[];
    if (results.isEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              const Icon(Icons.search_off, color: Colors.grey),
              const SizedBox(height: 4),
              const Text('No medicines found.'),
            ],
          ),
        ),
      ];
    }

    return const <Widget>[];
  }

  Widget _buildAllMedicinesList(
    ThemeData theme,
    AsyncValue<List<Map<String, dynamic>>> medicinesCacheAsync,
  ) {
    return medicinesCacheAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('Medicines list failed to load: $error'),
      ),
      data: (medicines) {
        final sorted = List<Map<String, dynamic>>.of(medicines)
          ..sort((a, b) {
            final aName =
                a['medicine_name']?.toString().toLowerCase().trim() ?? '';
            final bName =
                b['medicine_name']?.toString().toLowerCase().trim() ?? '';
            return aName.compareTo(bName);
          });

        if (sorted.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No medicines in hospital inventory yet.'),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                'Hospital Medicines (${sorted.length}) — tap to select',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: sorted.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final medicine = sorted[index];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 18,
                      backgroundColor: theme.colorScheme.secondaryContainer,
                      child: Icon(
                        Icons.medication,
                        size: 18,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                    title: Text(
                      medicine['medicine_name']?.toString() ?? 'Medicine',
                    ),
                    subtitle: Text(
                      [
                        if (medicine['strength'] != null)
                          medicine['strength'].toString(),
                        if (medicine['generic_name'] != null)
                          medicine['generic_name'].toString(),
                      ].join(' • '),
                    ),
                    onTap: () => _onMedicinePicked(medicine),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSelectedMedicineForm(ThemeData theme) {
    final medicine = _selectedMedicine!;
    final name = medicine['medicine_name']?.toString() ?? 'Medicine';
    final strength = medicine['strength']?.toString() ?? '';
    final title = strength.isEmpty ? name : '$name ($strength)';
    final descriptionParts = <String>[
      if (medicine['generic_name'] != null &&
          medicine['generic_name'].toString().isNotEmpty)
        medicine['generic_name'].toString(),
      medicineFrequencyDescription(_frequency),
    ]..removeWhere((part) => part.isEmpty);

    return Card(
      elevation: 0,
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: theme.colorScheme.primary.withValues(alpha: 0.4),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: theme.colorScheme.primary,
                  child: Icon(
                    Icons.medication,
                    size: 18,
                    color: theme.colorScheme.onPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (descriptionParts.isNotEmpty)
                        Text(
                          descriptionParts.join(' • '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Frequency',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final frequency in medicineFrequencyOptions)
                  ChoiceChip(
                    label: Text(frequency),
                    selected: _frequency == frequency,
                    onSelected: (_) => _selectFrequency(frequency),
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: _frequency == frequency
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _dosageController,
                    decoration: InputDecoration(
                      labelText: 'Dosage',
                      hintText: '1-0-1',
                                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('dialog_duration_$_duration'),
                    initialValue: medicineDurationOptions.contains(_duration)
                        ? _duration
                        : 'Custom',
                    decoration: InputDecoration(
                      labelText: 'Duration',
                                          ),
                    items: medicineDurationOptions
                        .map(
                          (duration) => DropdownMenuItem(
                            value: duration,
                            child: Text(
                              duration == 'Custom' ? 'Custom…' : duration,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _duration = value;
                      });
                    },
                  ),
                ),
              ],
            ),
            if (_duration == 'Custom') ...[
              const SizedBox(height: 10),
              TextFormField(
                controller: _customDurationController,
                decoration: InputDecoration(
                  labelText: 'Custom Duration',
                  hintText: 'e.g. 21 Days / 2 Weeks / 6 Months',
                                  ),
              ),
            ],
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: ValueKey('dialog_route_$_route'),
              initialValue: _route,
              decoration: InputDecoration(
                labelText: 'Route',
                              ),
              items: medicineRouteOptions
                  .map(
                    (route) => DropdownMenuItem(
                      value: route,
                      child: Text(route),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() => _route = value);
              },
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _instructionsController,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Instructions',
                hintText: 'e.g. With water, After food',
                alignLabelWithHint: true,
                              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuccessBanner(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.colorScheme.tertiaryContainer,
      child: Row(
        children: [
          Icon(
            Icons.check_circle,
            size: 18,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _lastAddedMessage ?? '',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _done,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Done (समाप्त)'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: FilledButton.icon(
              onPressed: _addAndContinue,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Add & Continue (और जोड़ें)'),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Add New Medicine dialog (hospital inventory master)
// -----------------------------------------------------------------------------

class AddNewMedicineDialog extends ConsumerStatefulWidget {
  const AddNewMedicineDialog({super.key});

  @override
  ConsumerState<AddNewMedicineDialog> createState() =>
      _AddNewMedicineDialogState();
}

class _AddNewMedicineDialogState extends ConsumerState<AddNewMedicineDialog> {
  final _formKey = GlobalKey<FormState>();
  final _medicineNameController = TextEditingController();
  final _genericNameController = TextEditingController();
  final _brandNameController = TextEditingController();
  final _strengthController = TextEditingController();

  bool _isSaving = false;

  @override
  void dispose() {
    _medicineNameController.dispose();
    _genericNameController.dispose();
    _brandNameController.dispose();
    _strengthController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add New Medicine'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _medicineNameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Medicine Name *'),
                validator: (value) =>
                    value?.trim().isEmpty == true ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _genericNameController,
                decoration: const InputDecoration(labelText: 'Generic Name'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _brandNameController,
                decoration: const InputDecoration(labelText: 'Brand Name'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _strengthController,
                decoration: const InputDecoration(
                  labelText: 'Strength',
                  hintText: 'e.g. 500mg',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _isSaving ? null : _save,
          icon: _isSaving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save, size: 18),
          label: const Text('Save Medicine'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isSaving = true);

    try {
      final db = ref.read(databaseServiceProvider);
      final hospitalId = ref.read(authStateProvider).hospitalId;

      final created = await db.addNewMedicine({
        'hospital_id': hospitalId,
        'medicine_name': _medicineNameController.text.trim(),
        'generic_name': _genericNameController.text.trim().isEmpty
            ? null
            : _genericNameController.text.trim(),
        'brand_name': _brandNameController.text.trim().isEmpty
            ? null
            : _brandNameController.text.trim(),
        'strength': _strengthController.text.trim().isEmpty
            ? null
            : _strengthController.text.trim(),
      });

      if (!mounted) return;
      Navigator.pop(context, created);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to add medicine: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}
