import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../models/employee_model.dart';
import '../../../repositories/employee_repository.dart';
import '../../widgets/app_ui.dart';

/// ---------------------------------------------------------------------------
/// Employee form screen (`/employees/new`, `/employees/:id/edit`).
///
/// UI composition + validation only. Persistence goes through
/// [EmployeeRepository]; the screen never talks to Supabase directly. Face
/// enrollment fields are intentionally absent — backend metadata only.
/// ---------------------------------------------------------------------------
class EmployeeFormScreen extends ConsumerStatefulWidget {
  const EmployeeFormScreen({super.key, this.employeeId});

  /// When non-null the screen edits an existing employee.
  final String? employeeId;

  @override
  ConsumerState<EmployeeFormScreen> createState() => _EmployeeFormScreenState();
}

class _EmployeeFormScreenState extends ConsumerState<EmployeeFormScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _mobileController;
  late final TextEditingController _designationController;
  late final TextEditingController _salaryController;

  String? _departmentId;
  late DateTime _joiningDate;
  DateTime? _relievingDate;
  bool _isActive = true;
  bool _saving = false;

  Employee? _existing;
  bool _loadingExisting = false;

  bool get _isEdit => widget.employeeId != null;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _joiningDate = DateTime(now.year, now.month, now.day);

    _firstNameController = TextEditingController();
    _lastNameController = TextEditingController();
    _mobileController = TextEditingController();
    _designationController = TextEditingController();
    _salaryController = TextEditingController();

    final id = widget.employeeId;
    if (id != null && id.isNotEmpty) {
      _loadingExisting = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadExisting(id));
    }
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _mobileController.dispose();
    _designationController.dispose();
    _salaryController.dispose();
    super.dispose();
  }

  Future<void> _loadExisting(String id) async {
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty || !mounted) return;

    try {
      final employee = await ref.read(
        employeeByIdProvider(
          EmployeeDetailParams(hospitalId: hospitalId, employeeId: id),
        ).future,
      );
      if (!mounted) return;
      if (employee == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Employee not found.')),
        );
        return;
      }
      setState(() {
        _existing = employee;
        _firstNameController.text = employee.firstName;
        _lastNameController.text = employee.lastName ?? '';
        _mobileController.text = employee.mobileNumber ?? '';
        _designationController.text = employee.designation ?? '';
        _salaryController.text = _formatSalaryInput(employee.monthlySalary);
        _departmentId = employee.departmentId;
        _joiningDate = employee.joiningDate ?? _joiningDate;
        _relievingDate = employee.relievingDate;
        _isActive = employee.isActive;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not load employee: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _loadingExisting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;
    final departmentsAsync = hospitalId == null
        ? null
        : ref.watch(hospitalDepartmentsProvider(hospitalId));
    final departments = departmentsAsync?.valueOrNull ??
        const <Map<String, dynamic>>[];

    return AppPage(
      title: _isEdit ? 'Edit Employee' : 'Add Employee',
      isRootPage: false,
      children: [
        if (_loadingExisting)
          const Center(child: CircularProgressIndicator())
        else
          Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppFieldRow(
                  children: [
                    TextFormField(
                      controller: _firstNameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'First Name *',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'First name is required'
                          : null,
                    ),
                    TextFormField(
                      controller: _lastNameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Last Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
                AppGap.sm,
                TextFormField(
                  controller: _mobileController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Mobile',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final v = value?.trim() ?? '';
                    if (v.isEmpty) return null;
                    if (!RegExp(r'^\d{10,15}$').hasMatch(v)) {
                      return 'Enter a valid mobile number';
                    }
                    return null;
                  },
                ),
                AppGap.sm,
                AppFieldRow(
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _departmentId,
                      decoration: const InputDecoration(
                        labelText: 'Department',
                        border: OutlineInputBorder(),
                      ),
                      items: _departmentItems(departments),
                      onChanged: (value) =>
                          setState(() => _departmentId = value),
                    ),
                    TextFormField(
                      controller: _designationController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Designation',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
                AppGap.sm,
                TextFormField(
                  controller: _salaryController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Monthly Salary (₹) *',
                    prefixText: '₹ ',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final v = value?.trim() ?? '';
                    if (v.isEmpty) return 'Monthly salary is required';
                    final parsed = double.tryParse(v);
                    if (parsed == null || parsed < 0) {
                      return 'Enter a valid salary';
                    }
                    return null;
                  },
                ),
                AppGap.sm,
                AppFieldRow(
                  children: [
                    _DateField(
                      label: 'Joining Date *',
                      value: DateFormat('dd MMM yyyy').format(_joiningDate),
                      onTap: _pickJoiningDate,
                    ),
                    _DateField(
                      label: 'Relieving Date (optional)',
                      value: _relievingDate == null
                          ? 'Not set'
                          : DateFormat('dd MMM yyyy').format(_relievingDate!),
                      onTap: _pickRelievingDate,
                      onClear: _relievingDate == null
                          ? null
                          : () => setState(() => _relievingDate = null),
                    ),
                  ],
                ),
                AppGap.xs,
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  subtitle: const Text(
                    'Inactive employees are excluded from attendance.',
                  ),
                  value: _isActive,
                  onChanged: (value) => setState(() => _isActive = value),
                ),
                AppGap.md,
                AppSubmitButton(
                  label: _isEdit ? 'Save Changes' : 'Create Employee',
                  loading: _saving,
                  onPressed: _submit,
                  icon: Icons.save_outlined,
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Department dropdown items. Includes the current department when it is not
  /// present in the fetched list (e.g. the department was deleted later).
  List<DropdownMenuItem<String>> _departmentItems(
    List<Map<String, dynamic>> departments,
  ) {
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(
        value: null,
        child: Text('No Department'),
      ),
    ];

    final currentId = _departmentId;
    if (currentId != null &&
        currentId.isNotEmpty &&
        !departments.any((d) => d['id']?.toString() == currentId)) {
      items.add(
        DropdownMenuItem<String>(
          value: currentId,
          child: const Text('Current Department'),
        ),
      );
    }

    items.addAll(
      departments.map(
        (department) => DropdownMenuItem<String>(
          value: department['id']?.toString(),
          child: Text(department['name']?.toString() ?? 'Unknown'),
        ),
      ),
    );
    return items;
  }

  Future<void> _pickJoiningDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _joiningDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() {
        _joiningDate = picked;
        if (_relievingDate != null && _relievingDate!.isBefore(picked)) {
          _relievingDate = null;
        }
      });
    }
  }

  Future<void> _pickRelievingDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _relievingDate ?? _joiningDate,
      firstDate: _joiningDate,
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => _relievingDate = picked);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final relieving = _relievingDate;
    if (relieving != null && relieving.isBefore(_joiningDate)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Relieving date cannot be before joining date.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Hospital not assigned to this user.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final draft = Employee(
        id: _existing?.id ?? '',
        hospitalId: hospitalId,
        employeeCode: _existing?.employeeCode ?? '',
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim().isEmpty
            ? null
            : _lastNameController.text.trim(),
        mobileNumber: _mobileController.text.trim().isEmpty
            ? null
            : _mobileController.text.trim(),
        departmentId: _departmentId,
        designation: _designationController.text.trim().isEmpty
            ? null
            : _designationController.text.trim(),
        monthlySalary: double.tryParse(_salaryController.text.trim()) ?? 0,
        joiningDate: _joiningDate,
        relievingDate: relieving,
        isActive: _isActive,
        // Preserve backend-only face metadata on edit.
        faceReferenceId: _existing?.faceReferenceId,
        faceEnrolled: _existing?.faceEnrolled ?? false,
      );

      final repository = ref.read(employeeRepositoryProvider);
      if (_isEdit) {
        await repository.updateEmployee(hospitalId: hospitalId, employee: draft);
      } else {
        await repository.createEmployee(hospitalId: hospitalId, employee: draft);
      }

      ref.read(employeesRefreshProvider.notifier).state++;
      if (mounted) context.go('/employees');
    } on EmployeeRepositoryException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.red),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not save employee. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
    this.onClear,
  });

  final String label;
  final String value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: onClear == null
              ? const Icon(Icons.calendar_today_outlined, size: 18)
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: 'Clear',
                  onPressed: onClear,
                ),
        ),
        child: Text(value),
      ),
    );
  }
}

String _formatSalaryInput(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(2);
}
