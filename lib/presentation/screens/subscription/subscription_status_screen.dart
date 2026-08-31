import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../widgets/app_refresh_button.dart';

/// Subscription status + renewal screen (`/subscription`).
///
/// Shows the hospital's trial/subscription state, the available yearly plans,
/// a mock payment gateway (Stripe / UPI / Paytm / Mock Pay) and the complete
/// payment history. When the trial has expired, every other app route is
/// blocked until a plan is purchased here.
class SubscriptionStatusScreen extends ConsumerStatefulWidget {
  const SubscriptionStatusScreen({super.key});

  @override
  ConsumerState<SubscriptionStatusScreen> createState() =>
      _SubscriptionStatusScreenState();
}

class _SubscriptionStatusScreenState extends ConsumerState<SubscriptionStatusScreen> {
  String _selectedPlanId = 'standard';
  String _selectedPaymentMethod = 'mock';
  bool _submitting = false;

  Future<void> _renew() async {
    final authState = ref.read(authStateProvider);
    final hospitalId = authState.hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) return;

    final plan = _plans.firstWhere((p) => p.id == _selectedPlanId);
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _submitting = true);
    try {
      final db = ref.read(databaseServiceProvider);
      await db.updateSubscription(
        hospitalId,
        plan.id,
        365,
        paymentMethod: _selectedPaymentMethod,
        paymentAmount: plan.price,
      );

      ref.invalidate(subscriptionStatusProvider(hospitalId));
      ref.invalidate(paymentHistoryProvider(hospitalId));
      ref.read(authStateProvider.notifier).markSubscriptionActive();

      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Subscription renewed successfully! App unlocked.'),
        ),
      );
      context.go('/dashboard');
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Renewal failed: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final hospitalId = authState.hospitalId;

    if (hospitalId == null || hospitalId.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Subscription')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Hospital context not available.\nPlease login again.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final statusAsync = ref.watch(subscriptionStatusProvider(hospitalId));
    final historyAsync = ref.watch(paymentHistoryProvider(hospitalId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Subscription'),
        actions: [
          AppRefreshButton(
            onRefresh: () {
              ref.invalidate(subscriptionStatusProvider(hospitalId));
              ref.invalidate(paymentHistoryProvider(hospitalId));
              setState(() {});
            },
          ),
        ],
      ),
      body: statusAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _buildError(context, e),
        data: (status) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildStatusCard(context, status),
            const SizedBox(height: 16),
            _buildDateDetails(context, status),
            const SizedBox(height: 24),
            _sectionHeader(context, 'Subscription Plans'),
            const SizedBox(height: 12),
            for (final plan in _plans) ...[
              _buildPlanCard(context, plan),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
            _buildPaymentMethodSelector(context),
            const SizedBox(height: 16),
            _buildRenewButton(context, status),
            const SizedBox(height: 24),
            _sectionHeader(context, 'Payment History'),
            const SizedBox(height: 8),
            historyAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Text('Could not load payment history: $e'),
              data: (payments) => payments.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'No payments yet. Your renewal payments will appear here.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : Column(
                      children: [
                        for (final payment in payments)
                          _buildPaymentTile(context, payment),
                      ],
                    ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI builders
  // ---------------------------------------------------------------------------

  Widget _buildError(BuildContext context, Object error) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            const Text(
              'Could not load subscription status.\n'
              'Run the subscription SQL migration first.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () {
                final hospitalId = ref.read(authStateProvider).hospitalId;
                if (hospitalId != null) {
                  ref.invalidate(subscriptionStatusProvider(hospitalId));
                }
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(BuildContext context, Map<String, dynamic> status) {
    final theme = Theme.of(context);
    final isExpired = status['is_expired'] == true;
    final isTrial = status['is_trial'] == true;

    final Color color;
    final IconData icon;
    final String title;
    final String subtitle;

    if (isExpired) {
      color = theme.colorScheme.error;
      icon = Icons.block;
      title = 'Subscription Expired';
      subtitle =
          'Your free trial has ended. Renew a plan below to continue using MediFlux Hospital Software.';
    } else if (isTrial) {
      color = Colors.orange.shade800;
      icon = Icons.timer_outlined;
      title = 'Free Trial Active';
      subtitle =
          'Trial ends on ${_formatDate(status['trial_end_date'])} '
          '(${status['days_left']} days left). All modules are unlocked.';
    } else {
      color = Colors.green.shade700;
      icon = Icons.verified_outlined;
      title = 'Subscription Active';
      subtitle =
          '${_planLabel(status['subscription_plan'])} plan is active until '
          '${_formatDate(status['subscription_expiry'])}.';
    }

    return Card(
      color: color.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 40),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(subtitle, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _buildDateDetails(BuildContext context, Map<String, dynamic> status) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _detailRow(context, Icons.play_circle_outline, 'Trial Start',
                _formatDate(status['trial_start_date'])),
            const Divider(height: 16),
            _detailRow(context, Icons.event_outlined, 'Trial End',
                _formatDate(status['trial_end_date'])),
            const Divider(height: 16),
            _detailRow(context, Icons.workspace_premium_outlined,
                'Subscription Expiry', _formatDate(status['subscription_expiry'])),
            const Divider(height: 16),
            _detailRow(context, Icons.card_membership, 'Current Plan',
                _planLabel(status['subscription_plan'])),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label, style: theme.textTheme.bodyMedium),
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
    );
  }

  Widget _buildPlanCard(BuildContext context, _Plan plan) {
    final theme = Theme.of(context);
    final selected = plan.id == _selectedPlanId;
    final primary = theme.colorScheme.primary;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? primary : theme.colorScheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _selectedPlanId = plan.id),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? primary : theme.colorScheme.outline,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plan.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      plan.tagline,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '₹${plan.priceLabel}/year',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: primary,
                    ),
                  ),
                  Text(
                    plan.features,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentMethodSelector(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Payment Method (mock gateway)',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final method in _paymentMethods)
              ChoiceChip(
                label: Text(method.label),
                selected: _selectedPaymentMethod == method.id,
                onSelected: (_) =>
                    setState(() => _selectedPaymentMethod = method.id),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Stripe / UPI / Paytm are mocked — no real payment is charged.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  Widget _buildRenewButton(BuildContext context, Map<String, dynamic> status) {
    final plan = _plans.firstWhere((p) => p.id == _selectedPlanId);
    final isExpired = status['is_expired'] == true;

    return ElevatedButton.icon(
      onPressed: _submitting ? null : _renew,
      icon: _submitting
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.lock_open),
      label: Text(
        isExpired
            ? 'Pay ₹${plan.priceLabel} & Renew (${plan.name})'
            : 'Renew Now — ₹${plan.priceLabel}/year',
      ),
      style: ElevatedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildPaymentTile(BuildContext context, Map<String, dynamic> payment) {
    final theme = Theme.of(context);
    final method = payment['payment_method']?.toString() ?? 'mock';
    final status = payment['payment_status']?.toString() ?? 'success';
    final isSuccess = status == 'success';

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            _methodIcon(method),
            size: 20,
            color: theme.colorScheme.primary,
          ),
        ),
        title: Text(
          '₹${_amount(payment['payment_amount']).toStringAsFixed(2)} — '
          '${_planLabel(payment['subscription_plan'])}',
        ),
        subtitle: Text(
          '${_formatDateTime(payment['payment_date'])} • $method',
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: (isSuccess ? Colors.green : theme.colorScheme.error)
                .withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            isSuccess ? 'Paid' : status,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isSuccess ? Colors.green.shade700 : theme.colorScheme.error,
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Formatting helpers
  // ---------------------------------------------------------------------------

  String _formatDate(dynamic iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso.toString());
    if (dt == null) return '—';
    return DateFormat('dd MMM yyyy').format(dt.toLocal());
  }

  String _formatDateTime(dynamic iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso.toString());
    if (dt == null) return '—';
    return DateFormat('dd MMM yyyy, hh:mm a').format(dt.toLocal());
  }

  String _planLabel(dynamic plan) {
    if (plan == null) return 'Trial';
    final text = plan.toString();
    if (text.isEmpty) return 'Trial';
    return text[0].toUpperCase() + text.substring(1);
  }

  double _amount(dynamic value) {
    if (value == null) return 0;
    return double.tryParse(value.toString()) ?? 0;
  }

  IconData _methodIcon(String method) {
    switch (method) {
      case 'stripe':
        return Icons.credit_card;
      case 'upi':
        return Icons.qr_code;
      case 'paytm':
        return Icons.account_balance_wallet_outlined;
      default:
        return Icons.payments_outlined;
    }
  }
}

// -----------------------------------------------------------------------------
// Plans & payment methods
// -----------------------------------------------------------------------------

class _Plan {
  const _Plan({
    required this.id,
    required this.name,
    required this.price,
    required this.tagline,
    required this.features,
  });

  final String id;
  final String name;
  final double price;
  final String tagline;
  final String features;

  String get priceLabel => price.toStringAsFixed(0);
}

const List<_Plan> _plans = [
  _Plan(
    id: 'basic',
    name: 'Basic Plan',
    price: 10000,
    tagline: 'For small clinics',
    features: 'OPD • IPD • Billing',
  ),
  _Plan(
    id: 'standard',
    name: 'Standard Plan',
    price: 15000,
    tagline: 'For growing hospitals',
    features: 'Everything in Basic + Lab',
  ),
  _Plan(
    id: 'premium',
    name: 'Premium Plan',
    price: 20000,
    tagline: 'For multi-speciality hospitals',
    features: 'Everything + Pharmacy + ABDM',
  ),
];

const List<_PaymentMethod> _paymentMethods = [
  _PaymentMethod(id: 'mock', label: 'Mock Pay'),
  _PaymentMethod(id: 'stripe', label: 'Stripe'),
  _PaymentMethod(id: 'upi', label: 'UPI'),
  _PaymentMethod(id: 'paytm', label: 'Paytm'),
];

class _PaymentMethod {
  const _PaymentMethod({required this.id, required this.label});

  final String id;
  final String label;
}
