/// Presentation layer: [ProjectSidebarView], the Project_Sidebar surface shown
/// while a Project is open. It is the v2 evolution of v1's `SidebarView`,
/// extended from a single flat `Document_List` into the three-level tree
/// (Project → Folder → Document).
///
/// The view renders, for the Active_Project:
///   * a header carrying the Project Name, a back-to-dashboard control
///     (Req 5.4), a create-folder control (Req 7.1), and a create-root-document
///     control (Req 10.1);
///   * a contents load-error banner when the Active_Project's contents failed
///     to load, retaining any previously displayed contents beneath it
///     (Req 6.11);
///   * the ordered, expandable [FolderTile]s, each revealing its ordered
///     documents when expanded (Req 6.1, 6.2, 6.4);
///   * the ordered Root-Level Documents via the reused [DocumentListItem]
///     (Req 6.1, 6.3, 6.6, 6.7, 6.8);
///   * per-item rename / delete controls for folders (Req 8.1, 9.1) and
///     documents (Req 12.1, 13.1);
///   * the active-document highlight (Req 6.8, 11.1); and
///   * an empty-project message when the Active_Project has zero folders and
///     zero documents (Req 6.9).
///
/// Like v1's `SidebarView`, this view is a thin observer over
/// [ProjectWorkspaceState]: it watches the state's `folders`, per-container
/// documents, `activeDocument`, `contentsStatus`, and `transientError`, and
/// dispatches every user intent back to the state layer (`createFolder`,
/// `createDocument`, `selectDocument`, `renameFolder`, `renameDocument`,
/// `deleteFolder`, `deleteDocument`, `clearTransientError`). Back-to-dashboard
/// is dispatched to [AppNavigationState.closeProject] (Req 5.4). Ordering is
/// already applied by the state layer (Req 6.2, 6.3), so lists are rendered in
/// the order the workspace returns.
///
/// The only local state it keeps is which single row — a folder or a
/// document — is currently in inline-rename mode, mirroring how v1 centralized
/// rename mode so folder and document rename behave identically.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/document.dart';
import '../domain/folder.dart';
import '../state/app_navigation_state.dart';
import '../state/load_status.dart';
import '../state/project_workspace_state.dart';
import '../theme/app_theme.dart';
import 'delete_confirmation_dialog.dart';
import 'document_list_item.dart';
import 'error_surfaces.dart';
import 'folder_tile.dart';
import 'name_field.dart';

/// The Project_Sidebar: a header (project name + back / create-folder /
/// create-root-document controls), an optional contents-load-error banner, and
/// the ordered folder + root-document tree (or an empty-project message).
///
/// A [StatefulWidget] because it tracks the id of the single row currently in
/// inline-rename mode ([_renamingId]); all folder and document data itself
/// lives in [ProjectWorkspaceState].
class ProjectSidebarView extends StatefulWidget {
  const ProjectSidebarView({super.key});

  @override
  State<ProjectSidebarView> createState() => _ProjectSidebarViewState();
}

class _ProjectSidebarViewState extends State<ProjectSidebarView> {
  /// The id of the folder or document currently switched into inline-rename
  /// mode, or `null` when no row is being renamed (Req 8.1, 12.1). Only one row
  /// can be in rename mode at a time. Folder ids and document ids are UUIDs and
  /// never collide, so a single field disambiguates both.
  String? _renamingId;

  /// The id of the single folder or document whose rename / delete controls are
  /// currently revealed, or `null` when none are. Controls are hidden by
  /// default and shown after a long-press on the tile (Req v3); long-pressing
  /// the same tile again hides them.
  String? _revealedId;

  /// Toggles whether the rename / delete controls are revealed for the tile
  /// identified by [id]. Revealing a tile hides any previously revealed one
  /// (only one tile shows its controls at a time).
  void _toggleRevealed(String id) {
    setState(() => _revealedId = _revealedId == id ? null : id);
  }

  /// Enters inline-rename mode for the folder or document identified by [id]
  /// (Req 8.1, 12.1).
  void _beginRename(String id) {
    setState(() {
      _renamingId = id;
      // Renaming supersedes the revealed controls.
      _revealedId = null;
    });
  }

  /// Exits inline-rename mode, retaining whatever name/title the state layer
  /// holds (used on both confirm and cancel, Req 8.6, 12.6).
  void _endRename() {
    if (_renamingId == null) return;
    setState(() => _renamingId = null);
  }

  /// Confirms a folder rename: forwards the new name to the authoritative
  /// rename flow then leaves edit mode (Req 8.1, 8.6). The state layer
  /// re-validates and persists [newName].
  void _confirmFolderRename(
    ProjectWorkspaceState state,
    String id,
    String newName,
  ) {
    state.renameFolder(id, newName);
    _endRename();
  }

  /// Confirms a document rename: forwards the new title to the authoritative
  /// rename flow then leaves edit mode (Req 12.1, 12.6). The state layer
  /// re-validates and persists [newTitle].
  void _confirmDocumentRename(
    ProjectWorkspaceState state,
    String id,
    String newTitle,
  ) {
    state.renameDocument(id, newTitle);
    _endRename();
  }

  /// Shows the folder delete confirmation prompt (warning that the contained
  /// documents will also be removed, Req 9.1); on confirmation dispatches the
  /// cascade delete to the state layer (Req 9.2). Cancelling leaves the folder
  /// and its documents untouched.
  Future<void> _confirmDeleteFolder(
    BuildContext context,
    ProjectWorkspaceState state,
    Folder folder,
  ) async {
    final bool confirmed = await DeleteConfirmationDialog.showForFolder(
      context,
      folderName: folder.name,
    );
    if (confirmed) {
      state.deleteFolder(folder.id);
    }
  }

  /// Shows the document delete confirmation prompt (Req 13.1); on confirmation
  /// dispatches the delete to the state layer (Req 13.2). Cancelling leaves the
  /// document untouched (Req 13.4).
  Future<void> _confirmDeleteDocument(
    BuildContext context,
    ProjectWorkspaceState state,
    Document doc,
  ) async {
    final bool confirmed = await DeleteConfirmationDialog.showForDocument(
      context,
      documentTitle: doc.title,
    );
    if (confirmed) {
      state.deleteDocument(doc.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Observe the workspace so the sidebar rebuilds on any folder / document /
    // active / status change (Req 6.1, 6.2, 6.3, 6.8, 6.11).
    final ProjectWorkspaceState state =
        context.watch<ProjectWorkspaceState>();
    final List<Folder> folders = state.folders;
    final List<Document> rootDocuments = state.rootDocuments();
    final bool hasContentsError =
        state.contentsStatus == LoadStatus.error;
    // Req 6.9: the empty-project message is shown only when the Active_Project
    // has zero folders AND zero documents. With zero folders there can be no
    // folder-contained documents, so the check reduces to no folders and no
    // root-level documents.
    final bool isEmptyProject = folders.isEmpty && rootDocuments.isEmpty;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[AppPalette.surface, Color(0xFF0D1526)],
        ),
        border: Border(
          right: BorderSide(color: AppPalette.hairline),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildHeader(context, state),
          // Contents load-error banner sits above the tree and retains any
          // previously displayed contents beneath it (Req 6.11).
          if (hasContentsError)
            ErrorBanner(
              message: state.transientError ??
                  'The project contents could not be loaded.',
              onDismiss: state.clearTransientError,
            ),
          Expanded(
            child: isEmptyProject
                ? _buildEmptyState()
                : _buildTree(context, state, folders, rootDocuments),
          ),
        ],
      ),
    );
  }

  /// The Project_Sidebar header: the back-to-dashboard control (Req 5.4), the
  /// Project Name, and the create-folder (Req 7.1) and create-root-document
  /// (Req 10.1) controls.
  Widget _buildHeader(BuildContext context, ProjectWorkspaceState state) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppPalette.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              // Req 5.4: return to the Dashboard. Dispatched to the navigation
              // state, which disposes this workspace and clears the editor.
              IconButton(
                tooltip: 'Back to dashboard',
                style: IconButton.styleFrom(
                  backgroundColor: AppPalette.surfaceVariant,
                  shape: const RoundedRectangleBorder(
                    borderRadius: AppStyle.controlRadius,
                  ),
                ),
                icon: const Icon(
                  Icons.arrow_back,
                  size: 20,
                  color: AppPalette.textSecondary,
                ),
                onPressed: () =>
                    context.read<AppNavigationState>().closeProject(),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.project.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              // Req 7.1: create a folder in the Active_Project.
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _promptCreateFolder(context, state),
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('Folder'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Req 10.1: create a Root-Level Document under the project root.
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => state.createDocument(),
                  icon: const Icon(Icons.note_add_outlined, size: 18),
                  label: const Text('Doc'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Presents an inline [NameField] in a dialog-free popup row for the new
  /// folder name and dispatches [ProjectWorkspaceState.createFolder] on confirm
  /// (Req 7.1, 7.2). The authoritative flow re-validates and persists it.
  Future<void> _promptCreateFolder(
    BuildContext context,
    ProjectWorkspaceState state,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('New folder'),
          content: NameField(
            initialValue: '',
            onConfirm: (String name) {
              state.createFolder(name);
              Navigator.of(dialogContext).pop();
            },
            onCancel: () => Navigator.of(dialogContext).pop(),
          ),
        );
      },
    );
  }

  /// The centered empty-project message shown when the Active_Project has zero
  /// folders and zero documents (Req 6.9).
  Widget _buildEmptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          'This project has no folders or documents yet. '
          'Create a folder or a document to get started.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppPalette.textSecondary),
        ),
      ),
    );
  }

  /// The ordered tree body: a single interleaved, reorderable list of the
  /// project's root items — folders and root-level documents share one order,
  /// so a document can sit above, below, or between folders (Req v3, 6.1–6.4).
  ///
  /// Interactions:
  ///   * the ⠿ drag handle reorders an item within the root list (a document
  ///     can thus swap order with a folder);
  ///   * dragging a document's body onto a folder moves it *into* that folder;
  ///   * dragging a folder document's body onto the root list moves it *out*;
  ///   * long-pressing a tile reveals its rename / delete controls.
  Widget _buildTree(
    BuildContext context,
    ProjectWorkspaceState state,
    List<Folder> folders,
    List<Document> rootDocuments,
  ) {
    final List<RootItem> items = state.rootItems();
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      itemCount: items.length,
      onReorderItem: (int oldIndex, int newIndex) =>
          state.reorderRootItems(oldIndex, newIndex),
      itemBuilder: (BuildContext context, int index) {
        final RootItem item = items[index];
        if (item.isFolder) {
          return _buildFolderEntry(context, state, item.folder!, index);
        }
        return _buildRootDocumentEntry(context, state, item.document!, index);
      },
    );
  }

  /// A folder row in the root list: a drag handle (reorder among root items), a
  /// [DragTarget] that accepts a document dropped onto it (move into this
  /// folder), and the [FolderTile] itself (which renders the folder's contents
  /// and its own reorderable documents when expanded).
  Widget _buildFolderEntry(
    BuildContext context,
    ProjectWorkspaceState state,
    Folder folder,
    int index,
  ) {
    return DragTarget<Document>(
      key: ValueKey<String>('root-folder-${folder.id}'),
      onWillAcceptWithDetails: (DragTargetDetails<Document> details) =>
          details.data.folderId != folder.id,
      onAcceptWithDetails: (DragTargetDetails<Document> details) {
        // Append the moved document to the end of the target folder.
        final int end = state.documentsIn(folder.id).length;
        state.moveDocument(details.data.id, folder.id, end);
      },
      builder: (
        BuildContext context,
        List<Document?> candidate,
        List<dynamic> rejected,
      ) {
        final bool highlighted = candidate.isNotEmpty;
        return Container(
          decoration: highlighted
              ? BoxDecoration(
                  border: Border.all(color: AppPalette.primary, width: 2),
                  borderRadius: BorderRadius.circular(6),
                )
              : null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _buildDragHandle(index, topAligned: true),
              Expanded(
                child: FolderTile(
                  folder: folder,
                  state: state,
                  controlsRevealed: _revealedId == folder.id,
                  onLongPress: () => _toggleRevealed(folder.id),
                  isRenaming: _renamingId == folder.id,
                  renameField: _renamingId == folder.id
                      ? NameField(
                          initialValue: folder.name,
                          onConfirm: (String newName) =>
                              _confirmFolderRename(state, folder.id, newName),
                          onCancel: _endRename,
                        )
                      : null,
                  onRename: () => _beginRename(folder.id),
                  onDelete: () =>
                      _confirmDeleteFolder(context, state, folder),
                  onReorderDocuments: (int oldIndex, int newIndex) =>
                      state.reorderDocumentsInFolder(
                          folder.id, oldIndex, newIndex),
                  documentRowBuilder:
                      (BuildContext context, Document doc, int docIndex) =>
                          _buildFolderDocumentRow(
                              context, state, doc, docIndex),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// A root-level document row: a drag handle (reorder among root items) beside
  /// the draggable, selectable document row. The document body is draggable so
  /// it can be dropped onto a folder to move it in.
  Widget _buildRootDocumentEntry(
    BuildContext context,
    ProjectWorkspaceState state,
    Document doc,
    int index,
  ) {
    return Row(
      key: ValueKey<String>('root-doc-${doc.id}'),
      children: <Widget>[
        _buildDragHandle(index),
        Expanded(child: _buildDraggableDocumentRow(context, state, doc)),
      ],
    );
  }

  /// A document row inside a folder: a drag handle (reorder within the folder)
  /// beside the draggable, selectable document row. Needs a stable [Key] for
  /// the folder's [ReorderableListView].
  Widget _buildFolderDocumentRow(
    BuildContext context,
    ProjectWorkspaceState state,
    Document doc,
    int index,
  ) {
    return Row(
      key: ValueKey<String>('folder-doc-${doc.id}'),
      children: <Widget>[
        _buildDragHandle(index),
        Expanded(child: _buildDraggableDocumentRow(context, state, doc)),
      ],
    );
  }

  /// A drag handle that starts a reorder of the item at [index] within its
  /// enclosing reorderable list.
  Widget _buildDragHandle(int index, {bool topAligned = false}) {
    return ReorderableDragStartListener(
      index: index,
      child: Padding(
        padding: EdgeInsets.only(top: topAligned ? 8 : 6, left: 4, right: 2),
        child: const Icon(
          Icons.drag_indicator,
          size: 18,
          color: AppPalette.textSecondary,
        ),
      ),
    );
  }

  /// Wraps a document row in a [Draggable] so its body can be dragged onto a
  /// folder (to move it in) or the root list (to move it out). Dragging the
  /// body is distinct from the ⠿ handle (which reorders) and from a tap (which
  /// selects). The floating feedback is a compact chip of the title.
  Widget _buildDraggableDocumentRow(
    BuildContext context,
    ProjectWorkspaceState state,
    Document doc,
  ) {
    // While renaming, do not make the row draggable — the inline field needs
    // normal pointer handling.
    if (_renamingId == doc.id) {
      return _buildDocumentRow(context, state, doc);
    }

    final String shownTitle =
        doc.title.trim().isEmpty ? 'Untitled Document' : doc.title;

    return Draggable<Document>(
      data: doc,
      dragAnchorStrategy: childDragAnchorStrategy,
      // A small delay-free drag on the body; taps still pass through to select.
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppPalette.surfaceVariant,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppPalette.primary),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.description_outlined,
                  size: 16, color: AppPalette.textSecondary),
              const SizedBox(width: 6),
              Text(
                shownTitle,
                style: const TextStyle(color: AppPalette.textPrimary),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.4,
        child: _buildDocumentRow(context, state, doc),
      ),
      child: _buildDocumentRow(context, state, doc),
    );
  }

  /// Builds one document row, shared between folder-contained documents and
  /// root-level documents so their select / rename / delete behaviour is
  /// identical (Req 6.6, 6.7, 6.8, 11.1, 12.1, 13.1).
  ///
  /// When the row is in inline-rename mode it renders an editable [NameField]
  /// in place of the row (Req 12.1). Otherwise it renders the reused
  /// [DocumentListItem] with the active-document highlight (Req 6.8), tap to
  /// select (Req 11.1), a long-press to reveal the rename / delete controls,
  /// and those controls only when this row is the revealed one.
  Widget _buildDocumentRow(
    BuildContext context,
    ProjectWorkspaceState state,
    Document doc,
  ) {
    // Inline-rename mode: render the editable title field in place of the row
    // (Req 12.1). Confirm forwards to renameDocument then exits; cancel simply
    // exits, retaining the title (Req 12.6).
    if (_renamingId == doc.id) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: NameField(
          initialValue: doc.title,
          label: NameFieldLabel.title,
          onConfirm: (String newTitle) =>
              _confirmDocumentRename(state, doc.id, newTitle),
          onCancel: _endRename,
        ),
      );
    }

    // Normal row: display title (Req 6.6, 6.7), active highlight (Req 6.8),
    // tap to select (Req 11.1), long-press to reveal controls, and the
    // rename / delete controls only when revealed (Req 12.1, 13.1).
    final bool revealed = _revealedId == doc.id;
    return DocumentListItem(
      document: doc,
      isActive: doc.id == state.activeDocument?.id,
      onTap: () => state.selectDocument(doc.id),
      onLongPress: () => _toggleRevealed(doc.id),
      trailing: revealed ? _buildDocumentControls(context, state, doc) : null,
    );
  }

  /// The per-document trailing controls: a rename (edit) button that enters
  /// inline rename mode (Req 12.1) and a delete button that opens the
  /// confirmation dialog (Req 13.1). Shown only after the row is long-pressed.
  Widget _buildDocumentControls(
    BuildContext context,
    ProjectWorkspaceState state,
    Document doc,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          tooltip: 'Rename document',
          visualDensity: VisualDensity.compact,
          icon: const Icon(
            Icons.edit_outlined,
            color: AppPalette.textSecondary,
            size: 18,
          ),
          onPressed: () => _beginRename(doc.id),
        ),
        IconButton(
          tooltip: 'Delete document',
          visualDensity: VisualDensity.compact,
          icon: const Icon(
            Icons.delete_outline,
            color: AppPalette.textSecondary,
            size: 18,
          ),
          onPressed: () => _confirmDeleteDocument(context, state, doc),
        ),
      ],
    );
  }
}
