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
class ProjectCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final String shown = projectDisplayName(project.name);

    // A raised surface tile above the darkest background. The Card / InkWell
    // paint on the palette surface so ink splashes and the selected state have
    // a surface to render on without falling back to a default color
    // (Req 18.2, 18.5).
    return Card(
      color: AppPalette.surface,
      surfaceTintColor: AppPalette.surface,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
          child: Row(
            children: <Widget>[
              // The project Name (Req 1.1). Long names ellipsize rather than
              // wrap so the tile keeps a stable single-line height.
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
              // Trailing rename / delete controls (Req 3.1, 4.1). Each is shown
              // only when its callback is provided.
              if (onRename != null)
                IconButton(
                  tooltip: 'Rename project',
                  icon: const Icon(Icons.edit, color: AppPalette.textSecondary),
                  onPressed: onRename,
                ),
              if (onDelete != null)
                IconButton(
                  tooltip: 'Delete project',
                  icon: const Icon(Icons.delete, color: AppPalette.error),
                  onPressed: onDelete,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
