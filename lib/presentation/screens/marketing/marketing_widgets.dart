import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/marketing_constants.dart';

/// ---------------------------------------------------------------------------
/// Small shared widgets/helpers for the PRO / Marketing screens.
/// UI-only formatting; no Supabase or geofence logic lives here.
/// ---------------------------------------------------------------------------

String marketingPractitionerTypeLabel(String type) {
  switch (type) {
    case MarketingConstants.practitionerTypeRegistered:
      return 'Registered Practitioner';
    case MarketingConstants.practitionerTypeLocal:
      return 'Local Practitioner';
    case MarketingConstants.practitionerTypeClinic:
      return 'Clinic';
    case MarketingConstants.practitionerTypeOther:
      return 'Other';
    default:
      return type.isEmpty ? '—' : type;
  }
}

String formatMarketingDate(DateTime? value) {
  if (value == null) return '—';
  return DateFormat('dd MMM yyyy').format(value);
}

String formatMarketingDateTime(DateTime? value) {
  if (value == null) return '—';
  return DateFormat('dd MMM yyyy, hh:mm a').format(value.toLocal());
}

String formatMarketingTime(DateTime? value) {
  if (value == null) return '—';
  return DateFormat('hh:mm a').format(value.toLocal());
}

String formatMarketingDistance(double? meters) {
  if (meters == null) return '—';
  if (meters < 1000) return '${meters.round()} m';
  return '${(meters / 1000).toStringAsFixed(2)} km';
}

/// Reusable "Geo Verified / Not Verified" chip for visits and doctors.
class GeoVerifiedChip extends StatelessWidget {
  const GeoVerifiedChip({super.key, required this.verified});

  final bool verified;

  @override
  Widget build(BuildContext context) {
    final color = verified ? Colors.green.shade800 : Colors.orange.shade900;
    final background = verified
        ? Colors.green.withValues(alpha: 0.14)
        : Colors.orange.withValues(alpha: 0.16);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            verified ? Icons.gps_fixed : Icons.gps_not_fixed,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            verified ? 'Geo Verified' : 'Not Verified',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }
}

/// Reusable error + retry view for marketing FutureProviders.
class MarketingErrorRetry extends StatelessWidget {
  const MarketingErrorRetry({
    super.key,
    required this.message,
    required this.error,
    required this.onRetry,
  });

  final String message;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              style: theme.textTheme.bodySmall,
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

class MarketingEmptyState extends StatelessWidget {
  const MarketingEmptyState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.campaign_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// Renders a compact metric label/value pair.
class MarketingMetric extends StatelessWidget {
  const MarketingMetric({
    super.key,
    required this.label,
    required this.value,
  });

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
