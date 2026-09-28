/// Presentation layer: [ProjectCard], one tile of the Dashboard's project
/// list.
///
/// A card shows a single [Project]'s Name (Req 1.1), opens the project when the
/// tile is tapped (Req 5.1), and exposes trailing rename (Req 3.1) and delete
/// (Req 4.1) controls. It holds no persistence or navigation logic itself: the
/// gestures are surfaced as callbacks ([onOpen], [onRename], [onDelete]) that
/// the `DashboardView` wires to the corresponding `AppNavigationState` intents
/// (`openProject`, `renameProject`, `deleteProject`). This mirrors the
/// callback-based `DocumentListItem` convention from v1 and keeps the tile a
/// pure, testable widget.
///
/// Every color the card assigns is drawn from [AppPalette] so the tile never
/// falls back to a light-mode or system-default color (Req 18.2, 18.5).
library;

import 'package:flutter/material.dart';

import '../domain/project.dart';
import '../theme/app_theme.dart';

/// The placeholder shown when a [Project] has an empty / whitespace-only Name,
/// so an unnamed project still presents a readable label on the Dashboard.
const String kUntitledProjectPlaceholder = 'Untitled Project';

/// Transforms a Project's stored Name into the label the Dashboard displays,
/// without altering the stored Name.
///
/// Returns [kUntitledProjectPlaceholder] when [storedName] trims to empty
/// (empty or whitespace-only); otherwise returns [storedName] unchanged. The
/// tile relies on text overflow ellipsis rather than hard truncation, so the
/// full name is retained for display and layout.
String projectDisplayName(String storedName) {
  if (storedName.trim().isEmpty) {
    return kUntitledProjectPlaceholder;
  }
  return storedName;
}

/// A single project tile on the Dashboard.
///
/// Renders the Project's [projectDisplayName] and opens the project on tap
/// (Req 1.1, 5.1). The trailing slot holds the rename (Req 3.1) and delete
/// (Req 4.1) controls, each surfaced as a callback the Dashboard forwards to
/// the authoritative `AppNavigationState` flow. Colors come only from
/// [AppPalette] (Req 18.2, 18.5).
class ProjectCard extends StatefulWidget {
  /// The Project this tile represents. Its stored [Project.name] is read but
  /// never modified.
  final Project project;

  /// Called when the user taps the tile to open the project. The Dashboard
  /// forwards this to `AppNavigationState.openProject` (Req 5.1). When `null`
  /// the tile is not tappable.
  final VoidCallback? onOpen;

  /// Called when the user activates the rename control. The Dashboard opens the
  /// inline name field and forwards the result to
  /// `AppNavigationState.renameProject` (Req 3.1). When `null` the rename
  /// control is hidden.
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
  /// Whether the pointer is currently over the card, used to raise it with a
  /// soft accent-tinted shadow and reveal its controls (a modern hover lift).
  bool _hovered = false;

  /// The first letter of the display name, uppercased, for the gradient avatar
  /// chip. Falls back to a document glyph when the name has no letter.
  String get _initial {
    final String shown = projectDisplayName(widget.project.name).trim();
    if (shown.isEmpty) return '';
    return shown.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final String shown = projectDisplayName(widget.project.name);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        transform: _hovered
            ? Matrix4.translationValues(0, -2, 0)
            : Matrix4.identity(),
        decoration: BoxDecoration(
          gradient: AppStyle.cardSurface,
          borderRadius: AppStyle.cardRadius,
          border: Border.all(
            color: _hovered ? AppPalette.primary : AppPalette.hairline,
          ),
          boxShadow: _hovered ? AppStyle.hoverShadow : AppStyle.cardShadow,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onOpen,
            borderRadius: AppStyle.cardRadius,
            hoverColor: AppPalette.hoverOverlay,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
              child: Row(
                children: <Widget>[
                  _buildAvatar(),
                  const SizedBox(width: 12),
                  // The project Name (Req 1.1). Long names ellipsize rather
                  // than wrap so the tile keeps a stable single-line height.
                  Expanded(
                    child: Text(
                      shown,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // Trailing rename / delete controls (Req 3.1, 4.1). Each is
                  // shown only when its callback is provided.
                  if (widget.onRename != null)
                    IconButton(
                      tooltip: 'Rename project',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.edit_outlined,
                        size: 20,
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
                        size: 20,
                        color: AppPalette.error,
                      ),
                      onPressed: widget.onDelete,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The gradient avatar chip carrying the project's initial — a small modern
  /// touch that gives every card a distinct, colorful anchor.
  Widget _buildAvatar() {
    final String initial = _initial;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        gradient: AppStyle.accent,
        borderRadius: AppStyle.controlRadius,
      ),
      child: initial.isEmpty
          ? const Icon(Icons.menu_book_rounded,
              size: 20, color: AppPalette.onPrimary)
          : Text(
              initial,
              style: const TextStyle(
                color: AppPalette.onPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }
}
