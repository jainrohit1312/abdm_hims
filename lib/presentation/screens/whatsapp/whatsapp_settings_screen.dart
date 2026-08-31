import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/whatsapp_providers.dart';
import '../../../models/whatsapp_models.dart';
import '../../../services/whatsapp_service.dart';
import '../../widgets/smart_navigation.dart';
import 'whatsapp_ui.dart';

/// ---------------------------------------------------------------------------
/// WhatsApp Settings Screen (`/whatsapp/settings`)
/// ---------------------------------------------------------------------------
/// Per-hospital Meta WhatsApp Cloud API credential management. The access
/// token is encrypted by `WhatsappKeyCipher` before it is written to Supabase.
/// ---------------------------------------------------------------------------
class WhatsappSettingsScreen extends ConsumerStatefulWidget {
  const WhatsappSettingsScreen({super.key});

  @override
  ConsumerState<WhatsappSettingsScreen> createState() =>
      _WhatsappSettingsScreenState();
}

class _WhatsappSettingsScreenState
    extends ConsumerState<WhatsappSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _apiKeyController = TextEditingController();
  final _phoneNumberIdController = TextEditingController();
  final _businessAccountIdController = TextEditingController();
  final _webhookTokenController = TextEditingController();

  bool _obscureApiKey = true;
  bool _isActive = true;
  bool _isSaving = false;
  bool _isTesting = false;
  bool _loaded = false;

  @override
  void dispose() {
    _apiKeyController.dispose();
    _phoneNumberIdController.dispose();
    _businessAccountIdController.dispose();
    _webhookTokenController.dispose();
    super.dispose();
  }

  void _fillForm(WhatsappSettings? settings) {
    if (_loaded || settings == null) return;
    _loaded = true;
    _apiKeyController.text = settings.apiKey;
    _phoneNumberIdController.text = settings.phoneNumberId;
    _businessAccountIdController.text = settings.businessAccountId;
    _webhookTokenController.text = settings.webhookVerifyToken;
    _isActive = settings.isActive;
  }

  Future<void> _save() async {
    if (_formKey.currentState?.validate() != true) return;
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) {
      showWhatsappError(context, 'Hospital is not assigned to this user.');
      return;
    }

    setState(() => _isSaving = true);
    try {
      final settings = WhatsappSettings(
        hospitalId: hospitalId,
        apiKey: _apiKeyController.text.trim(),
        phoneNumberId: _phoneNumberIdController.text.trim(),
        businessAccountId: _businessAccountIdController.text.trim(),
        webhookVerifyToken: _webhookTokenController.text.trim(),
        isActive: _isActive,
      );
      await ref.read(whatsappDbServiceProvider).saveSettings(settings);
      invalidateWhatsappProviders(ref, hospitalId: hospitalId);
      if (!mounted) return;
      showWhatsappSuccess(context, 'WhatsApp settings saved.');
    } catch (e) {
      if (!mounted) return;
      showWhatsappError(context, e);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _testConnection() async {
    final apiKey = _apiKeyController.text.trim();
    final phoneNumberId = _phoneNumberIdController.text.trim();
    final businessAccountId = _businessAccountIdController.text.trim();
    if (apiKey.isEmpty ||
        (phoneNumberId.isEmpty && businessAccountId.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter the API key and phone number / business account id first.',
          ),
        ),
      );
      return;
    }

    setState(() => _isTesting = true);
    try {
      final service = ref.read(whatsappServiceProvider);
      if (businessAccountId.isNotEmpty) {
        await service.getPhoneNumbers(
          accessToken: apiKey,
          businessAccountId: businessAccountId,
        );
      } else {
        await service.getPhoneNumberInfo(
          accessToken: apiKey,
          phoneNumberId: phoneNumberId,
        );
      }
      if (!mounted) return;
      showWhatsappSuccess(
        context,
        'Connection successful. Your Meta credentials are valid.',
      );
    } on WhatsappApiException catch (e) {
      if (!mounted) return;
      showWhatsappError(context, e);
    } catch (e) {
      if (!mounted) return;
      showWhatsappError(context, e);
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    final settingsAsync = hospitalId == null
        ? null
        : ref.watch(whatsappSettingsProvider(hospitalId));

    // Prefill the form once the existing row arrives.
    settingsAsync?.whenData(_fillForm);

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('WhatsApp Settings'),
        isRootPage: false,
      ),
      body: settingsAsync == null
          ? const Center(child: Text('Hospital not assigned to this user.'))
          : settingsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Failed to load settings: $error'),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () =>
                          ref.invalidate(whatsappSettingsProvider(hospitalId!)),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
              data: (settings) => SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildInfoCard(theme),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _apiKeyController,
                        obscureText: _obscureApiKey,
                        decoration: InputDecoration(
                          labelText: 'Meta Access Token (API Key) *',
                          hintText: 'EAAG... permanent system-user token',
                          prefixIcon: const Icon(Icons.key_outlined),
                          suffixIcon: IconButton(
                            tooltip: _obscureApiKey ? 'Show' : 'Hide',
                            icon: Icon(
                              _obscureApiKey
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                            onPressed: () => setState(
                              () => _obscureApiKey = !_obscureApiKey,
                            ),
                          ),
                        ),
                        validator: (v) => v?.trim().isEmpty == true
                            ? 'Access token is required'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _phoneNumberIdController,
                        decoration: const InputDecoration(
                          labelText: 'WhatsApp Phone Number ID *',
                          hintText: 'e.g. 123456789012345',
                          prefixIcon: Icon(Icons.phone_outlined),
                        ),
                        validator: (v) => v?.trim().isEmpty == true
                            ? 'Phone number id is required'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _businessAccountIdController,
                        decoration: const InputDecoration(
                          labelText: 'WhatsApp Business Account ID',
                          hintText: 'e.g. 987654321098765',
                          prefixIcon: Icon(Icons.business_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _webhookTokenController,
                        decoration: const InputDecoration(
                          labelText: 'Webhook Verify Token',
                          hintText: 'Any secret string, e.g. mediflux-webhook-123',
                          prefixIcon: Icon(Icons.https_outlined),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Active'),
                        subtitle: const Text(
                          'Enable WhatsApp messaging for this hospital',
                        ),
                        value: _isActive,
                        onChanged: (v) => setState(() => _isActive = v),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _isTesting ? null : _testConnection,
                              icon: _isTesting
                                  ? const SizedBox(
                                      height: 16,
                                      width: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.wifi_tethering),
                              label: const Text('Test Connection'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _isSaving ? null : _save,
                              icon: _isSaving
                                  ? const SizedBox(
                                      height: 16,
                                      width: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.save_outlined),
                              label: const Text('Save Settings'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildWebhookHelp(theme),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildInfoCard(ThemeData theme) {
    return Card(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline,
              color: theme.colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'These credentials come from Meta Business Suite → WhatsApp '
                'Manager → API Setup. Each hospital must configure its own '
                'WABA, phone number id and system-user access token. The token '
                'is stored encrypted in Supabase.',
                style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebhookHelp(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Webhook Configuration',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'In the Meta WhatsApp Manager set the callback URL to your '
              'Supabase Edge Function:\n'
              'https://<project-ref>.supabase.co/functions/v1/whatsapp-webhook\n\n'
              'Use the same verify token you entered above. The Edge Function '
              'receives delivery/read/failed status updates and updates the '
              'message history automatically.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
