import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../widgets/smart_navigation.dart';

/// The seven staff roles supported by the user-management module.
const List<({String label, String value})> _roleOptions = [
  (label: 'Admin', value: 'admin'),
  (label: 'Doctor', value: 'doctor'),
  (label: 'Nurse', value: 'nurse'),
  (label: 'Receptionist', value: 'receptionist'),
  (label: 'Pharmacist', value: 'pharmacist'),
  (label: 'Lab Technician', value: 'lab_technician'),
  (label: 'Accountant', value: 'accountant'),
];

/// Multi-user management screen (`/users`).
///
/// Lists every user of the logged-in admin's hospital and supports adding,
/// editing and deleting users.
class UserManagementScreen extends ConsumerStatefulWidget {
  const UserManagementScreen({super.key});

  @override
  ConsumerState<UserManagementScreen> createState() =>
      _UserManagementScreenState();
}

class _UserManagementScreenState extends ConsumerState<UserManagementScreen> {
  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    if (hospitalId == null || hospitalId.isEmpty) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('User Management')),
        body: const Center(
          child: Text('Hospital not assigned to this user.'),
        ),
      );
    }

    final usersAsync = ref.watch(hospitalUsersProvider(hospitalId));
    final departmentsAsync = ref.watch(hospitalDepartmentsProvider(hospitalId));
    final departments =
        departmentsAsync.valueOrNull ?? const <Map<String, dynamic>>[];

    return Scaffold(
      appBar: SmartAppBar(title: const Text('User Management')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showUserFormDialog(
          hospitalId: hospitalId,
          departments: departments,
        ),
        icon: const Icon(Icons.person_add_alt_1_outlined),
        label: const Text('Add User'),
      ),
      body: usersAsync.when(
        data: (users) {
          if (users.isEmpty) {
            return const Center(
              child: Text('No users found. Add the first user!'),
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(hospitalUsersProvider(hospitalId));
            },
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: users.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final user = users[index];
                return _buildUserCard(user, hospitalId, departments);
              },
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Failed to load users: $error'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () =>
                    ref.invalidate(hospitalUsersProvider(hospitalId)),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUserCard(
    Map<String, dynamic> user,
    String hospitalId,
    List<Map<String, dynamic>> departments,
  ) {
    final theme = Theme.of(context);
    final firstName = user['first_name']?.toString() ?? '';
    final lastName = user['last_name']?.toString() ?? '';
    final fullName = '$firstName $lastName'.trim();
    final email = user['email']?.toString() ?? '-';
    final phone = user['phone']?.toString() ?? '';
    final role = user['role']?.toString() ?? 'staff';
    final isActive = user['is_active'] != false;
    final department = (user['departments'] as Map?)?.cast<String, dynamic>();
    final departmentName = department?['name']?.toString();

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isActive
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          child: Text(_initials(fullName)),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                fullName.isEmpty ? 'Unknown User' : fullName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            _RoleChip(role: role),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(email),
            if (departmentName != null && departmentName.isNotEmpty)
              Text('Department: $departmentName'),
            if (phone.isNotEmpty) Text('Phone: $phone'),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  isActive ? Icons.check_circle : Icons.block,
                  size: 14,
                  color: isActive ? Colors.green : theme.colorScheme.error,
                ),
                const SizedBox(width: 4),
                Text(isActive ? 'Active' : 'Inactive'),
              ],
            ),
          ],
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (action) {
            if (action == 'edit') {
              _showUserFormDialog(
                hospitalId: hospitalId,
                departments: departments,
                existing: user,
              );
            } else if (action == 'delete') {
              _confirmDelete(user, hospitalId);
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'edit', child: Text('Edit')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  Future<void> _showUserFormDialog({
    required String hospitalId,
    required List<Map<String, dynamic>> departments,
    Map<String, dynamic>? existing,
  }) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          _UserFormDialog(existing: existing, departments: departments),
    );

    if (result == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final dbService = ref.read(databaseServiceProvider);
      if (existing == null) {
        await dbService.createUser({...result, 'hospital_id': hospitalId});
        messenger.showSnackBar(
          const SnackBar(content: Text('User created successfully!')),
        );
      } else {
        await dbService.updateUser(existing['id'] as String, result);
        messenger.showSnackBar(
          const SnackBar(content: Text('User updated successfully!')),
        );
      }
      ref.invalidate(hospitalUsersProvider(hospitalId));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to save user: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _confirmDelete(
    Map<String, dynamic> user,
    String hospitalId,
  ) async {
    final firstName = user['first_name']?.toString() ?? '';
    final lastName = user['last_name']?.toString() ?? '';
    final name = '$firstName $lastName'.trim();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete User'),
        content: Text(
          'Are you sure you want to delete "$name"?\n\n'
          'This removes their hospital access. The Supabase Auth account '
          'still exists and must be removed from the Auth dashboard if '
          'needed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(databaseServiceProvider).deleteUser(user['id'] as String);
      ref.invalidate(hospitalUsersProvider(hospitalId));
      messenger.showSnackBar(
        const SnackBar(content: Text('User deleted successfully!')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to delete user: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final label = _roleLabel(role);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

String _roleLabel(String role) {
  final normalized = role.toLowerCase();
  for (final option in _roleOptions) {
    if (option.value == normalized) return option.label;
  }
  if (normalized == 'super_admin') return 'Super Admin';
  if (normalized.isEmpty) return 'Staff';
  return normalized[0].toUpperCase() + normalized.substring(1);
}

class _UserFormDialog extends StatefulWidget {
  const _UserFormDialog({required this.existing, required this.departments});

  final Map<String, dynamic>? existing;
  final List<Map<String, dynamic>> departments;

  @override
  State<_UserFormDialog> createState() => _UserFormDialogState();
}

class _UserFormDialogState extends State<_UserFormDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _emailController;
  late final TextEditingController _passwordController;
  late final TextEditingController _phoneController;

  late String _role;
  String? _departmentId;
  late bool _isActive;
  bool _obscurePassword = true;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _firstNameController = TextEditingController(
      text: existing?['first_name']?.toString() ?? '',
    );
    _lastNameController = TextEditingController(
      text: existing?['last_name']?.toString() ?? '',
    );
    _emailController = TextEditingController(
      text: existing?['email']?.toString() ?? '',
    );
    _passwordController = TextEditingController();
    _phoneController = TextEditingController(
      text: existing?['phone']?.toString() ?? '',
    );
    _role = existing?['role']?.toString() ?? 'receptionist';
    _departmentId = existing?['department_id']?.toString();
    _isActive = existing?['is_active'] != false;
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    Navigator.pop(context, {
      'first_name': _firstNameController.text.trim(),
      'last_name': _lastNameController.text.trim(),
      'email': _emailController.text.trim(),
      'password': _passwordController.text,
      'role': _role,
      'department_id': _role == 'doctor' ? _departmentId : null,
      'phone': _phoneController.text.trim(),
      'is_active': _isActive,
    });
  }

  /// Role dropdown items. Includes the current role when it is a legacy value
  /// (e.g. `super_admin`, `staff`) that isn't part of the standard list, so
  /// the dropdown never renders without a matching selected value.
  List<DropdownMenuItem<String>> _roleItems() {
    final items = <DropdownMenuItem<String>>[];
    if (!_roleOptions.any((option) => option.value == _role)) {
      items.add(
        DropdownMenuItem(value: _role, child: Text(_roleLabel(_role))),
      );
    }
    items.addAll(
      _roleOptions.map(
        (option) => DropdownMenuItem(
          value: option.value,
          child: Text(option.label),
        ),
      ),
    );
    return items;
  }

  /// Department dropdown items. Includes the current department when it isn't
  /// present in [widget.departments] (e.g. department was deleted later).
  List<DropdownMenuItem<String>> _departmentItems() {
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(
        value: null,
        child: Text('Select Department'),
      ),
    ];

    final currentId = _departmentId;
    if (currentId != null &&
        !widget.departments.any((d) => d['id']?.toString() == currentId)) {
      items.add(
        DropdownMenuItem<String>(
          value: currentId,
          child: const Text('Current Department'),
        ),
      );
    }

    items.addAll(
      widget.departments.map(
        (department) => DropdownMenuItem<String>(
          value: department['id']?.toString(),
          child: Text(department['name']?.toString() ?? 'Unknown'),
        ),
      ),
    );
    return items;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit User' : 'Add New User'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _firstNameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'First Name *'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'First name is required'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _lastNameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Last Name'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emailController,
                enabled: !_isEdit,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Email *',
                  helperText: _isEdit
                      ? 'Email cannot be changed after creation'
                      : null,
                ),
                validator: (value) {
                  final v = value?.trim() ?? '';
                  if (v.isEmpty) return 'Email is required';
                  if (!v.contains('@')) return 'Enter a valid email';
                  return null;
                },
              ),
              if (!_isEdit) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Password *',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                      onPressed: () => setState(
                        () => _obscurePassword = !_obscurePassword,
                      ),
                    ),
                  ),
                  validator: (value) {
                    final v = value ?? '';
                    if (v.isEmpty) return 'Password is required';
                    if (v.length < 6) return 'Minimum 6 characters';
                    return null;
                  },
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Role *'),
                items: _roleItems(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _role = value;
                      if (_role != 'doctor') _departmentId = null;
                    });
                  }
                },
              ),
              if (_role == 'doctor') ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _departmentId,
                  decoration: const InputDecoration(
                    labelText: 'Department (for Doctor)',
                  ),
                  items: _departmentItems(),
                  onChanged: (value) =>
                      setState(() => _departmentId = value),
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone'),
                validator: (value) {
                  final v = value?.trim() ?? '';
                  if (v.isEmpty) return null;
                  if (!RegExp(r'^\d{10,15}$').hasMatch(v)) {
                    return 'Enter a valid phone number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Active'),
                value: _isActive,
                onChanged: (value) => setState(() => _isActive = value),
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
        FilledButton(
          onPressed: _submit,
          child: Text(_isEdit ? 'Save Changes' : 'Create User'),
        ),
      ],
    );
  }
}
