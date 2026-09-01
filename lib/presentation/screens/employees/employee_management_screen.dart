import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../models/employee_attendance_summary.dart';
import '../../../models/employee_model.dart';
import '../../../models/employee_salary_summary.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/smart_navigation.dart';

/// ---------------------------------------------------------------------------
/// Employee Management screen (`/employees`).
///
/// UI composition only: the screen lays out three tabs and delegates every
/// data/calculation concern to providers + pure domain calculators. It never
/// performs a Supabase query or salary/attendance calculation itself.
/// ---------------------------------------------------------------------------
class EmployeeManagementScreen extends ConsumerStatefulWidget {
  const EmployeeManagementScreen({super.key});

  @override
  ConsumerState<EmployeeManagementScreen> createState() =>
      _EmployeeManagementScreenState();
}

class _EmployeeManagementScreenState
    extends ConsumerState<EmployeeManagementScreen> {
  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    if (hospitalId == null || hospitalId.isEmpty) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('Employee Management')),
        body: const Center(
          child: Text('Hospital not assigned to this user.'),
        ),
      );
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: SmartAppBar(
          title: const Text('Employee Management'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Employees'),
              Tab(text: 'Attendance'),
              Tab(text: 'Salary'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _EmployeesTab(hospitalId: hospitalId),
            _AttendanceTab(hospitalId: hospitalId),
            _SalaryTab(hospitalId: hospitalId),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 1. EMPLOYEES TAB
// ---------------------------------------------------------------------------
class _EmployeesTab extends ConsumerStatefulWidget {
  const _EmployeesTab({required this.hospitalId});

  final String hospitalId;

  @override
  ConsumerState<_EmployeesTab> createState() => _EmployeesTabState();
}

class _EmployeesTabState extends ConsumerState<_EmployeesTab> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final employeesAsync = ref.watch(employeesProvider(widget.hospitalId));
    final departmentsAsync = ref.watch(
      hospitalDepartmentsProvider(widget.hospitalId),
    );

    final departments = departmentsAsync.valueOrNull ??
        const <Map<String, dynamic>>[];
    final departmentNames = <String, String>{
      for (final d in departments)
        if (d['id']?.toString().isNotEmpty == true)
          d['id'].toString(): d['name']?.toString() ?? '—',
    };

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search by name / employee code / mobile',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _query = value.trim()),
              ),
              AppGap.sm,
              Row(
                children: [
                  Expanded(
                    child: Text(
                      employeesAsync.maybeWhen(
                        data: (employees) =>
                            '${_filter(employees).length} employee(s)',
                        orElse: () => 'Employees',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: () => context.push('/employees/new'),
                    icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                    label: const Text('Add Employee'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: employeesAsync.when(
            data: (employees) {
              final filtered = _filter(employees);
              if (filtered.isEmpty) {
                return const Center(child: Text('No employees found.'));
              }
              return RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(employeesProvider(widget.hospitalId));
                },
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => AppGap.xs,
                  itemBuilder: (context, index) {
                    final employee = filtered[index];
                    return _EmployeeCard(
                      employee: employee,
                      departmentName: departmentNames[employee.departmentId] ??
                          (employee.departmentId == null
                              ? '—'
                              : 'Unknown'),
                    );
                  },
                ),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _ErrorRetry(
              message: 'Failed to load employees',
              error: error,
              onRetry: () =>
                  ref.invalidate(employeesProvider(widget.hospitalId)),
            ),
          ),
        ),
      ],
    );
  }

  List<Employee> _filter(List<Employee> employees) {
    if (_query.isEmpty) return employees;
    final q = _query.toLowerCase();
    return employees.where((e) {
      return e.firstName.toLowerCase().contains(q) ||
          (e.lastName?.toLowerCase().contains(q) ?? false) ||
          e.employeeCode.toLowerCase().contains(q) ||
          (e.mobileNumber?.contains(q) ?? false);
    }).toList();
  }
}

class _EmployeeCard extends StatelessWidget {
  const _EmployeeCard({required this.employee, required this.departmentName});

  final Employee employee;
  final String departmentName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: employee.isActive
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest,
          child: Text(_initials(employee.fullName)),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                employee.fullName.isEmpty ? 'Unknown' : employee.fullName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                employee.employeeCode,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [departmentName, employee.designation]
                  .where((e) => e != null && e.isNotEmpty)
                  .join(' • '),
            ),
            Text(
              '${_formatCurrency(employee.monthlySalary)} / month'
              '${employee.mobileNumber == null || employee.mobileNumber!.isEmpty ? '' : '  •  ${employee.mobileNumber}'}',
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  employee.isActive ? Icons.check_circle : Icons.block,
                  size: 14,
                  color: employee.isActive ? Colors.green : colorScheme.error,
                ),
                const SizedBox(width: 4),
                Text(employee.isActive ? 'Active' : 'Inactive'),
              ],
            ),
          ],
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (action) {
            if (action == 'edit') {
              context.push('/employees/${employee.id}/edit');
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'edit', child: Text('Edit')),
          ],
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}

// ---------------------------------------------------------------------------
// 2. ATTENDANCE TAB (Daily + Monthly)
// ---------------------------------------------------------------------------
class _AttendanceTab extends StatelessWidget {
  const _AttendanceTab({required this.hospitalId});

  final String hospitalId;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const Material(
            color: Colors.transparent,
            child: TabBar(
              tabs: [Tab(text: 'Daily'), Tab(text: 'Monthly')],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _DailyAttendanceTab(hospitalId: hospitalId),
                _MonthlyAttendanceTab(hospitalId: hospitalId),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -- Daily attendance ---------------------------------------------------------
class _DailyAttendanceTab extends ConsumerStatefulWidget {
  const _DailyAttendanceTab({required this.hospitalId});

  final String hospitalId;

  @override
  ConsumerState<_DailyAttendanceTab> createState() =>
      _DailyAttendanceTabState();
}

class _DailyAttendanceTabState extends ConsumerState<_DailyAttendanceTab> {
  DateTime _date = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final date = DateTime(_date.year, _date.month, _date.day);
    final params = AttendanceDayParams(
      hospitalId: widget.hospitalId,
      date: date,
    );
    final dailyAsync = ref.watch(dailyAttendanceProvider(params));
    final employeesAsync = ref.watch(employeesProvider(widget.hospitalId));

    final employeesById = <String, Employee>{
      for (final e in employeesAsync.valueOrNull ?? const <Employee>[])
        e.id: e,
    };

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Previous day',
                onPressed: () => setState(() {
                  _date = _date.subtract(const Duration(days: 1));
                }),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickDate(context),
                  icon: const Icon(Icons.calendar_today_outlined, size: 16),
                  label: Text(DateFormat('dd MMM yyyy').format(_date)),
                ),
              ),
              IconButton(
                tooltip: 'Next day',
                onPressed: () => setState(() {
                  _date = _date.add(const Duration(days: 1));
                }),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
        Expanded(
          child: dailyAsync.when(
            data: (summaries) {
              if (summaries.isEmpty) {
                return const Center(
                  child: Text('No eligible employees for this date.'),
                );
              }
              return RefreshIndicator(
                onRefresh: () async => ref.invalidate(dailyAttendanceProvider(
                  params,
                )),
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: summaries.length,
                  separatorBuilder: (_, _) => AppGap.xs,
                  itemBuilder: (context, index) {
                    final summary = summaries[index];
                    final employee = employeesById[summary.employeeId];
                    return _DailyAttendanceRow(
                      summary: summary,
                      employee: employee,
                    );
                  },
                ),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _ErrorRetry(
              message: 'Failed to load daily attendance',
              error: error,
              onRetry: () => ref.invalidate(dailyAttendanceProvider(params)),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(_date.year - 3),
      lastDate: DateTime(_date.year + 3),
    );
    if (picked != null && mounted) {
      setState(() => _date = picked);
    }
  }
}

class _DailyAttendanceRow extends StatelessWidget {
  const _DailyAttendanceRow({required this.summary, this.employee});

  final EmployeeDailyAttendance summary;
  final Employee? employee;

  @override
  Widget build(BuildContext context) {
    final name = employee?.fullName ?? summary.employeeId;
    final code = employee?.employeeCode ?? '';

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showDetail(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (code.isNotEmpty)
                      Text(
                        code,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              _TimeColumn(
                label: 'In',
                value: summary.firstPunchIn == null
                    ? '—'
                    : DateFormat('hh:mm a').format(summary.firstPunchIn!),
              ),
              _TimeColumn(
                label: 'Out',
                value: summary.lastPunchOut == null
                    ? '—'
                    : DateFormat('hh:mm a').format(summary.lastPunchOut!),
              ),
              SizedBox(
                width: 64,
                child: Text(
                  _formatMinutes(summary.workingMinutes),
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              _StatusChip(status: summary.status),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetail(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(employee?.fullName ?? 'Attendance'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DetailRow(
              label: 'Date',
              value: DateFormat('dd MMM yyyy').format(summary.date),
            ),
            _DetailRow(
              label: 'Punch In',
              value: summary.firstPunchIn == null
                  ? '—'
                  : DateFormat('hh:mm a').format(summary.firstPunchIn!),
            ),
            _DetailRow(
              label: 'Punch Out',
              value: summary.lastPunchOut == null
                  ? (summary.isCurrentlyPunchedIn ? 'Not yet' : '—')
                  : DateFormat('hh:mm a').format(summary.lastPunchOut!),
            ),
            _DetailRow(
              label: 'Working Hours',
              value: _formatMinutes(summary.workingMinutes),
            ),
            _DetailRow(
              label: 'Status',
              value: summary.isCurrentlyPunchedIn
                  ? '${summary.status.label} (currently in)'
                  : summary.status.label,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _TimeColumn extends StatelessWidget {
  const _TimeColumn({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 74,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final AttendanceStatus status;

  @override
  Widget build(BuildContext context) {
    final (Color background, Color foreground, IconData icon) = switch (status) {
      AttendanceStatus.present => (
        Colors.green.withValues(alpha: 0.14),
        Colors.green.shade800,
        Icons.check_circle_outline,
      ),
      AttendanceStatus.halfDay => (
        Colors.orange.withValues(alpha: 0.16),
        Colors.orange.shade900,
        Icons.hourglass_bottom_outlined,
      ),
      AttendanceStatus.absent => (
        Colors.red.withValues(alpha: 0.12),
        Colors.red.shade800,
        Icons.cancel_outlined,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: foreground),
          const SizedBox(width: 4),
          Text(
            status.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

// -- Monthly attendance -------------------------------------------------------
class _MonthlyAttendanceTab extends ConsumerStatefulWidget {
  const _MonthlyAttendanceTab({required this.hospitalId});

  final String hospitalId;

  @override
  ConsumerState<_MonthlyAttendanceTab> createState() =>
      _MonthlyAttendanceTabState();
}

class _MonthlyAttendanceTabState extends ConsumerState<_MonthlyAttendanceTab> {
  late int _year;
  late int _month;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
  }

  @override
  Widget build(BuildContext context) {
    final params = AttendanceMonthParams(
      hospitalId: widget.hospitalId,
      year: _year,
      month: _month,
    );
    final monthlyAsync = ref.watch(monthlyAttendanceProvider(params));
    final employeesAsync = ref.watch(employeesProvider(widget.hospitalId));

    final employeesById = <String, Employee>{
      for (final e in employeesAsync.valueOrNull ?? const <Employee>[])
        e.id: e,
    };

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: _MonthYearSelector(
            year: _year,
            month: _month,
            onChanged: (year, month) => setState(() {
              _year = year;
              _month = month;
            }),
          ),
        ),
        Expanded(
          child: monthlyAsync.when(
            data: (summaries) {
              final relevant = summaries
                  .where((s) => s.eligibleDays > 0)
                  .toList();
              if (relevant.isEmpty) {
                return const Center(
                  child: Text('No employee was eligible in this month.'),
                );
              }
              return RefreshIndicator(
                onRefresh: () async =>
                    ref.invalidate(monthlyAttendanceProvider(params)),
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: relevant.length,
                  separatorBuilder: (_, _) => AppGap.xs,
                  itemBuilder: (context, index) {
                    final summary = relevant[index];
                    final employee = employeesById[summary.employeeId];
                    return _MonthlyAttendanceRow(
                      summary: summary,
                      employee: employee,
                    );
                  },
                ),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _ErrorRetry(
              message: 'Failed to load monthly attendance',
              error: error,
              onRetry: () => ref.invalidate(monthlyAttendanceProvider(params)),
            ),
          ),
        ),
      ],
    );
  }
}

class _MonthlyAttendanceRow extends StatelessWidget {
  const _MonthlyAttendanceRow({required this.summary, this.employee});

  final EmployeeMonthlyAttendance summary;
  final Employee? employee;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        title: Text(
          employee?.fullName ?? summary.employeeId,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _Metric(label: 'Present', value: '${summary.presentDays}'),
            _Metric(label: 'Half', value: '${summary.halfDays}'),
            _Metric(label: 'Absent', value: '${summary.absentDays}'),
            _Metric(
              label: 'Units',
              value: summary.attendanceUnits
                  .toStringAsFixed(summary.attendanceUnits == summary.attendanceUnits.roundToDouble() ? 0 : 1),
            ),
            _Metric(
              label: 'Hours',
              value: _formatMinutes(summary.totalWorkingMinutes),
            ),
          ],
        ),
        trailing: Text(
          'Eligible\n${summary.eligibleDays}d',
          textAlign: TextAlign.right,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        text: '$label: ',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        children: [
          TextSpan(
            text: value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. SALARY TAB
// ---------------------------------------------------------------------------
class _SalaryTab extends ConsumerStatefulWidget {
  const _SalaryTab({required this.hospitalId});

  final String hospitalId;

  @override
  ConsumerState<_SalaryTab> createState() => _SalaryTabState();
}

class _SalaryTabState extends ConsumerState<_SalaryTab> {
  late int _year;
  late int _month;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
  }

  @override
  Widget build(BuildContext context) {
    final params = AttendanceMonthParams(
      hospitalId: widget.hospitalId,
      year: _year,
      month: _month,
    );
    final salaryAsync = ref.watch(employeeSalarySummaryProvider(params));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: _MonthYearSelector(
            year: _year,
            month: _month,
            onChanged: (year, month) => setState(() {
              _year = year;
              _month = month;
            }),
          ),
        ),
        Expanded(
          child: salaryAsync.when(
            data: (rows) {
              if (rows.isEmpty) {
                return const Center(
                  child: Text('No salary data for this month.'),
                );
              }
              final totalEmployees = rows.length;
              final grossSalary = rows.fold<double>(
                0,
                (sum, r) => sum + r.monthlySalary,
              );
              final payableSalary = rows.fold<double>(
                0,
                (sum, r) => sum + r.payableSalary,
              );

              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _SummaryCard(
                          icon: Icons.people_outline,
                          label: 'Total Employees',
                          value: '$totalEmployees',
                          color: Colors.blue,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SummaryCard(
                          icon: Icons.currency_rupee,
                          label: 'Gross Monthly Salary',
                          value: _formatCurrency(grossSalary),
                          color: Colors.purple,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SummaryCard(
                          icon: Icons.payments_outlined,
                          label: 'Total Payable Salary',
                          value: _formatCurrency(payableSalary),
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                  AppGap.md,
                  for (final row in rows) ...[
                    _SalaryRow(row: row),
                    AppGap.xs,
                  ],
                ],
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _ErrorRetry(
              message: 'Failed to calculate salary',
              error: error,
              onRetry: () =>
                  ref.invalidate(employeeSalarySummaryProvider(params)),
            ),
          ),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 8),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SalaryRow extends StatelessWidget {
  const _SalaryRow({required this.row});

  final EmployeeSalarySummary row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        title: Text(
          row.employeeName.isEmpty ? row.employeeCode : row.employeeName,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _Metric(label: 'Gross', value: _formatCurrency(row.monthlySalary)),
            _Metric(label: 'Eligible', value: '${row.eligibleDays}d'),
            _Metric(label: 'Present', value: '${row.presentDays}'),
            _Metric(label: 'Half', value: '${row.halfDays}'),
            _Metric(label: 'Absent', value: '${row.absentDays}'),
            _Metric(
              label: 'Units',
              value: row.attendanceUnits.toStringAsFixed(1),
            ),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _formatCurrency(row.payableSalary),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.green.shade800,
              ),
            ),
            Text(
              'Payable',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared small widgets
// ---------------------------------------------------------------------------
class _MonthYearSelector extends StatelessWidget {
  const _MonthYearSelector({
    required this.year,
    required this.month,
    required this.onChanged,
  });

  final int year;
  final int month;
  final void Function(int year, int month) onChanged;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final years = [for (var y = now.year - 5; y <= now.year + 1; y++) y];

    return Row(
      children: [
        Expanded(
          flex: 2,
          child: DropdownButtonFormField<int>(
            initialValue: month,
            decoration: const InputDecoration(
              labelText: 'Month',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              for (var m = 1; m <= 12; m++)
                DropdownMenuItem(
                  value: m,
                  child: Text(DateFormat('MMMM').format(DateTime(year, m))),
                ),
            ],
            onChanged: (value) {
              if (value != null) onChanged(year, value);
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<int>(
            initialValue: year,
            decoration: const InputDecoration(
              labelText: 'Year',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              for (final y in years)
                DropdownMenuItem(value: y, child: Text('$y')),
            ],
            onChanged: (value) {
              if (value != null) onChanged(value, month);
            },
          ),
        ),
      ],
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({
    required this.message,
    required this.error,
    required this.onRetry,
  });

  final String message;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting helpers (UI-only; domain formatting stays out of calculators)
// ---------------------------------------------------------------------------
String _formatCurrency(double value) =>
    NumberFormat.currency(locale: 'en_IN', symbol: '₹').format(value);

String _formatMinutes(int minutes) {
  if (minutes <= 0) return '0h 0m';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return '${h}h ${m}m';
}
