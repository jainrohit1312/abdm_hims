import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../widgets/smart_navigation.dart';

/// Unified Lab / Diagnostics — Test Master screen.
///
/// Hospital admins can view, add, edit, activate/deactivate and delete all
/// diagnostic tests (Pathology, Radiology, Cardiology, Other).
class DiagnosticTestsMasterScreen extends ConsumerStatefulWidget {
  const DiagnosticTestsMasterScreen({super.key});

  @override
  ConsumerState<DiagnosticTestsMasterScreen> createState() =>
      _DiagnosticTestsMasterScreenState();
}

class _DiagnosticTestsMasterScreenState
    extends ConsumerState<DiagnosticTestsMasterScreen> {
  String _categoryFilter = 'all';
  bool _isMutating = false;

  static const Map<String, String> _categoryLabels = {
    'pathology': 'Pathology',
    'radiology': 'Radiology',
    'cardiology': 'Cardiology',
    'other': 'Other Diagnostics',
  };

  Future<void> _reload() async {
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId != null) {
      ref.invalidate(diagnosticTestsProvider(hospitalId));
    }
  }

  Future<void> _openForm({Map<String, dynamic>? test}) async {
    final saved = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _TestFormDialog(test: test),
    );
    if (saved == null || !mounted) return;

    setState(() => _isMutating = true);
    try {
      final db = ref.read(databaseServiceProvider);
      await db.saveDiagnosticTest(saved, id: test?['id']?.toString());
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            test == null
                ? 'Test added successfully'
                : 'Test updated successfully',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save test: $e')));
    } finally {
      if (mounted) setState(() => _isMutating = false);
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> test) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Test'),
        content: Text(
          'Delete "${test['test_name']}"? Existing order history will keep '
          'the test name but this master entry will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isMutating = true);
    try {
      final db = ref.read(databaseServiceProvider);
      await db.deleteDiagnosticTest(test['id'].toString());
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Test deleted')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to delete test: $e')));
    } finally {
      if (mounted) setState(() => _isMutating = false);
    }
  }

  Future<void> _toggleActive(Map<String, dynamic> test) async {
    final db = ref.read(databaseServiceProvider);
    final current = test['is_active'] == true;
    try {
      await db.setDiagnosticTestActive(test['id'].toString(), !current);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to update test: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    if (hospitalId == null) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('Diagnostic Tests Master')),
        body: const Center(child: Text('Hospital not assigned to this user.')),
      );
    }

    final testsAsync = ref.watch(diagnosticTestsProvider(hospitalId));

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Diagnostic Tests Master'),
        actions: [
          IconButton(
            tooltip: 'Add Test',
            onPressed: () => _openForm(),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isMutating ? null : () => _openForm(),
        icon: const Icon(Icons.add),
        label: const Text('Add Test'),
      ),
      body: Column(
        children: [
          _buildCategoryChips(),
          const Divider(height: 1),
          Expanded(
            child: testsAsync.when(
              data: (tests) {
                final filtered = _categoryFilter == 'all'
                    ? tests
                    : tests
                          .where(
                            (t) => t['category']?.toString() == _categoryFilter,
                          )
                          .toList();
                if (filtered.isEmpty) {
                  return const Center(child: Text('No tests found.'));
                }
                return RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) =>
                        _buildTestCard(filtered[index]),
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Failed to load tests: $error'),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _reload,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryChips() {
    final chips = ['all', ..._categoryLabels.keys];
    return SizedBox(
      height: 56,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        scrollDirection: Axis.horizontal,
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final category = chips[index];
          final label = category == 'all' ? 'All' : _categoryLabels[category]!;
          final selected = _categoryFilter == category;
          return FilterChip(
            label: Text(label),
            selected: selected,
            onSelected: (_) => setState(() => _categoryFilter = category),
          );
        },
      ),
    );
  }

  Widget _buildTestCard(Map<String, dynamic> test) {
    final category = test['category']?.toString() ?? 'other';
    final isActive = test['is_active'] == true;
    final price = double.tryParse(test['price']?.toString() ?? '') ?? 0;

    return Card(
      elevation: 1,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: _categoryColor(category).withValues(alpha: 0.15),
          child: Icon(
            _categoryIcon(category),
            color: _categoryColor(category),
            size: 20,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                test['test_name']?.toString() ?? '-',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '₹ ${price.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Code: ${test['test_code'] ?? '-'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                _smallChip(_categoryLabels[category] ?? category, _categoryColor(category)),
                if ((test['sample_type']?.toString() ?? '').isNotEmpty)
                  _smallChip(
                    test['sample_type'].toString(),
                    Colors.blueGrey,
                  ),
                _smallChip(
                  isActive ? 'Active' : 'Inactive',
                  isActive ? Colors.green : Colors.grey,
                ),
              ],
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            switch (value) {
              case 'edit':
                _openForm(test: test);
              case 'toggle':
                _toggleActive(test);
              case 'delete':
                _confirmDelete(test);
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'edit',
              child: ListTile(
                leading: Icon(Icons.edit_outlined),
                title: Text('Edit'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: 'toggle',
              child: ListTile(
                leading: Icon(
                  isActive ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                ),
                title: Text(isActive ? 'Deactivate' : 'Activate'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete_outline, color: Colors.red),
                title: Text('Delete', style: TextStyle(color: Colors.red)),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
        onTap: () => _openForm(test: test),
      ),
    );
  }

  Widget _smallChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }

  Color _categoryColor(String category) {
    switch (category) {
      case 'pathology':
        return Colors.purple;
      case 'radiology':
        return Colors.blue;
      case 'cardiology':
        return Colors.red;
      default:
        return Colors.teal;
    }
  }

  IconData _categoryIcon(String category) {
    switch (category) {
      case 'pathology':
        return Icons.biotech_outlined;
      case 'radiology':
        return Icons.image_search_outlined;
      case 'cardiology':
        return Icons.monitor_heart_outlined;
      default:
        return Icons.science_outlined;
    }
  }
}

// -----------------------------------------------------------------------------
// Add / Edit test dialog
// -----------------------------------------------------------------------------
class _TestFormDialog extends StatefulWidget {
  final Map<String, dynamic>? test;

  const _TestFormDialog({this.test});

  @override
  State<_TestFormDialog> createState() => _TestFormDialogState();
}

class _TestFormDialogState extends State<_TestFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _codeController;
  late final TextEditingController _sampleTypeController;
  late final TextEditingController _priceController;
  String _category = 'pathology';
  bool _isActive = true;
  bool _saving = false;

  bool get _isEditing => widget.test != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.test?['test_name']?.toString() ?? '',
    );
    _codeController = TextEditingController(
      text: widget.test?['test_code']?.toString() ?? '',
    );
    _sampleTypeController = TextEditingController(
      text: widget.test?['sample_type']?.toString() ?? '',
    );
    _priceController = TextEditingController(
      text: widget.test?['price']?.toString() ?? '',
    );
    _category = widget.test?['category']?.toString() ?? 'pathology';
    _isActive = widget.test?['is_active'] != false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    _sampleTypeController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    // Small delay so the dialog doesn't close before validation feedback.
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;

    Navigator.pop(
      context,
      {
        'test_name': _nameController.text.trim(),
        'test_code': _codeController.text.trim().toUpperCase(),
        'category': _category,
        'sample_type': _sampleTypeController.text.trim().isEmpty
            ? null
            : _sampleTypeController.text.trim(),
        'price': double.tryParse(_priceController.text.trim()) ?? 0,
        'is_active': _isActive,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEditing ? 'Edit Test' : 'Add Diagnostic Test'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Test Name *',
                    hintText: 'e.g. Complete Blood Count (CBC)',
                  ),
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? 'Test name is required'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _codeController,
                  decoration: const InputDecoration(
                    labelText: 'Test Code *',
                    hintText: 'e.g. CBC',
                  ),
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? 'Test code is required'
                      : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  decoration: const InputDecoration(labelText: 'Category *'),
                  items: const [
                    DropdownMenuItem(
                      value: 'pathology',
                      child: Text('Pathology'),
                    ),
                    DropdownMenuItem(
                      value: 'radiology',
                      child: Text('Radiology'),
                    ),
                    DropdownMenuItem(
                      value: 'cardiology',
                      child: Text('Cardiology'),
                    ),
                    DropdownMenuItem(
                      value: 'other',
                      child: Text('Other Diagnostics'),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => _category = value ?? 'pathology'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _sampleTypeController,
                  decoration: InputDecoration(
                    labelText: 'Sample Type',
                    hintText: _category == 'pathology'
                        ? 'e.g. Whole Blood, Serum, Urine'
                        : 'Optional',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _priceController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Price (₹) *',
                    prefixText: '₹ ',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Price is required';
                    }
                    if (double.tryParse(value.trim()) == null) {
                      return 'Enter a valid number';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  subtitle: const Text(
                    'Inactive tests are hidden from ordering',
                  ),
                  value: _isActive,
                  onChanged: (value) => setState(() => _isActive = value),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_isEditing ? 'Update' : 'Add'),
        ),
      ],
    );
  }
}
