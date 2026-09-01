import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../models/marketing_models.dart';
import '../../../repositories/marketing_area_repository.dart';
import '../../widgets/app_ui.dart';
import 'marketing_widgets.dart';

/// Areas tab — field-work marketing areas.
class MarketingAreasTab extends ConsumerStatefulWidget {
  const MarketingAreasTab({super.key, required this.hospitalId});

  final String hospitalId;

  @override
  ConsumerState<MarketingAreasTab> createState() => _MarketingAreasTabState();
}

class _MarketingAreasTabState extends ConsumerState<MarketingAreasTab> {
  @override
  Widget build(BuildContext context) {
    final areasAsync = ref.watch(marketingAreasProvider(widget.hospitalId));
    final doctorsAsync = ref.watch(referralDoctorsProvider(widget.hospitalId));

    final doctors = doctorsAsync.valueOrNull ?? const <ReferralDoctor>[];
    final doctorsByArea = <String, int>{};
    for (final doctor in doctors) {
      final areaId = doctor.areaId ?? '';
      doctorsByArea[areaId] = (doctorsByArea[areaId] ?? 0) + 1;
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Field-work areas (Govardhan, Vrindavan, Barsana...)',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              FilledButton.icon(
                onPressed: () => _showAreaDialog(),
                icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                label: const Text('Add Area'),
              ),
            ],
          ),
        ),
        Expanded(
          child: areasAsync.when(
            data: (areas) {
              if (areas.isEmpty) {
                return const MarketingEmptyState(
                  message: 'No marketing areas configured yet.',
                );
              }
              return RefreshIndicator(
                onRefresh: () async =>
                    ref.invalidate(marketingAreasProvider(widget.hospitalId)),
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: areas.length,
                  separatorBuilder: (_, _) => AppGap.xs,
                  itemBuilder: (context, index) {
                    final area = areas[index];
                    return _AreaCard(
                      area: area,
                      doctorCount: doctorsByArea[area.id] ?? 0,
                      onTap: () => context.push('/marketing/areas/${area.id}'),
                      onEdit: () => _showAreaDialog(existing: area),
                    );
                  },
                ),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => MarketingErrorRetry(
              message: 'Failed to load areas',
              error: error,
              onRetry: () =>
                  ref.invalidate(marketingAreasProvider(widget.hospitalId)),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showAreaDialog({MarketingArea? existing}) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _AreaFormDialog(existing: existing),
    );
    if (result == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final repository = ref.read(marketingAreaRepositoryProvider);
      if (existing == null) {
        await repository.createArea(
          hospitalId: widget.hospitalId,
          area: MarketingArea(
            id: '',
            hospitalId: widget.hospitalId,
            name: result['name'] as String,
            code: result['code'] as String?,
            description: result['description'] as String?,
            isActive: result['is_active'] as bool,
          ),
        );
      } else {
        await repository.updateArea(
          hospitalId: widget.hospitalId,
          area: MarketingArea(
            id: existing.id,
            hospitalId: widget.hospitalId,
            name: result['name'] as String,
            code: result['code'] as String?,
            description: result['description'] as String?,
            isActive: result['is_active'] as bool,
          ),
        );
      }
      ref.read(marketingRefreshProvider.notifier).state++;
      messenger.showSnackBar(
        SnackBar(
          content: Text(existing == null ? 'Area created!' : 'Area updated!'),
        ),
      );
    } on MarketingRepositoryException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.red),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not save area. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}

class _AreaCard extends StatelessWidget {
  const _AreaCard({
    required this.area,
    required this.doctorCount,
    required this.onTap,
    required this.onEdit,
  });

  final MarketingArea area;
  final int doctorCount;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          child: Text(area.name.isEmpty ? '?' : area.name[0].toUpperCase()),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                area.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (!area.isActive) ...[
              const SizedBox(width: 8),
              const Icon(Icons.block, size: 14, color: Colors.grey),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (area.code != null && area.code!.isNotEmpty)
              Text('Code: ${area.code}'),
            if (area.description != null && area.description!.isNotEmpty)
              Text(
                area.description!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            Text('$doctorCount referral doctor(s)'),
          ],
        ),
        isThreeLine: true,
        trailing: IconButton(
          tooltip: 'Edit Area',
          icon: const Icon(Icons.edit_outlined, size: 20),
          onPressed: onEdit,
        ),
      ),
    );
  }
}

class _AreaFormDialog extends StatefulWidget {
  const _AreaFormDialog({this.existing});

  final MarketingArea? existing;

  @override
  State<_AreaFormDialog> createState() => _AreaFormDialogState();
}

class _AreaFormDialogState extends State<_AreaFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _codeController;
  late final TextEditingController _descriptionController;
  late bool _isActive;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _codeController = TextEditingController(text: existing?.code ?? '');
    _descriptionController = TextEditingController(
      text: existing?.description ?? '',
    );
    _isActive = existing?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, {
      'name': _nameController.text.trim(),
      'code': _codeController.text.trim().isEmpty
          ? null
          : _codeController.text.trim(),
      'description': _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim(),
      'is_active': _isActive,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit Marketing Area' : 'Add Marketing Area'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Area Name *'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Area name is required'
                    : null,
              ),
              AppGap.sm,
              TextFormField(
                controller: _codeController,
                decoration: const InputDecoration(labelText: 'Code (optional)'),
              ),
              AppGap.sm,
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                ),
                maxLines: 2,
              ),
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
          child: Text(_isEdit ? 'Save Changes' : 'Create Area'),
        ),
      ],
    );
  }
}
