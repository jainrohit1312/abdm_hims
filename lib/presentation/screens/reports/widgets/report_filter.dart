import 'package:flutter/material.dart';

/// Reports list ka filter bar — search field (clear button ke saath), report
/// type chips aur status chips.
///
/// Screens apne local state (search query / selected type / selected status)
/// ko is widget ke callbacks ke through sync rakhti hain.
class ReportFilterBar extends StatelessWidget {
  const ReportFilterBar({
    super.key,
    required this.searchController,
    required this.selectedType,
    required this.selectedStatus,
    required this.onSearchChanged,
    required this.onTypeChanged,
    required this.onStatusChanged,
  });

  final TextEditingController searchController;
  final String? selectedType;
  final String? selectedStatus;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String?> onTypeChanged;
  final ValueChanged<String?> onStatusChanged;

  static const List<String> reportTypes = [
    'consultation',
    'patient',
    'ipd',
    'diagnostic',
    'voucher',
    'counseling',
    'doctor_performance',
    'revenue',
    'followup',
  ];

  static const List<String> reportStatuses = ['ready', 'generating', 'failed'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: searchController,
              onChanged: onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search by title or type...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          searchController.clear();
                          onSearchChanged('');
                        },
                      ),
              ),
            ),
          ),
          _ChipRow(
            title: 'Report Type',
            chips: [null, ...reportTypes],
            selected: selectedType,
            labelFor: _typeLabel,
            onSelected: onTypeChanged,
          ),
          _ChipRow(
            title: 'Status',
            chips: [null, ...reportStatuses],
            selected: selectedStatus,
            labelFor: _statusLabel,
            onSelected: onStatusChanged,
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  static String _typeLabel(String? value) {
    if (value == null) return 'All';
    switch (value) {
      case 'consultation':
        return 'Consultation';
      case 'patient':
        return 'Patient';
      case 'ipd':
        return 'IPD';
      case 'diagnostic':
        return 'Diagnostics';
      case 'voucher':
        return 'Voucher';
      case 'counseling':
        return 'Counseling';
      case 'doctor_performance':
        return 'Doctor Performance';
      case 'revenue':
        return 'Revenue';
      case 'followup':
        return 'Follow-up';
      default:
        return value;
    }
  }

  static String _statusLabel(String? value) {
    if (value == null) return 'All';
    switch (value) {
      case 'ready':
        return 'Ready';
      case 'generating':
        return 'Generating';
      case 'failed':
        return 'Failed';
      default:
        return value;
    }
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.title,
    required this.chips,
    required this.selected,
    required this.labelFor,
    required this.onSelected,
  });

  final String title;
  final List<String?> chips;
  final String? selected;
  final String Function(String?) labelFor;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              title,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final chip in chips) ...[
                  ChoiceChip(
                    label: Text(labelFor(chip)),
                    selected: selected == chip,
                    onSelected: (_) => onSelected(chip),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
