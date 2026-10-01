/// Presentation layer: [ProjectCard], one tile of the Dashboard's project
/// grid.
///
/// A card is a portrait book-cover tile: the project's cover photo (or the
/// colorful initial badge when it has none) on top at a 1:1.6 ratio, and a
/// footer with the project's Name (Req 1.1), its last-edited date, and the
/// edit (Req 3.1) and delete (Req 4.1) controls. Tapping / pressing Enter on
/// the card opens the project (Req 5.1).
///
/// It holds no persistence or navigation logic itself: the gestures are
/// surfaced as callbacks ([onOpen], [onRename], [onDelete]) that the
/// `DashboardView` wires to the corresponding `AppNavigationState` intents.
/// This keeps the tile a pure, testable widget.
///
/// Every color the card assigns is drawn from [AppPalette] so the tile never
/// falls back to a light-mode or system-default color (Req 18.2, 18.5).
library;

import 'package:flutter/material.dart';

import '../domain/project.dart';
import '../theme/app_theme.dart';
import 'project_cover.dart';

export 'project_cover.dart' show kUntitledProjectPlaceholder, projectDisplayName;

/// Formats [when] (UTC) as a short local date such as "Sep 3, 2026".
String formatProjectDate(DateTime when) {
  const List<String> months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final DateTime local = when.toLocal();
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}

/// A single project tile on the Dashboard: cover on top, name / date /
/// controls below. Colors come only from [AppPalette] (Req 18.2, 18.5).
class ProjectCard extends StatefulWidget {
  /// The height of the footer below the cover. The Dashboard grid sizes each
  /// cell as `width × 1.6 + footerHeight` so the cover keeps its 1:1.6 shape.
  static const double footerHeight = 64;

  /// The Project this tile represents. Its stored [Project.name] is read but
  /// never modified.
  final Project project;

  /// Called when the user activates the tile to open the project. The
  /// Dashboard forwards this to `AppNavigationState.openProject` (Req 5.1).
  /// When `null` the tile is not tappable.
  final VoidCallback? onOpen;

  /// Called when the user activates the edit control (rename + cover photo).
  /// The Dashboard opens the project dialog and forwards the result to
  /// `AppNavigationState.updateProject` (Req 3.1). When `null` the control is
  /// hidden.
  final VoidCallback? onRename;

  /// Called when the user activates the delete control. The Dashboard shows the
  /// confirmation prompt and forwards a confirmed deletion to
  /// `AppNavigationState.deleteProject` (Req 4.1). When `null` the delete
  /// control is hidden.
  final VoidCallback? onDelete;

  const ProjectCard({
    super.key,
    required this.project,
    this.onOpen,
    this.onRename,
    this.onDelete,
  });

  @override
  State<ProjectCard> createState() => _ProjectCardState();
}

class _ProjectCardState extends State<ProjectCard> {
  /// Whether the pointer is over the card (hover lift + accent border).
  bool _hovered = false;

  /// Whether the card itself holds keyboard focus (visible focus ring).
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final Project project = widget.project;
    final String shown = projectDisplayName(project.name);
    final bool active = _hovered || _focused;
    final TextTheme text = Theme.of(context).textTheme;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.curve,
        transform: _hovered
            ? Matrix4.translationValues(0, -3, 0)
            : Matrix4.identity(),
        decoration: BoxDecoration(
          gradient: AppStyle.cardSurface,
          borderRadius: AppStyle.cardRadius,
          border: Border.all(
            color: _focused
                ? AppPalette.focusRing
                : (_hovered ? AppPalette.primary : AppPalette.hairline),
            width: _focused ? AppStyle.focusRingWidth : 1,
          ),
          boxShadow: active ? AppStyle.hoverShadow : AppStyle.cardShadow,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Semantics(
            button: widget.onOpen != null,
            child: InkWell(
              onTap: widget.onOpen,
              onFocusChange: (bool focused) =>
                  setState(() => _focused = focused),
              borderRadius: AppStyle.cardRadius,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    // The portrait cover (or initial fallback), 1:1.6.
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: AppStyle.coverAspectRatio,
                          child: ProjectCover(
                            coverImage: project.coverImage,
                            projectName: project.name,
                            initialFontSize: 56,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: ProjectCard.footerHeight - AppSpacing.sm,
                      child: Row(
                        children: <Widget>[
                          const SizedBox(width: AppSpacing.xs),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                // The project Name (Req 1.1). Long names
                                // ellipsize so every tile keeps one height.
                                Text(
                                  shown,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.titleMedium,
                                ),
                                const SizedBox(height: AppSpacing.xxs),
                                Text(
                                  'Edited ${formatProjectDate(project.modifiedAt)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          // Edit / delete controls (Req 3.1, 4.1). Always
                          // present for keyboard and screen-reader users;
                          // they brighten when the card is hovered/focused.
                          AnimatedOpacity(
                            duration: AppMotion.fast,
                            opacity: active ? 1 : 0.7,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                if (widget.onRename != null)
                                  IconButton(
                                    tooltip: 'Edit project',
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 18,
                                      color: AppPalette.textSecondary,
                                    ),
                                    onPressed: widget.onRename,
                                  ),
                                if (widget.onDelete != null)
                                  IconButton(
                                    tooltip: 'Delete project',
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 18,
                                      color: AppPalette.error,
                                    ),
                                    onPressed: widget.onDelete,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
