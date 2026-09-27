/// Presentation layer: the error surfaces that render
/// `DocumentAppState.transientError` to the user — [ErrorBanner], a persistent
/// dark-themed banner, and [showErrorSnackBar], a helper for transient
/// notifications (Req 1.6, 2.5, 3.4, 5.3, 7.5).
///
/// Both surfaces present a recoverable error message; the state layer retains
/// the underlying data unchanged (e.g. the previous Document_List, the previous
/// Active_Document, or the unsaved in-memory edits) while the message is shown,
/// per the referenced acceptance criteria. Colors are drawn only from
/// [AppPalette] so no surface falls back to a light-mode / default color
/// (Req 8.5).
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A persistent, dark-themed banner that displays a recoverable error
/// [message], with an optional dismiss affordance (Req 1.6, 7.5).
///
/// Used where an error should remain visible until resolved or dismissed — for
/// example the Sidebar's list-load-failure banner (Req 1.6). For transient
/// notifications that auto-dismiss, prefer [showErrorSnackBar].
class ErrorBanner extends StatelessWidget {
  /// The error message to display.
  final String message;

  /// Called when the user taps the dismiss affordance. When `null`, no dismiss
  /// control is shown.
  final VoidCallback? onDismiss;

  const ErrorBanner({
    super.key,
    required this.message,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        // A raised surface tint drawn from the palette (Req 8.5), with a
        // left accent bar in the error color for emphasis.
        color: AppPalette.surfaceVariant,
        border: Border(
          left: BorderSide(color: AppPalette.error, width: 4),
        ),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.error_outline,
            color: AppPalette.error,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppPalette.textPrimary),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(
                Icons.close,
                color: AppPalette.textSecondary,
                size: 18,
              ),
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }
}

/// Surfaces a transient error [message] as a [SnackBar] via the nearest
/// [ScaffoldMessenger] (Req 2.5, 3.4, 5.3, 7.5).
///
/// Any in-flight snackbar is cleared first so a fresh error is shown promptly.
/// Colors come from the dark [SnackBarTheme] in `AppTheme.dark` plus the palette
/// error accent (Req 8.5). Intended for the Shell / Sidebar to present
/// `DocumentAppState.transientError` when it is set by a failed create, open,
/// delete, or save.
void showErrorSnackBar(BuildContext context, String message) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: <Widget>[
            const Icon(
              Icons.error_outline,
              color: AppPalette.error,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: AppPalette.textPrimary),
              ),
            ),
          ],
        ),
        backgroundColor: AppPalette.surfaceVariant,
        behavior: SnackBarBehavior.floating,
      ),
    );
}
