import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/whatsapp_providers.dart';
import '../../../models/whatsapp_models.dart';
import '../../../services/whatsapp_service.dart';
import '../../widgets/smart_navigation.dart';
import 'whatsapp_ui.dart';

/// ---------------------------------------------------------------------------
/// WhatsApp Templates Screen (`/whatsapp/templates`)
/// ---------------------------------------------------------------------------
/// Local copy of Meta pre-approved templates plus create/update/delete. A
/// template can optionally be pushed to Meta (so it becomes usable in
/// campaigns immediately) or stored locally while Meta approval is pending.
/// ---------------------------------------------------------------------------
class WhatsappTemplatesScreen extends ConsumerWidget {
  const WhatsappTemplatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('WhatsApp Templates'),
        isRootPage: false,
      ),
      floatingActionButton: hospitalId == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openTemplateForm(context, ref, hospitalId),
              icon: const Icon(Icons.add),
              label: const Text('New Template'),
            ),
      body: hospitalId == null
          ? const Center(child: Text('Hospital not assigned to this user.'))
          : ref
                .watch(whatsappTemplatesProvider(hospitalId))
                .when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Failed to load templates: $error'),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () => ref.invalidate(
                            whatsappTemplatesProvider(hospitalId),
                          ),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                  data: (templates) {
                    if (templates.isEmpty) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No templates yet.\nTap + to create your first message template.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: templates.length,
                      itemBuilder: (context, index) {
                        final template = templates[index];
                        return _TemplateCard(
                          template: template,
                          onEdit: () => _openTemplateForm(
                            context,
                            ref,
                            hospitalId,
                            template: template,
                          ),
                          onDelete: () => _deleteTemplate(
                            context,
                            ref,
                            hospitalId,
                            template,
                          ),
                          onSync: () =>
                              _pushToMeta(context, ref, hospitalId, template),
                        );
                      },
                    );
                  },
                ),
    );
  }

  Future<void> _openTemplateForm(
    BuildContext context,
    WidgetRef ref,
    String hospitalId, {
    WhatsappTemplate? template,
  }) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _TemplateFormDialog(template: template),
    );
    if (result == null) return;

    try {
      final toSave = WhatsappTemplate(
        hospitalId: hospitalId,
        templateName: result['template_name'] as String,
        language: result['language'] as String,
        category: result['category'] as String,
        body: result['body'] as String,
        headerType: result['header_type'] as String,
        headerText: result['header_text'] as String,
        footerText: result['footer_text'] as String,
        buttons: result['buttons'] as List<Map<String, dynamic>>,
        status: result['status'] as String,
        isActive: result['is_active'] as bool,
      );
      await ref
          .read(whatsappDbServiceProvider)
          .saveTemplate(toSave, id: template?.id);
      invalidateWhatsappProviders(ref, hospitalId: hospitalId);
      if (context.mounted) {
        showWhatsappSuccess(context, 'Template saved.');
      }
    } catch (e) {
      if (context.mounted) showWhatsappError(context, e);
    }
  }

  Future<void> _deleteTemplate(
    BuildContext context,
    WidgetRef ref,
    String hospitalId,
    WhatsappTemplate template,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Template'),
        content: Text('Delete "${template.templateName}"?'),
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
    if (confirmed != true) return;

    try {
      await ref
          .read(whatsappDbServiceProvider)
          .deleteTemplate(template.id, hospitalId);
      invalidateWhatsappProviders(ref, hospitalId: hospitalId);
      if (context.mounted) {
        showWhatsappSuccess(context, 'Template deleted.');
      }
    } catch (e) {
      if (context.mounted) showWhatsappError(context, e);
    }
  }

  Future<void> _pushToMeta(
    BuildContext context,
    WidgetRef ref,
    String hospitalId,
    WhatsappTemplate template,
  ) async {
    final settings = await ref
        .read(whatsappDbServiceProvider)
        .getSettings(hospitalId);
    if (settings == null || !settings.isConfigured) {
      if (context.mounted) {
        showWhatsappError(
          context,
          'Configure WhatsApp API settings before syncing templates with Meta.',
        );
      }
      return;
    }

    final wabaId = settings.businessAccountId.isNotEmpty
        ? settings.businessAccountId
        : settings.phoneNumberId;

    try {
      await ref
          .read(whatsappServiceProvider)
          .createTemplate(
            accessToken: settings.apiKey,
            wabaId: wabaId,
            name: template.templateName,
            language: template.language,
            category: template.category,
            body: template.body,
            headerType: template.headerType,
            headerText: template.headerText,
            footerText: template.footerText,
            buttons: template.buttons,
          );
      await ref
          .read(whatsappDbServiceProvider)
          .saveTemplate(template.copyWith(status: 'pending'), id: template.id);
      invalidateWhatsappProviders(ref, hospitalId: hospitalId);
      if (context.mounted) {
        showWhatsappSuccess(
          context,
          'Template submitted to Meta for approval.',
        );
      }
    } on WhatsappApiException catch (e) {
      if (context.mounted) showWhatsappError(context, e);
    } catch (e) {
      if (context.mounted) showWhatsappError(context, e);
    }
  }
}

class _TemplateCard extends StatelessWidget {
  final WhatsappTemplate template;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onSync;

  const _TemplateCard({
    required this.template,
    required this.onEdit,
    required this.onDelete,
    required this.onSync,
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
            Row(
              children: [
                Expanded(
                  child: Text(
                    template.templateName,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _statusChip(template.status),
                const SizedBox(width: 8),
                if (template.isActive)
                  Icon(
                    Icons.check_circle,
                    size: 18,
                    color: theme.colorScheme.primary,
                  )
                else
                  Icon(Icons.block, size: 18, color: theme.colorScheme.error),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${template.language.toUpperCase()} • ${template.category}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              template.body,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Submit to Meta',
                  icon: const Icon(Icons.cloud_upload_outlined, size: 20),
                  onPressed: onSync,
                ),
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: onEdit,
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: Colors.red,
                  ),
                  onPressed: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String status) {
    final color = switch (status.toLowerCase()) {
      'approved' => Colors.green,
      'rejected' => Colors.red,
      'paused' => Colors.orange,
      _ => Colors.blueGrey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _TemplateFormDialog extends StatefulWidget {
  final WhatsappTemplate? template;
  const _TemplateFormDialog({this.template});

  @override
  State<_TemplateFormDialog> createState() => _TemplateFormDialogState();
}

class _TemplateFormDialogState extends State<_TemplateFormDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _bodyController;
  late final TextEditingController _headerTextController;
  late final TextEditingController _footerTextController;
  late final TextEditingController _buttonsController;

  String _language = 'en';
  String _category = 'MARKETING';
  String _headerType = 'none';
  String _status = 'pending';
  bool _isActive = true;

  static const _categories = ['MARKETING', 'UTILITY', 'AUTHENTICATION'];
  static const _headerTypes = ['none', 'text', 'image', 'video', 'document'];

  bool get _isEdit => widget.template != null;

  @override
  void initState() {
    super.initState();
    final t = widget.template;
    _nameController = TextEditingController(text: t?.templateName ?? '');
    _bodyController = TextEditingController(text: t?.body ?? '');
    _headerTextController = TextEditingController(text: t?.headerText ?? '');
    _footerTextController = TextEditingController(text: t?.footerText ?? '');
    _buttonsController = TextEditingController(
      text: t == null || t.buttons.isEmpty ? '' : _prettyJson(t.buttons),
    );
    _language = t?.language ?? 'en';
    _category = t?.category ?? 'MARKETING';
    _headerType = (t?.headerType.isNotEmpty == true ? t!.headerType : 'none');
    _status = t?.status ?? 'pending';
    _isActive = t?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bodyController.dispose();
    _headerTextController.dispose();
    _footerTextController.dispose();
    _buttonsController.dispose();
    super.dispose();
  }

  String _prettyJson(List<Map<String, dynamic>> buttons) {
    return const JsonEncoder.withIndent('  ').convert(buttons);
  }

  List<Map<String, dynamic>> _parseButtons() {
    final text = _buttonsController.text.trim();
    if (text.isEmpty) return [];
    try {
      final decoded = jsonDecode(text);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  void _save() {
    final name = _nameController.text.trim();
    final body = _bodyController.text.trim();
    if (name.isEmpty || body.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Template name and body are required.')),
      );
      return;
    }
    if (_buttonsController.text.trim().isNotEmpty && _parseButtons().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Buttons must be a valid JSON array.')),
      );
      return;
    }

    Navigator.pop(context, {
      'template_name': name,
      'language': _language,
      'category': _category,
      'body': body,
      'header_type': _headerType,
      'header_text': _headerTextController.text.trim(),
      'footer_text': _footerTextController.text.trim(),
      'buttons': _parseButtons(),
      'status': _status,
      'is_active': _isActive,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit Template' : 'New Template'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Template Name *',
                  hintText: 'Lowercase_with_underscores, e.g. appt_reminder',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _language,
                      decoration: const InputDecoration(labelText: 'Language'),
                      items: ['en', 'hi', 'mr', 'gu', 'ta', 'te', 'kn', 'bn']
                          .map(
                            (l) => DropdownMenuItem(value: l, child: Text(l)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _language = v!),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _category,
                      decoration: const InputDecoration(labelText: 'Category'),
                      items: _categories
                          .map(
                            (c) => DropdownMenuItem(value: c, child: Text(c)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _category = v!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _bodyController,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Body *',
                  hintText:
                      'Message body. Use {{1}}, {{2}} for variables.\n'
                      'Example: Dear {{1}}, your appointment is on {{2}}.',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _headerType,
                      decoration: const InputDecoration(labelText: 'Header'),
                      items: _headerTypes
                          .map(
                            (h) => DropdownMenuItem(value: h, child: Text(h)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _headerType = v!),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _headerTextController,
                      decoration: const InputDecoration(
                        labelText: 'Header Text',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _footerTextController,
                decoration: const InputDecoration(labelText: 'Footer Text'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _buttonsController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Buttons (JSON array)',
                  hintText:
                      '[{"type":"QUICK_REPLY","text":"Book Now"}]\n'
                      'or [{"type":"URL","text":"Visit","url":"https://..."}]',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(labelText: 'Meta Status'),
                items: ['pending', 'approved', 'rejected', 'paused']
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: (v) => setState(() => _status = v!),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Active'),
                value: _isActive,
                onChanged: (v) => setState(() => _isActive = v),
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
        ElevatedButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
