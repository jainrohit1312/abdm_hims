import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/whatsapp_providers.dart';
import '../../../models/whatsapp_models.dart';
import '../../../services/whatsapp_service.dart';
import '../../widgets/smart_navigation.dart';
import 'whatsapp_ui.dart';

/// ---------------------------------------------------------------------------
/// WhatsApp Campaigns Screen (`/whatsapp/campaigns`)
/// ---------------------------------------------------------------------------
/// Broadcast campaigns: choose a Meta template, select opted-in patients, then
/// send immediately or schedule for later. Every per-patient attempt is logged
/// in `whatsapp_messages` and the campaign counters are updated as we go.
/// ---------------------------------------------------------------------------
class WhatsappCampaignsScreen extends ConsumerStatefulWidget {
  const WhatsappCampaignsScreen({super.key});

  @override
  ConsumerState<WhatsappCampaignsScreen> createState() =>
      _WhatsappCampaignsScreenState();
}

class _WhatsappCampaignsScreenState
    extends ConsumerState<WhatsappCampaignsScreen> {
  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('WhatsApp Campaigns'),
        isRootPage: false,
      ),
      floatingActionButton: hospitalId == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openComposer(hospitalId),
              icon: const Icon(Icons.add),
              label: const Text('New Campaign'),
            ),
      body: hospitalId == null
          ? const Center(child: Text('Hospital not assigned to this user.'))
          : ref
                .watch(whatsappCampaignsProvider(hospitalId))
                .when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Failed to load campaigns: $error'),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () => ref.invalidate(
                            whatsappCampaignsProvider(hospitalId),
                          ),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                  data: (campaigns) {
                    if (campaigns.isEmpty) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No campaigns yet.\nTap + to create a broadcast campaign.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: campaigns.length,
                      itemBuilder: (context, index) =>
                          _CampaignCard(campaign: campaigns[index]),
                    );
                  },
                ),
    );
  }

  Future<void> _openComposer(String hospitalId) async {
    final draft = await showDialog<_CampaignDraft>(
      context: context,
      builder: (_) => _CampaignComposerDialog(hospitalId: hospitalId),
    );
    if (draft == null || !mounted) return;

    try {
      final db = ref.read(whatsappDbServiceProvider);
      final createdBy =
          await ref.read(databaseServiceProvider).getCurrentUsersTableId() ??
          '';
      final campaign = WhatsappCampaign(
        hospitalId: hospitalId,
        templateId: draft.templateId,
        name: draft.name,
        messageBody: draft.messageBody,
        recipients: draft.recipients.map((r) => r.toMap()).toList(),
        status: draft.action == 'send' ? 'sending' : draft.action,
        scheduledAt: draft.scheduledAt,
        createdBy: createdBy,
      );
      final created = await db.createCampaign(campaign);

      if (draft.action == 'send') {
        await _broadcast(created, draft.recipients);
      }

      invalidateWhatsappProviders(ref, hospitalId: hospitalId);
      if (!mounted) return;
      showWhatsappSuccess(
        context,
        draft.action == 'send'
            ? 'Campaign "${draft.name}" sent.'
            : draft.action == 'scheduled'
            ? 'Campaign scheduled for ${_formatDate(draft.scheduledAt)}.'
            : 'Campaign saved as draft.',
      );
    } catch (e) {
      if (!mounted) return;
      showWhatsappError(context, e);
    }
  }

  /// Sends the campaign message to every selected recipient sequentially.
  /// A tiny inter-message delay keeps the flow well under Meta's rate limit.
  Future<void> _broadcast(
    WhatsappCampaign campaign,
    List<WhatsappRecipient> recipients,
  ) async {
    final db = ref.read(whatsappDbServiceProvider);
    final service = ref.read(whatsappServiceProvider);

    final settings = await db.getSettings(campaign.hospitalId);
    if (settings == null || !settings.isConfigured) {
      await db.updateCampaignStatus(campaign.id, status: 'failed');
      throw const WhatsappApiException(
        message: 'WhatsApp API is not configured. Open Settings first.',
        errorCode: 'NOT_CONFIGURED',
      );
    }

    WhatsappTemplate? template;
    if (campaign.templateId.isNotEmpty) {
      final templates = await db.getTemplates(campaign.hospitalId);
      for (final t in templates) {
        if (t.id == campaign.templateId) {
          template = t;
          break;
        }
      }
    }

    var sent = 0;
    var failed = 0;
    final logs = <WhatsappMessage>[];

    for (final recipient in recipients) {
      if (!WhatsappService.isValidPhone(recipient.phoneNumber)) {
        logs.add(
          WhatsappMessage(
            hospitalId: campaign.hospitalId,
            campaignId: campaign.id,
            patientId: recipient.patientId,
            phoneNumber: recipient.phoneNumber,
            templateId: campaign.templateId,
            messageBody: campaign.messageBody,
            status: 'failed',
            errorMessage: 'Invalid phone number',
          ),
        );
        failed++;
        continue;
      }

      try {
        final Map<String, dynamic> response;
        if (template != null) {
          response = await service.sendTemplateMessage(
            accessToken: settings.apiKey,
            phoneNumberId: settings.phoneNumberId,
            to: recipient.phoneNumber,
            templateName: template.templateName,
            languageCode: template.language,
          );
        } else {
          response = await service.sendTextMessage(
            accessToken: settings.apiKey,
            phoneNumberId: settings.phoneNumberId,
            to: recipient.phoneNumber,
            body: campaign.messageBody,
          );
        }

        final messageId = _extractMessageId(response);
        logs.add(
          WhatsappMessage(
            hospitalId: campaign.hospitalId,
            campaignId: campaign.id,
            patientId: recipient.patientId,
            phoneNumber: recipient.phoneNumber,
            templateId: campaign.templateId,
            messageBody: campaign.messageBody,
            messageId: messageId,
            status: 'sent',
            sentAt: DateTime.now(),
          ),
        );
        sent++;
      } on WhatsappApiException catch (e) {
        logs.add(
          WhatsappMessage(
            hospitalId: campaign.hospitalId,
            campaignId: campaign.id,
            patientId: recipient.patientId,
            phoneNumber: recipient.phoneNumber,
            templateId: campaign.templateId,
            messageBody: campaign.messageBody,
            status: 'failed',
            errorMessage: e.message,
          ),
        );
        failed++;
      } catch (e) {
        logs.add(
          WhatsappMessage(
            hospitalId: campaign.hospitalId,
            campaignId: campaign.id,
            patientId: recipient.patientId,
            phoneNumber: recipient.phoneNumber,
            templateId: campaign.templateId,
            messageBody: campaign.messageBody,
            status: 'failed',
            errorMessage: e.toString(),
          ),
        );
        failed++;
      }

      // Batched logging every 25 messages keeps inserts efficient.
      if (logs.length >= 25) {
        await db.logMessages(logs);
        logs.clear();
      }
      await Future.delayed(const Duration(milliseconds: 80));
    }

    if (logs.isNotEmpty) {
      await db.logMessages(logs);
    }

    await db.updateCampaignStatus(
      campaign.id,
      status: 'sent',
      sentCount: sent,
      failedCount: failed,
      sentAt: DateTime.now(),
    );
  }

  String _extractMessageId(Map<String, dynamic> response) {
    final messages = response['messages'];
    if (messages is List && messages.isNotEmpty && messages.first is Map) {
      return (messages.first as Map)['id']?.toString() ?? '';
    }
    return '';
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '-';
    final d = date.toLocal();
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day}-${d.month}-${d.year} $hh:$mm';
  }
}

/// Result object returned by the composer dialog.
class _CampaignDraft {
  final String name;
  final String templateId;
  final String messageBody;
  final List<WhatsappRecipient> recipients;
  final String action; // draft | scheduled | send
  final DateTime? scheduledAt;

  const _CampaignDraft({
    required this.name,
    required this.templateId,
    required this.messageBody,
    required this.recipients,
    required this.action,
    this.scheduledAt,
  });
}

class _CampaignCard extends StatelessWidget {
  final WhatsappCampaign campaign;
  const _CampaignCard({required this.campaign});

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
                    campaign.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _statusChip(campaign.status),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${campaign.recipients.length} recipient(s) • '
              '${_formatDate(campaign.scheduledAt)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              campaign.messageBody,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: campaign.totalCount == 0
                  ? 0
                  : (campaign.deliveredCount + campaign.readCount) /
                        campaign.totalCount,
              minHeight: 6,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat('Sent', campaign.sentCount, theme.colorScheme.primary),
                _stat('Delivered', campaign.deliveredCount, Colors.teal),
                _stat('Read', campaign.readCount, Colors.green),
                _stat('Failed', campaign.failedCount, theme.colorScheme.error),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, int value, Color color) {
    return Column(
      children: [
        Text(
          '$value',
          style: TextStyle(fontWeight: FontWeight.bold, color: color),
        ),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Widget _statusChip(String status) {
    final color = switch (status.toLowerCase()) {
      'sent' => Colors.green,
      'sending' => Colors.blue,
      'scheduled' => Colors.orange,
      'failed' => Colors.red,
      'cancelled' => Colors.grey,
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

  String _formatDate(DateTime? date) {
    if (date == null) return 'Send now';
    final d = date.toLocal();
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day}-${d.month}-${d.year} $hh:$mm';
  }
}

class _CampaignComposerDialog extends ConsumerStatefulWidget {
  final String hospitalId;
  const _CampaignComposerDialog({required this.hospitalId});

  @override
  ConsumerState<_CampaignComposerDialog> createState() =>
      _CampaignComposerDialogState();
}

class _CampaignComposerDialogState
    extends ConsumerState<_CampaignComposerDialog> {
  final _nameController = TextEditingController();
  final _bodyController = TextEditingController();

  String _templateId = '';
  DateTime? _scheduledAt;
  final Set<String> _selectedPatientIds = {};
  bool _scheduleEnabled = false;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final templatesAsync = ref.watch(
      whatsappTemplatesProvider(widget.hospitalId),
    );
    final audienceAsync = ref.watch(
      whatsappAudienceProvider(widget.hospitalId),
    );

    return AlertDialog(
      title: const Text('New Campaign'),
      content: SizedBox(
        width: 640,
        height: 560,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Campaign Name *',
                        hintText: 'e.g. Diwali Health Camp Reminder',
                      ),
                    ),
                    const SizedBox(height: 12),
                    templatesAsync.when(
                      loading: () => const LinearProgressIndicator(),
                      error: (e, _) => Text('Templates error: $e'),
                      data: (templates) {
                        if (templates.isEmpty) {
                          return const Card(
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: Text(
                                'No templates available. Create a template first '
                                '(or leave template empty to send a text message).',
                              ),
                            ),
                          );
                        }
                        return DropdownButtonFormField<String>(
                          initialValue: _templateId.isEmpty
                              ? null
                              : _templateId,
                          decoration: const InputDecoration(
                            labelText: 'Template (optional)',
                          ),
                          items: [
                            const DropdownMenuItem<String>(
                              value: '',
                              child: Text('— Plain text message —'),
                            ),
                            ...templates.map(
                              (t) => DropdownMenuItem(
                                value: t.id,
                                child: Text(
                                  '${t.templateName} (${t.language}, ${t.status})',
                                ),
                              ),
                            ),
                          ],
                          onChanged: (v) {
                            setState(() {
                              _templateId = v ?? '';
                              final selected = templates
                                  .where((t) => t.id == _templateId)
                                  .toList();
                              if (selected.isNotEmpty) {
                                _bodyController.text = selected.first.body;
                              }
                            });
                          },
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _bodyController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Message Body *',
                        hintText: 'Promotional or transactional message text',
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Recipients (opted-in patients)',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    audienceAsync.when(
                      loading: () => const LinearProgressIndicator(),
                      error: (e, _) => Text('Audience error: $e'),
                      data: (recipients) {
                        if (recipients.isEmpty) {
                          return const Card(
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: Text(
                                'No opted-in patients found. Add opt-ins from '
                                'OPD/IPD registration or the patient profile.',
                              ),
                            ),
                          );
                        }
                        return Column(
                          children: [
                            CheckboxListTile(
                              value:
                                  _selectedPatientIds.length ==
                                  recipients.length,
                              onChanged: (v) => setState(() {
                                _selectedPatientIds
                                  ..clear()
                                  ..addAll(
                                    v == true
                                        ? recipients
                                              .map((r) => r.patientId)
                                              .toList()
                                        : const [],
                                  );
                              }),
                              title: const Text('Select all'),
                              dense: true,
                            ),
                            const Divider(height: 1),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 160),
                              child: ListView(
                                shrinkWrap: true,
                                children: recipients
                                    .map(
                                      (r) => CheckboxListTile(
                                        value: _selectedPatientIds.contains(
                                          r.patientId,
                                        ),
                                        onChanged: (v) => setState(() {
                                          if (v == true) {
                                            _selectedPatientIds.add(
                                              r.patientId,
                                            );
                                          } else {
                                            _selectedPatientIds.remove(
                                              r.patientId,
                                            );
                                          }
                                        }),
                                        title: Text(r.name),
                                        subtitle: Text(
                                          '${r.uhid.isEmpty ? 'No UHID' : r.uhid} • '
                                          '${r.phoneNumber} • ${r.source.toUpperCase()}',
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                        dense: true,
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Schedule for later'),
                      value: _scheduleEnabled,
                      onChanged: (v) => setState(() {
                        _scheduleEnabled = v;
                        if (!v) _scheduledAt = null;
                      }),
                    ),
                    if (_scheduleEnabled)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.schedule),
                        title: Text(
                          _scheduledAt == null
                              ? 'Pick date & time'
                              : _formatDate(_scheduledAt!),
                        ),
                        onTap: _pickSchedule,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _isSubmitting ? null : () => _submit('draft'),
          child: const Text('Save Draft'),
        ),
        TextButton(
          onPressed: _isSubmitting ? null : () => _submit('scheduled'),
          child: const Text('Schedule'),
        ),
        ElevatedButton(
          onPressed: _isSubmitting ? null : () => _submit('send'),
          child: _isSubmitting
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Send Now'),
        ),
      ],
    );
  }

  Future<void> _pickSchedule() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      initialDate: _scheduledAt ?? now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_scheduledAt ?? now),
    );
    if (time == null || !mounted) return;
    setState(() {
      _scheduledAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  void _submit(String action) {
    final name = _nameController.text.trim();
    final body = _bodyController.text.trim();
    if (name.isEmpty || body.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Campaign name and message body are required.'),
        ),
      );
      return;
    }
    if (_selectedPatientIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one recipient.')),
      );
      return;
    }
    if (action == 'scheduled' && _scheduledAt == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a schedule date first.')),
      );
      return;
    }

    final audience = ref.read(whatsappAudienceProvider(widget.hospitalId));
    final recipients =
        audience.valueOrNull
            ?.where((r) => _selectedPatientIds.contains(r.patientId))
            .toList() ??
        const <WhatsappRecipient>[];

    if (recipients.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No recipients resolved. Please try again.')),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    Navigator.pop(
      context,
      _CampaignDraft(
        name: name,
        templateId: _templateId,
        messageBody: body,
        recipients: recipients,
        action: action,
        scheduledAt: _scheduledAt,
      ),
    );
  }

  String _formatDate(DateTime date) {
    final d = date.toLocal();
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day}-${d.month}-${d.year} $hh:$mm';
  }
}
