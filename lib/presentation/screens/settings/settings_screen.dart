import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../widgets/smart_navigation.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: SmartAppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          _buildSectionHeader('Appearance', theme),
          SwitchListTile(
            title: const Text('Dark Mode'),
            subtitle: const Text('Toggle dark/light theme'),
            value: themeMode == ThemeMode.dark,
            onChanged: (value) {
              ref.read(themeModeProvider.notifier).state = value
                  ? ThemeMode.dark
                  : ThemeMode.light;
            },
          ),
          const Divider(),
          _buildSectionHeader('Account', theme),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Profile'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {},
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Change Password'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              _showChangePasswordDialog(context);
            },
          ),
          const Divider(),
          _buildSectionHeader('Hospital Info', theme),
          ListTile(
            leading: const Icon(Icons.local_hospital),
            title: const Text('Hospital Details'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {},
          ),
          ListTile(
            leading: const Icon(Icons.group),
            title: const Text('User Management'),
            subtitle: const Text('Admins, Doctors, Nurses, Staff...'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/users'),
          ),
          ListTile(
            leading: const Icon(Icons.workspace_premium_outlined),
            title: const Text('Subscription'),
            subtitle: const Text('Trial status, plans & renewals'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/subscription'),
          ),
          const Divider(),
          _buildSectionHeader('OPD Prescription Settings', theme),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Prescription Mode'),
            subtitle: const Text(
              'Doctor-wise: Printed Prescription (Yes) ya Direct OPD (No)',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showPrescriptionModeDialog(context),
          ),
          const Divider(),
          _buildSectionHeader('Lab / Diagnostics Masters', theme),
          ListTile(
            leading: const Icon(Icons.biotech_outlined),
            title: const Text('Diagnostic Tests Master'),
            subtitle: const Text(
              'Pathology, Radiology, Cardiology & Other test prices',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/diagnostics/tests'),
          ),
          const Divider(),
          _buildSectionHeader('IPD Billing Masters', theme),
          ListTile(
            leading: const Icon(Icons.meeting_room_outlined),
            title: const Text('Ward Pricing'),
            subtitle: const Text('Daily room rate per ward type'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showWardPricingDialog(context),
          ),
          ListTile(
            leading: const Icon(Icons.miscellaneous_services_outlined),
            title: const Text('Service Master'),
            subtitle: const Text(
              'Custom IPD services (Sitting, Dressing, Diet...)',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showServiceMasterDialog(context),
          ),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('Package Master'),
            subtitle: const Text(
              'Operation packages (Appendectomy, C-Section...)',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showPackageMasterDialog(context),
          ),
          const Divider(),
          _buildSectionHeader('WhatsApp Marketing', theme),
          ListTile(
            leading: const Icon(Icons.chat_outlined),
            title: const Text('WhatsApp Dashboard'),
            subtitle: const Text('Campaign analytics & message funnel'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/whatsapp'),
          ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('WhatsApp API Settings'),
            subtitle: const Text('Meta WhatsApp Cloud API keys (per hospital)'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/whatsapp/settings'),
          ),
          ListTile(
            leading: const Icon(Icons.message_outlined),
            title: const Text('Message Templates'),
            subtitle: const Text('Pre-approved Meta templates'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/whatsapp/templates'),
          ),
          ListTile(
            leading: const Icon(Icons.campaign_outlined),
            title: const Text('Broadcast Campaigns'),
            subtitle: const Text('Send & schedule WhatsApp broadcasts'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/whatsapp/campaigns'),
          ),
          ListTile(
            leading: const Icon(Icons.block_outlined),
            title: const Text('WhatsApp Opt-Outs'),
            subtitle: const Text('Manage patient DND list'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/whatsapp/opt-outs'),
          ),
          const Divider(),
          _buildSectionHeader('Data & Sync', theme),
          ListTile(
            leading: const Icon(Icons.cloud_sync),
            title: const Text('Sync Data'),
            subtitle: const Text('Last synced: Today, 10:30 AM'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {},
          ),
          ListTile(
            leading: const Icon(Icons.backup),
            title: const Text('Backup & Restore'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {},
          ),
          const Divider(),
          _buildSectionHeader('About', theme),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About HIMS'),
            subtitle: const Text('Version 1.0.0'),
            onTap: () {
              showAboutDialog(
                context: context,
                applicationName: 'HIMS',
                applicationVersion: '1.0.0',
                applicationLegalese:
                    '© 2024 HIMS - Hospital Information Management System',
              );
            },
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Logout'),
                    content: const Text('Are you sure you want to logout?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                          ref.read(authStateProvider.notifier).logout();
                          context.go('/login');
                        },
                        child: const Text(
                          'Logout',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                );
              },
              icon: const Icon(Icons.logout, color: Colors.red),
              label: const Text('Logout', style: TextStyle(color: Colors.red)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.red),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  void _showChangePasswordDialog(BuildContext context) {
    final currentPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change Password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: currentPasswordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current Password'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: newPasswordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New Password'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirmPasswordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Confirm New Password',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Password changed successfully!')),
              );
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Ward Pricing dialog
  // ---------------------------------------------------------------------------

  void _showWardPricingDialog(BuildContext context) {
    showDialog(context: context, builder: (_) => const _WardPricingDialog());
  }

  // ---------------------------------------------------------------------------
  // Service Master dialog
  // ---------------------------------------------------------------------------

  void _showServiceMasterDialog(BuildContext context) {
    showDialog(context: context, builder: (_) => const _ServiceMasterDialog());
  }

  // ---------------------------------------------------------------------------
  // Package Master dialog
  // ---------------------------------------------------------------------------

  void _showPackageMasterDialog(BuildContext context) {
    showDialog(context: context, builder: (_) => const _PackageMasterDialog());
  }

  // ---------------------------------------------------------------------------
  // Prescription Mode dialog (Smart OPD Workflow)
  // ---------------------------------------------------------------------------

  void _showPrescriptionModeDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const _PrescriptionModeDialog(),
    );
  }
}

// =============================================================================
// Ward Pricing Master (daily room rate per ward type)
// =============================================================================

class _WardPricingDialog extends ConsumerStatefulWidget {
  const _WardPricingDialog();

  @override
  ConsumerState<_WardPricingDialog> createState() => _WardPricingDialogState();
}

class _WardPricingDialogState extends ConsumerState<_WardPricingDialog> {
  @override
  Widget build(BuildContext context) {
    final pricingAsync = ref.watch(ipdWardPricingProvider);

    return AlertDialog(
      title: Row(
        children: [
          const Text('Ward Pricing'),
          const Spacer(),
          IconButton(
            tooltip: 'Add ward pricing',
            onPressed: () => _openPricingForm(),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 420,
        child: pricingAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) =>
              Center(child: Text('Failed to load ward pricing: $e')),
          data: (pricing) {
            if (pricing.isEmpty) {
              return const Center(
                child: Text(
                  'No ward pricing defined yet.\nTap + to add a daily rate.',
                  textAlign: TextAlign.center,
                ),
              );
            }
            return ListView.separated(
              itemCount: pricing.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final row = pricing[index];
                final wardType = row['ward_type']?.toString() ?? 'general';
                final rate = _toDouble(row['daily_rate']);
                final description = row['description']?.toString() ?? '';
                final isActive = row['is_active'] != false;
                return ListTile(
                  title: Text(_formatWardType(wardType)),
                  subtitle: Text(description.isEmpty ? wardType : description),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _inr(rate),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: () => _openPricingForm(row: row),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: Colors.red,
                        ),
                        onPressed: () => _deletePricing(row),
                      ),
                    ],
                  ),
                  enabled: isActive,
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Future<void> _openPricingForm({Map<String, dynamic>? row}) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _WardPricingFormDialog(row: row),
    );
    if (result == null) return;

    try {
      final db = ref.read(databaseServiceProvider);
      await db.saveIPDWardPricing(result, id: row?['id']?.toString());
      ref.invalidate(ipdWardPricingProvider);
    } catch (e) {
      _showMessage('Failed to save ward pricing: $e');
    }
  }

  Future<void> _deletePricing(Map<String, dynamic> row) async {
    final id = row['id']?.toString();
    if (id == null) return;
    try {
      final db = ref.read(databaseServiceProvider);
      await db.deleteIPDWardPricing(id);
      ref.invalidate(ipdWardPricingProvider);
    } catch (e) {
      _showMessage('Failed to delete ward pricing: $e');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _WardPricingFormDialog extends StatefulWidget {
  final Map<String, dynamic>? row;
  const _WardPricingFormDialog({this.row});

  @override
  State<_WardPricingFormDialog> createState() => _WardPricingFormDialogState();
}

class _WardPricingFormDialogState extends State<_WardPricingFormDialog> {
  late final TextEditingController _rateController;
  late final TextEditingController _descriptionController;
  late String _wardType;
  late bool _isActive;

  bool get _isEdit => widget.row != null;

  static const Map<String, String> _wardTypeOptions = {
    'general': 'General Ward',
    'semi_private': 'Semi Private',
    'private': 'Private',
    'icu': 'ICU',
    'nicu': 'NICU',
    'deluxe': 'Deluxe',
    'emergency': 'Emergency',
  };

  @override
  void initState() {
    super.initState();
    final row = widget.row;
    _wardType = row?['ward_type']?.toString() ?? 'general';
    final rate = _toDouble(row?['daily_rate']);
    _rateController = TextEditingController(
      text: rate == 0 ? '' : rate.toStringAsFixed(2),
    );
    _descriptionController = TextEditingController(
      text: row?['description']?.toString() ?? '',
    );
    _isActive = row?['is_active'] != false;
  }

  @override
  void dispose() {
    _rateController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit Ward Pricing' : 'Add Ward Pricing'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _wardType,
            decoration: const InputDecoration(labelText: 'Ward Type *'),
            items: _wardTypeOptions.entries
                .map(
                  (entry) => DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => _wardType = v!),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _rateController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Daily Rate (₹) *'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            decoration: const InputDecoration(
              labelText: 'Description',
              hintText: 'e.g. General ward bed charge per day',
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Active'),
            value: _isActive,
            onChanged: (v) => setState(() => _isActive = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final rate = _toDouble(_rateController.text);
            if (rate <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Enter a valid daily rate.')),
              );
              return;
            }
            Navigator.pop(context, {
              'ward_type': _wardType,
              'daily_rate': rate,
              'description': _descriptionController.text.trim(),
              'is_active': _isActive,
            });
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// =============================================================================
// Service Master
// =============================================================================

class _ServiceMasterDialog extends ConsumerStatefulWidget {
  const _ServiceMasterDialog();

  @override
  ConsumerState<_ServiceMasterDialog> createState() =>
      _ServiceMasterDialogState();
}

class _ServiceMasterDialogState extends ConsumerState<_ServiceMasterDialog> {
  @override
  Widget build(BuildContext context) {
    final servicesAsync = ref.watch(ipdServiceMasterProvider);

    return AlertDialog(
      title: Row(
        children: [
          const Text('Service Master'),
          const Spacer(),
          IconButton(
            tooltip: 'Add service',
            onPressed: () => _openServiceForm(),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 420,
        child: servicesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Failed to load services: $e')),
          data: (services) {
            if (services.isEmpty) {
              return const Center(
                child: Text(
                  'No services defined yet.\nTap + to add a service.',
                  textAlign: TextAlign.center,
                ),
              );
            }
            return ListView.separated(
              itemCount: services.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final service = services[index];
                final name = service['name']?.toString() ?? 'Service';
                final charge = _toDouble(service['default_charge']);
                final description = service['description']?.toString() ?? '';
                final isActive = service['is_active'] != false;
                return ListTile(
                  title: Text(name),
                  subtitle: Text(
                    description.isEmpty ? 'No description' : description,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _inr(charge),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: () => _openServiceForm(service: service),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: Colors.red,
                        ),
                        onPressed: () => _deleteService(service),
                      ),
                    ],
                  ),
                  enabled: isActive,
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Future<void> _openServiceForm({Map<String, dynamic>? service}) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ServiceFormDialog(service: service),
    );
    if (result == null) return;

    try {
      final db = ref.read(databaseServiceProvider);
      await db.saveIPDServiceMaster(result, id: service?['id']?.toString());
      ref.invalidate(ipdServiceMasterProvider);
    } catch (e) {
      _showMessage('Failed to save service: $e');
    }
  }

  Future<void> _deleteService(Map<String, dynamic> service) async {
    final id = service['id']?.toString();
    if (id == null) return;
    try {
      final db = ref.read(databaseServiceProvider);
      await db.deleteIPDServiceMaster(id);
      ref.invalidate(ipdServiceMasterProvider);
    } catch (e) {
      _showMessage('Failed to delete service: $e');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ServiceFormDialog extends StatefulWidget {
  final Map<String, dynamic>? service;
  const _ServiceFormDialog({this.service});

  @override
  State<_ServiceFormDialog> createState() => _ServiceFormDialogState();
}

class _ServiceFormDialogState extends State<_ServiceFormDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _chargeController;
  late final TextEditingController _descriptionController;

  bool get _isEdit => widget.service != null;

  @override
  void initState() {
    super.initState();
    final service = widget.service;
    _nameController = TextEditingController(
      text: service?['name']?.toString() ?? '',
    );
    final charge = _toDouble(service?['default_charge']);
    _chargeController = TextEditingController(
      text: charge == 0 ? '' : charge.toStringAsFixed(2),
    );
    _descriptionController = TextEditingController(
      text: service?['description']?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _chargeController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit Service' : 'Add Service'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Service Name *',
              hintText: 'e.g. Sitting Charge',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _chargeController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Default Charge (₹) *',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final name = _nameController.text.trim();
            final charge = _toDouble(_chargeController.text);
            if (name.isEmpty || charge <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Enter service name and a valid charge.'),
                ),
              );
              return;
            }
            Navigator.pop(context, {
              'name': name,
              'default_charge': charge,
              'description': _descriptionController.text.trim(),
            });
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// =============================================================================
// Package Master
// =============================================================================

class _PackageMasterDialog extends ConsumerStatefulWidget {
  const _PackageMasterDialog();

  @override
  ConsumerState<_PackageMasterDialog> createState() =>
      _PackageMasterDialogState();
}

class _PackageMasterDialogState extends ConsumerState<_PackageMasterDialog> {
  @override
  Widget build(BuildContext context) {
    final packagesAsync = ref.watch(ipdPackagesProvider);

    return AlertDialog(
      title: Row(
        children: [
          const Text('Package Master'),
          const Spacer(),
          IconButton(
            tooltip: 'Add package',
            onPressed: () => _openPackageForm(),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 420,
        child: packagesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Failed to load packages: $e')),
          data: (packages) {
            if (packages.isEmpty) {
              return const Center(
                child: Text(
                  'No packages defined yet.\nTap + to add a package.',
                  textAlign: TextAlign.center,
                ),
              );
            }
            return ListView.separated(
              itemCount: packages.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final package = packages[index];
                final name = package['name']?.toString() ?? 'Package';
                final amount = _toDouble(package['package_amount']);
                final description = package['description']?.toString() ?? '';
                final isActive = package['is_active'] != false;
                return ListTile(
                  title: Text(name),
                  subtitle: Text(
                    description.isEmpty ? 'No description' : description,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _inr(amount),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: () => _openPackageForm(package: package),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: Colors.red,
                        ),
                        onPressed: () => _deletePackage(package),
                      ),
                    ],
                  ),
                  enabled: isActive,
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Future<void> _openPackageForm({Map<String, dynamic>? package}) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PackageFormDialog(package: package),
    );
    if (result == null) return;

    try {
      final db = ref.read(databaseServiceProvider);
      await db.saveIPDPackage(result, id: package?['id']?.toString());
      ref.invalidate(ipdPackagesProvider);
    } catch (e) {
      _showMessage('Failed to save package: $e');
    }
  }

  Future<void> _deletePackage(Map<String, dynamic> package) async {
    final id = package['id']?.toString();
    if (id == null) return;
    try {
      final db = ref.read(databaseServiceProvider);
      await db.deleteIPDPackage(id);
      ref.invalidate(ipdPackagesProvider);
    } catch (e) {
      _showMessage('Failed to delete package: $e');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _PackageFormDialog extends StatefulWidget {
  final Map<String, dynamic>? package;
  const _PackageFormDialog({this.package});

  @override
  State<_PackageFormDialog> createState() => _PackageFormDialogState();
}

class _PackageFormDialogState extends State<_PackageFormDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _amountController;
  late final TextEditingController _descriptionController;
  late bool _isActive;

  bool get _isEdit => widget.package != null;

  @override
  void initState() {
    super.initState();
    final package = widget.package;
    _nameController = TextEditingController(
      text: package?['name']?.toString() ?? '',
    );
    final amount = _toDouble(package?['package_amount']);
    _amountController = TextEditingController(
      text: amount == 0 ? '' : amount.toStringAsFixed(2),
    );
    _descriptionController = TextEditingController(
      text: package?['description']?.toString() ?? '',
    );
    _isActive = package?['is_active'] != false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit Package' : 'Add Package'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Package Name *',
              hintText: 'e.g. Appendectomy Package',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amountController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Package Amount (₹) *',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Active'),
            value: _isActive,
            onChanged: (v) => setState(() => _isActive = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final name = _nameController.text.trim();
            final amount = _toDouble(_amountController.text);
            if (name.isEmpty || amount <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Enter package name and a valid amount.'),
                ),
              );
              return;
            }
            Navigator.pop(context, {
              'name': name,
              'package_amount': amount,
              'description': _descriptionController.text.trim(),
              'is_active': _isActive,
            });
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// =============================================================================
// Prescription Mode (Smart OPD & Prescription Workflow)
// =============================================================================

class _PrescriptionModeDialog extends ConsumerStatefulWidget {
  const _PrescriptionModeDialog();

  @override
  ConsumerState<_PrescriptionModeDialog> createState() =>
      _PrescriptionModeDialogState();
}

class _PrescriptionModeDialogState
    extends ConsumerState<_PrescriptionModeDialog> {
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;
    final doctorsAsync = ref.watch(doctorsCacheProvider(hospitalId));

    return AlertDialog(
      title: const Text('Prescription Mode'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: doctorsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Failed to load doctors: $e')),
          data: (doctors) {
            if (doctors.isEmpty) {
              return const Center(
                child: Text(
                  'No doctors found for this hospital.\n'
                  'Add doctors first from User Management.',
                  textAlign: TextAlign.center,
                ),
              );
            }
            return ListView.separated(
              itemCount: doctors.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final doctor = doctors[index];
                final doctorId = doctor['id']?.toString() ?? '';
                final name = doctor['name']?.toString() ?? 'Doctor';
                final prescriptionMode = doctor['prescription_mode'] == true;

                return SwitchListTile(
                  title: Text(name),
                  subtitle: Text(
                    prescriptionMode
                        ? 'Yes — Printed Prescription'
                        : 'No — Direct OPD',
                  ),
                  value: prescriptionMode,
                  onChanged: _isSaving
                      ? null
                      : (value) => _toggleMode(
                          doctorId: doctorId,
                          name: name,
                          mode: value,
                        ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Future<void> _toggleMode({
    required String doctorId,
    required String name,
    required bool mode,
  }) async {
    if (doctorId.isEmpty) return;

    setState(() => _isSaving = true);
    try {
      final db = ref.read(databaseServiceProvider);
      await db.updateDoctorPrescriptionMode(doctorId, mode);

      final hospitalId = ref.read(authStateProvider).hospitalId;
      ref.invalidate(doctorsCacheProvider(hospitalId));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$name → ${mode ? 'Yes (Printed Prescription)' : 'No (Direct OPD)'}',
          ),
          backgroundColor: const Color(0xFF66BB6A),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update prescription mode: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}

// Shared formatting helpers
double _toDouble(dynamic value) {
  if (value == null) return 0;
  return double.tryParse(value.toString()) ?? 0;
}

String _inr(double value) => '₹ ${value.toStringAsFixed(2)}';

String _formatWardType(String wardType) {
  final words = wardType.split('_').where((w) => w.isNotEmpty).toList();
  final formatted = words
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
  return formatted.isEmpty ? 'General' : formatted;
}
