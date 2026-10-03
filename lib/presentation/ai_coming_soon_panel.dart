/// Presentation layer: [AiComingSoonPanel], shown in the AI panel slot while
/// the assistant is turned off ([AppInfo.aiAssistantAvailable] is `false`).
///
/// It has no download button and reads no AI state, so nothing AI-related
/// (model download, indexing) can start from it.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'panel_header.dart';

/// A friendly "Coming soon" placeholder for the AI assistant.
class AiComingSoonPanel extends StatelessWidget {
  /// Closes the panel.
  final VoidCallback onClose;

  const AiComingSoonPanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      color: AppPalette.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PanelHeader(
            icon: Icons.auto_awesome,
            title: 'AI assistant',
            subtitle: 'Coming soon',
            actions: <Widget>[
              IconButton(
                tooltip: 'Close',
                icon: const Icon(
                  Icons.close,
                  color: AppPalette.textSecondary,
                ),
                onPressed: onClose,
              ),
            ],
          ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: AppPalette.surfaceVariant,
                        borderRadius: AppStyle.cardRadius,
                        border: Border.all(color: AppPalette.hairline),
                      ),
                      child: const Icon(
                        Icons.auto_awesome,
                        size: 30,
                        color: AppPalette.secondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.xs,
                      ),
                      decoration: BoxDecoration(
                        color: AppPalette.surfaceVariant,
                        borderRadius: AppStyle.pillRadius,
                        border: Border.all(color: AppPalette.hairline),
                      ),
                      child: Text(
                        'Coming soon',
                        style: text.labelLarge?.copyWith(
                          color: AppPalette.secondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'A private, on-device assistant that answers questions '
                      'about your documents and characters is on its way.',
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(
                        color: AppPalette.textSecondary,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      "We're polishing it before release. Nothing needs to be "
                      'downloaded yet.',
                      textAlign: TextAlign.center,
                      style: text.bodySmall?.copyWith(
                        color: AppPalette.textSecondary,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
