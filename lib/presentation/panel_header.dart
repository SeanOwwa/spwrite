/// Presentation layer: [PanelHeader], the shared header used by the right-hand
/// side panels (Characters, AI assistant) so they read as one consistent
/// family: an accent icon chip, a title with an optional caption, and trailing
/// icon-button actions, over a hairline bottom border. Colors come from
/// [AppPalette].
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A side-panel header: icon chip, title / subtitle, and trailing [actions].
class PanelHeader extends StatelessWidget {
  /// The accent icon shown in the leading chip.
  final IconData icon;

  /// The panel title (announced as a heading).
  final String title;

  /// An optional low-emphasis caption under the title.
  final String? subtitle;

  /// Trailing controls (typically [IconButton]s with tooltips).
  final List<Widget> actions;

  const PanelHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actions = const <Widget>[],
  });

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        gradient: AppStyle.panelSurface,
        border: Border(bottom: BorderSide(color: AppPalette.hairline)),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppPalette.surfaceVariant,
              borderRadius: AppStyle.pillRadius,
              border: Border.all(color: AppPalette.hairline),
            ),
            child: Icon(icon, size: 18, color: AppPalette.secondary),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}
