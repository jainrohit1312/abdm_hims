import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../widgets/app_page_content.dart';
import '../../widgets/smart_navigation.dart';

/// Voucher Settings screen (`/vouchers/settings`).
///
/// * Manage custom voucher expense categories (`voucher_categories`).
/// * Set the approval authority name + limit (`voucher_settings`).
class VoucherSettingsScreen extends ConsumerStatefulWidget {
  const VoucherSettingsScreen({super.key});

  @override
  ConsumerState<VoucherSettingsScreen> createState() =>
      _VoucherSettingsScreenState();
}

class _VoucherSettingsScreenState extends ConsumerState<VoucherSettingsScreen> {
  final _approverController = TextEditingController();
  final _limitController = TextEditingController();
  bool _settingsLoaded = false;
  bool _savingSettings = false;

  @override
  void dispose() {
    _approverController.dispose();
    _limitController.dispose();
    super.dispose();
  }

  Future<void> _addCategory(String hospitalId) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add Custom Category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Category Name *',
            hintText: 'e.g. Generator Diesel',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isEmpty) return;
              Navigator.pop(dialogContext, value);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (name == null || !mounted) return;

    try {
      await ref
          .read(databaseServiceProvider)
          .createVoucherCategory(hospitalId: hospitalId, categoryName: name);
      _invalidateCategories(hospitalId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Category "$name" added')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to add category: $e')));
    }
  }

  Future<void> _toggleCategory(
    String hospitalId,
    Map<String, dynamic> category,
  ) async {
    final current = category['is_active'] != false;
    try {
      await ref
          .read(databaseServiceProvider)
          .setVoucherCategoryActive(category['id'].toString(), !current);
      _invalidateCategories(hospitalId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to update category: $e')));
    }
  }

  Future<void> _deleteCategory(
    String hospitalId,
    Map<String, dynamic> category,
  ) async {
    final name = category['category_name']?.toString() ?? 'Category';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Category'),
        content: Text('Delete "$name"? Existing vouchers keep their category.'),
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

    try {
      await ref
          .read(databaseServiceProvider)
          .deleteVoucherCategory(category['id'].toString());
      _invalidateCategories(hospitalId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Category deleted')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(content: Text('Failed to delete category: $e')),
      );
    }
  }

  Future<void> _saveApprovalSettings(String hospitalId) async {
    final name = _approverController.text.trim();
    final limit = double.tryParse(_limitController.text.trim());

    if (name.isEmpty) {
      _showMessage('Enter the approver name.');
      return;
    }
    if (limit == null || limit < 0) {
      _showMessage('Enter a valid approval limit.');
      return;
    }

    setState(() => _savingSettings = true);
    try {
      await ref
          .read(databaseServiceProvider)
          .saveVoucherSettings(
            hospitalId: hospitalId,
            approverName: name,
            approvalLimit: limit,
          );
      ref.invalidate(voucherSettingsProvider(hospitalId));
      if (!mounted) return;
      _showMessage('Approval settings saved.');
    } catch (e) {
      if (!mounted) return;
      _showMessage('Failed to save approval settings: $e');
    } finally {
      if (mounted) setState(() => _savingSettings = false);
    }
  }

  void _invalidateCategories(String hospitalId) {
    ref.invalidate(allVoucherCategoriesProvider(hospitalId));
    ref.invalidate(voucherCategoriesProvider(hospitalId));
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    if (hospitalId == null) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('Voucher Settings')),
        body: const Center(child: Text('Hospital not assigned to this user.')),
      );
    }

    final categoriesAsync = ref.watch(allVoucherCategoriesProvider(hospitalId));
    final settingsAsync = ref.watch(voucherSettingsProvider(hospitalId));

    // Fill the approval form once the stored settings arrive.
    ref.listen(voucherSettingsProvider(hospitalId), (previous, next) {
      next.whenData((settings) {
        if (settings == null || _settingsLoaded) return;
        _settingsLoaded = true;
        _approverController.text = settings['approver_name']?.toString() ?? '';
        final limit =
            double.tryParse(settings['approval_limit']?.toString() ?? '') ?? 0;
        _limitController.text = limit == 0 ? '' : limit.toStringAsFixed(2);
      });
    });

    return Scaffold(
      appBar: SmartAppBar(title: const Text('Voucher Settings')),
      body: AppPageListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader('Voucher Custom Categories'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Add your own expense categories',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Add category',
                        onPressed: () => _addCategory(hospitalId),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                  const Divider(height: 1),
                  categoriesAsync.when(
                    data: (categories) {
                      if (categories.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No custom categories yet.\nTap + to add one.',
                            textAlign: TextAlign.center,
                          ),
                        );
                      }
                      return Column(
                        children: [
                          for (final category in categories)
                            ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              title: Text(
                                category['category_name']?.toString() ?? '-',
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Switch(
                                    value: category['is_active'] != false,
                                    onChanged: (_) => _toggleCategory(
                                      hospitalId,
                                      category,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Delete',
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.red,
                                    ),
                                    onPressed: () => _deleteCategory(
                                      hospitalId,
                                      category,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                    loading: () => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (error, _) => Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text('Failed to load categories: $error'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          _sectionHeader('Approval Authority / Limits'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  settingsAsync.maybeWhen(
                    loading: () => const LinearProgressIndicator(),
                    orElse: () => const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _approverController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Approver Name *',
                      hintText: 'e.g. Dr. R. Sharma (Administrator)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _limitController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Approval Limit (₹) *',
                      prefixText: '₹ ',
                      hintText: 'Vouchers above this amount need approval',
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _savingSettings
                          ? null
                          : () => _saveApprovalSettings(hospitalId),
                      icon: _savingSettings
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(
                        _savingSettings ? 'Saving...' : 'Save Approval Settings',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
