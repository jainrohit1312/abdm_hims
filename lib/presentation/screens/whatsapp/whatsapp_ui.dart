import 'package:flutter/material.dart';

import '../../../services/whatsapp_service.dart';

/// ---------------------------------------------------------------------------
/// WhatsApp Module — UI feedback helpers
/// ---------------------------------------------------------------------------
/// The global `ErrorHandler` intentionally maps unknown exceptions to a
/// generic message. The WhatsApp module needs to surface Meta API errors
/// (invalid token, rate limits, template not approved, ...) verbatim, so the
/// screens use these small helpers instead.
/// ---------------------------------------------------------------------------

/// Shows a user-friendly error snackbar. [WhatsappApiException] messages are
/// already written for end users, so they are shown as-is.
void showWhatsappError(BuildContext context, Object? error) {
  String message;
  if (error is WhatsappApiException) {
    message = error.message;
  } else {
    final raw = error?.toString() ?? '';
    message = raw.trim().isEmpty
        ? 'Something went wrong. Please try again.'
        : raw;
  }

  final theme = Theme.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.onError),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ],
      ),
      backgroundColor: theme.colorScheme.error,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(16),
      action: SnackBarAction(
        label: 'Dismiss',
        textColor: theme.colorScheme.onError,
        onPressed: () {},
      ),
    ),
  );
}

/// Shows a green success snackbar.
void showWhatsappSuccess(BuildContext context, String message) {
  final theme = Theme.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Icon(Icons.check_circle_outline, color: theme.colorScheme.onPrimary),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ],
      ),
      backgroundColor: Colors.green,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(16),
    ),
  );
}
