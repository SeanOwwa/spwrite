/// Presentation layer: [FolderTile], one Folder row in the Project_Sidebar
/// tree together with its (revealed-when-expanded) contained Documents.
///
/// A tile renders, for a single [Folder] of the Active_Project:
///   * an expand / collapse chevron reflecting [ProjectWorkspaceState.isExpanded]
///     and toggling it (Req 6.4, 6.5);
///   * the Folder Name;
///   * trailing controls to create a Document inside the Folder (Req 10.2),
///     rename the Folder (Req 8.1), and delete the Folder (Req 9.1);
///   * when expanded, the Folder's ordered Documents (Req 6.4), or an
///     empty-folder indicator when the expanded Folder contains zero Documents
///     (Req 6.10).
///
/// Like v1's `SidebarView` rows, the tile is a thin observer over
/// [ProjectWorkspaceState]: it reads the folder's documents, the Active_Document,
/// and the folder's expansion state from the workspace, and dispatches every
/// user intent back to the state layer (`toggleFolder`, `createDocument`,
/// `selectDocument`) or to the callbacks the parent supplies for the flows the
/// parent orchestrates inline (folder rename / delete, and per-document
/// rename / delete). It owns no folder or document data of its own.
library;

import 'package:flutter/material.dart';

import '../domain/document.dart';
import '../domain/folder.dart';
import '../state/project_workspace_state.dart';
import '../theme/app_theme.dart';

/// A single Folder row in the Project_Sidebar and, when the Folder is expanded,
/// the ordered Documents it contains (or an empty-folder indicator).
///
/// A [StatelessWidget]: all mutable state (which Folder is expanded, the
/// Active_Document, the per-container document lists) lives in
/// [ProjectWorkspaceState], and the transient "which row is being renamed"
/// concern is owned by the parent Project_Sidebar, which supplies the inline
/// row builder via [documentRowBuilder]. This keeps the inline-rename behaviour
/// consistent across folders and root-level documents, mirroring how v1's
/// `SidebarView` centralized rename mode.
class FolderTile extends StatelessWidget {
  /// The Folder this tile represents. Its stored fields are read but never
  /// mutated by the tile.
  final Folder folder;

  /// Whether this Folder is currently in inline-rename mode. When true the
  /// parent supplies [renameField] to render in place of the Name / row
  /// contents (Req 8.1).
  final bool isRenaming;

  /// The inline editable Name field to render when [isRenaming] is true. The
  /// parent owns the rename lifecycle (confirm / cancel) and passes the built
  /// field here so the tile only decides *where* it appears (Req 8.1).
  final Widget? renameField;

  /// Enters inline-rename mode for this Folder (Req 8.1). Wired to the trailing
  /// rename control.
  final VoidCallback onRename;

  /// Opens the delete confirmation flow for this Folder (Req 9.1). Wired to the
  /// trailing delete control. The parent shows the contained-items confirmation
  /// prompt and dispatches `deleteFolder` on confirmation.
  final VoidCallback onDelete;

  /// Builds the row widget for a Document contained in this Folder at [index]
  /// (its position in the folder's ordered list), so the parent can render a
  /// reorderable, draggable row (or an inline rename field for the Document
  /// currently being renamed) — keeping document behaviour identical to
  /// root-level documents. The returned widget must carry a unique [Key] for
  /// the reorderable list.
  final Widget Function(BuildContext context, Document document, int index)
      documentRowBuilder;

  /// Reorders the documents inside this folder: moves the document at
  /// [oldIndex] to [newIndex] within the folder's ordered list.
  final void Function(int oldIndex, int newIndex) onReorderDocuments;

  /// Whether this folder's rename / delete controls are revealed. They are
  /// hidden by default and shown after a long-press on the folder row (Req v3).
  final bool controlsRevealed;

  /// Called when the folder row is long-pressed, to toggle [controlsRevealed].
  final VoidCallback onLongPress;

  /// The workspace state, passed in from the parent Project_Sidebar rather than
  /// read via `context.watch`. The sidebar already watches the state and
  /// rebuilds this tile when it changes; passing it explicitly is also required
  /// because a [ReorderableListView] builds its items under an internal overlay
  /// whose `BuildContext` is not a descendant of the workspace provider, so
  /// looking the provider up here would throw a `ProviderNotFoundException`.
  final ProjectWorkspaceState state;

  const FolderTile({
    super.key,
    required this.folder,
    required this.onRename,
    required this.onDelete,
    required this.documentRowBuilder,
    required this.onReorderDocuments,
    required this.state,
    required this.controlsRevealed,
    required this.onLongPress,
    this.isRenaming = false,
    this.renameField,
  });

  @override
  Widget build(BuildContext context) {
    final bool expanded = state.isExpanded(folder.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _buildFolderRow(context, state, expanded),
        // Revealed contents when expanded (Req 6.4); hidden when collapsed
        // (Req 6.5).
        if (expanded) _buildContents(context, state),
      ],
    );
  }

  /// The Folder header row: the expand / collapse chevron, the Name (or the
  /// inline rename field when [isRenaming]), and the trailing create-document /
  /// rename / delete controls.
  Widget _buildFolderRow(
    BuildContext context,
    ProjectWorkspaceState state,
    bool expanded,
  ) {
    // While renaming, replace the Name + tap target with the inline field so
    // the user edits the Name in place (Req 8.1). The chevron is retained so
    // the folder can still be expanded / collapsed during a rename.
    if (isRenaming) {
      return Material(
        color: AppPalette.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: <Widget>[
              _buildChevron(state, expanded),
              const Icon(
                Icons.folder_outlined,
                color: AppPalette.textSecondary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(child: renameField ?? const SizedBox.shrink()),
            ],
          ),
        ),
      );
    }

    return Material(
      color: AppPalette.surface,
      child: InkWell(
        // Tapping the row toggles expand / collapse (Req 6.4, 6.5).
        onTap: () => state.toggleFolder(folder.id),
        // Long-pressing reveals / hides the rename & delete controls (Req v3).
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: <Widget>[
              _buildChevron(state, expanded),
              const Icon(
                Icons.folder_outlined,
                color: AppPalette.textSecondary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppPalette.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _buildRowControls(context, state),
            ],
          ),
        ),
      ),
    );
  }

  /// The expand / collapse chevron. Tapping it toggles the folder just like
  /// tapping the row, so either affordance works (Req 6.4, 6.5).
  Widget _buildChevron(ProjectWorkspaceState state, bool expanded) {
    return IconButton(
      tooltip: expanded ? 'Collapse folder' : 'Expand folder',
      visualDensity: VisualDensity.compact,
      icon: Icon(
        expanded ? Icons.expand_more : Icons.chevron_right,
        color: AppPalette.textSecondary,
        size: 20,
      ),
      onPressed: () => state.toggleFolder(folder.id),
    );
  }

  /// The trailing folder controls: create-document-in-folder is always
  /// available (Req 10.2); rename (Req 8.1) and delete (Req 9.1) are hidden by
  /// default and shown only when [controlsRevealed] is true — i.e. after the
  /// folder row has been long-pressed (Req v3).
  Widget _buildRowControls(
    BuildContext context,
    ProjectWorkspaceState state,
  ) {
    // Read-only guides have no folder controls.
    if (state.isReadOnly) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          tooltip: 'Create document in folder',
          visualDensity: VisualDensity.compact,
          icon: const Icon(
            Icons.note_add_outlined,
            color: AppPalette.textSecondary,
            size: 18,
          ),
          // Req 10.2: create a document contained in this folder. The workspace
          // state also auto-expands a collapsed target folder (Req 10.6).
          onPressed: () => state.createDocument(folderId: folder.id),
        ),
        if (controlsRevealed) ...<Widget>[
          IconButton(
            tooltip: 'Rename folder',
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.edit_outlined,
              color: AppPalette.textSecondary,
              size: 18,
            ),
            onPressed: onRename,
          ),
          IconButton(
            tooltip: 'Delete folder',
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.delete_outline,
              color: AppPalette.textSecondary,
              size: 18,
            ),
            onPressed: onDelete,
          ),
        ],
      ],
    );
  }

  /// The expanded Folder's contents: the ordered Documents it contains, or an
  /// empty-folder indicator when it contains zero Documents (Req 6.4, 6.10).
  ///
  /// Contained document rows are indented so the tree hierarchy reads clearly,
  /// and each row is built by [documentRowBuilder] so the parent controls
  /// selection, rename, and delete uniformly with root-level documents.
  Widget _buildContents(BuildContext context, ProjectWorkspaceState state) {
    final List<Document> documents = state.documentsIn(folder.id);

    // Req 6.10: an expanded folder with no documents shows an empty indicator.
    if (documents.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(left: 48, right: 16, top: 4, bottom: 8),
        child: Text(
          'This folder is empty.',
          style: TextStyle(
            color: AppPalette.textSecondary,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    // Req 6.4: reveal the folder's ordered documents, indented beneath the
    // folder row. A ReorderableListView lets the user drag documents into a new
    // order within the folder; the parent supplies each draggable row.
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        onReorderItem: onReorderDocuments,
        children: <Widget>[
          for (int i = 0; i < documents.length; i++)
            documentRowBuilder(context, documents[i], i),
        ],
      ),
    );
  }
}
