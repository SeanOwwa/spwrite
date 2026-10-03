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
import 'project_cover.dart';

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
    // Rename/delete controls never appear in a read-only guide.
    if (context.read<ProjectWorkspaceState>().isReadOnly) return;
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
        gradient: AppStyle.panelSurface,
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
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
      ),
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
              const SizedBox(width: AppSpacing.md),
              // The project's cover thumbnail (or initial badge), 1:1.6.
              SizedBox(
                width: 34,
                height: 34 / AppStyle.coverAspectRatio,
                child: ProjectCover(
                  coverImage: state.project.coverImage,
                  projectName: state.project.name,
                  borderRadius: const BorderRadius.all(Radius.circular(6)),
                  initialFontSize: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      'PROJECT',
                      style: text.labelSmall,
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Semantics(
                      header: true,
                      child: Text(
                        state.project.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleLarge,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Built-in guides are read-only: no create buttons, just a note.
          if (state.isReadOnly)
            _buildReadOnlyNote(context)
          else
          Row(
            children: <Widget>[
              // Req 7.1: create a folder in the Active_Project.
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey<String>('sidebar-new-folder'),
                  onPressed: () => _promptCreateFolder(context, state),
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('Folder'),
                  style: OutlinedButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.md),
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
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The note shown instead of the create buttons in a read-only guide.
  Widget _buildReadOnlyNote(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppPalette.surfaceVariant,
        borderRadius: AppStyle.controlRadius,
        border: Border.all(color: AppPalette.hairline),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.menu_book_outlined,
            size: 18,
            color: AppPalette.secondary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Built-in guide · read-only',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                  ),
            ),
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
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.auto_stories_outlined,
              size: 40,
              color: AppPalette.textSecondary,
            ),
            SizedBox(height: AppSpacing.md),
            Text(
              'This project has no folders or documents yet. '
              'Create a folder or a document to get started.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  /// The ordered tree body: a single interleaved list of the project's root
  /// items — folders and root-level documents share one order, so a document
  /// can sit above, below, or between folders (Req v3, 6.1–6.4) — followed by
  /// an open area at the bottom that is also a drop target.
  ///
  /// Drag & drop: press anywhere on a folder or document row and drag it.
  ///   * dropping on the top / bottom half of a row places the item before /
  ///     after it, in that row's container (reorder, or move between the top
  ///     level and a folder);
  ///   * dropping a document on a folder row moves it *into* that folder;
  ///   * dropping in the open area below the list moves the item to the end of
  ///     the top level (the way out of a folder when nothing else is visible).
  ///
  /// Taps still select or expand, and long-press still reveals the rename /
  /// delete controls: a drag only starts once the pointer moves.
  Widget _buildTree(
    BuildContext context,
    ProjectWorkspaceState state,
    List<Folder> folders,
    List<Document> rootDocuments,
  ) {
    final List<RootItem> items = state.rootItems();
    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.only(top: AppSpacing.sm),
          sliver: SliverList.builder(
            itemCount: items.length,
            itemBuilder: (BuildContext context, int index) {
              final RootItem item = items[index];
              if (item.isFolder) {
                return _buildFolderEntry(context, state, item.folder!, index);
              }
              return _buildRootDocumentEntry(
                  context, state, item.document!, index);
            },
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: _buildEndDropArea(state, items.length),
        ),
      ],
    );
  }

  /// A folder entry in the root list: the [FolderTile] (header plus, when
  /// expanded, its documents). The header row is draggable (moves the folder
  /// among the root items) and accepts documents (drops them into the folder).
  /// The whole entry also accepts a dragged folder, placing it before or after
  /// this one.
  Widget _buildFolderEntry(
    BuildContext context,
    ProjectWorkspaceState state,
    Folder folder,
    int index,
  ) {
    final SidebarDragItem self = SidebarDragItem.folder(folder);
    return _SidebarDropZone(
      key: ValueKey<String>('root-folder-${folder.id}'),
      // Documents reach this outer zone only over the folder's open space
      // (e.g. the "empty folder" note); there they drop into the folder.
      placementFor: (SidebarDragItem item, double fraction) => item.isFolder
          ? _halfPlacement(fraction)
          : SidebarDropPlacement.inside,
      onDrop: (SidebarDragItem item, SidebarDropPlacement placement) =>
          _dropOnFolder(state, item, folder, index, placement),
      child: _fadeWhileDragging(
        self,
        FolderTile(
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
          onDelete: () => _confirmDeleteFolder(context, state, folder),
          documentRowBuilder:
              (BuildContext context, Document doc, int docIndex) =>
                  _buildFolderDocumentRow(context, state, folder, doc, docIndex),
          headerBuilder: (BuildContext context, Widget header) =>
              _SidebarDropZone(
            // The header takes documents: the top edge places the document
            // above the folder at the top level, the rest drops it inside.
            accepts: (SidebarDragItem item) => !item.isFolder,
            placementFor: (SidebarDragItem item, double fraction) =>
                fraction < 0.3
                    ? SidebarDropPlacement.before
                    : SidebarDropPlacement.inside,
            onDrop: (SidebarDragItem item, SidebarDropPlacement placement) =>
                _dropOnFolder(state, item, folder, index, placement),
            child: _isDraggable(state, folder.id)
                ? _draggable(
                    context,
                    item: self,
                    icon: Icons.folder_outlined,
                    label: folder.name,
                    child: header,
                  )
                : header,
          ),
        ),
      ),
    );
  }

  /// The open area below the root list. Dropping here moves the item to the
  /// end of the top level, which is how a document leaves a folder when no
  /// top-level row is in view.
  Widget _buildEndDropArea(ProjectWorkspaceState state, int rootCount) {
    return _SidebarDropZone(
      key: const ValueKey<String>('sidebar-end-drop-area'),
      placementFor: (SidebarDragItem item, double fraction) =>
          SidebarDropPlacement.before,
      onDrop: (SidebarDragItem item, SidebarDropPlacement placement) =>
          _dropAtRoot(state, item, rootCount),
      hoverHint: 'Move to the top level',
      child: const SizedBox(height: 56),
    );
  }

  // ---------------------------------------------------------------------------
  // Drag & drop
  // ---------------------------------------------------------------------------

  /// The id of the folder or document being dragged, so its row can be dimmed
  /// in place while its chip follows the pointer. `null` when nothing is.
  String? _draggingId;

  /// Scrolls the tree while a drag is held near its top or bottom edge.
  EdgeDraggingAutoScroller? _autoScroller;

  @override
  void dispose() {
    _autoScroller?.stopAutoScroll();
    super.dispose();
  }

  /// Whether the row for [id] can be dragged: not in a read-only guide and not
  /// while it is being renamed (the inline field needs normal pointer input).
  bool _isDraggable(ProjectWorkspaceState state, String id) =>
      !state.isReadOnly && _renamingId != id;

  /// Before for the top half of a row, after for the bottom half.
  static SidebarDropPlacement _halfPlacement(double fraction) => fraction < 0.5
      ? SidebarDropPlacement.before
      : SidebarDropPlacement.after;

  /// Dims [child] while [item] is the one being dragged. The [Opacity] is
  /// always present so the subtree (and the active [Draggable]) keeps its
  /// element when the drag starts and ends.
  Widget _fadeWhileDragging(SidebarDragItem item, Widget child) {
    return Opacity(
      opacity: _draggingId == item.id ? 0.4 : 1,
      child: child,
    );
  }

  /// Makes the whole [child] row draggable as [item]. Dragging starts once the
  /// pointer moves, so taps and long-presses on the row keep working. The
  /// floating feedback is a compact chip with [icon] and [label].
  Widget _draggable(
    BuildContext context, {
    required SidebarDragItem item,
    required IconData icon,
    required String label,
    required Widget child,
  }) {
    return Draggable<SidebarDragItem>(
      data: item,
      // The drop position is read from the pointer, so anchor the drag there.
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _SidebarDragChip(icon: icon, label: label),
      onDragStarted: () => setState(() => _draggingId = item.id),
      onDragUpdate: (DragUpdateDetails details) =>
          _autoScrollIfNeeded(context, details.globalPosition),
      onDragEnd: (_) => _endDrag(),
      child: child,
    );
  }

  /// Starts (or keeps) scrolling the tree when the pointer nears its edge.
  void _autoScrollIfNeeded(BuildContext rowContext, Offset globalPosition) {
    if (!rowContext.mounted) return;
    final ScrollableState? scrollable = Scrollable.maybeOf(rowContext);
    if (scrollable == null) return;
    if (_autoScroller?.scrollable != scrollable) {
      _autoScroller?.stopAutoScroll();
      _autoScroller = EdgeDraggingAutoScroller(
        scrollable,
        velocityScalar: 50,
      );
    }
    _autoScroller!.startAutoScrollIfNecessary(
      Rect.fromCenter(center: globalPosition, width: 1, height: 40),
    );
  }

  void _endDrag() {
    _autoScroller?.stopAutoScroll();
    if (mounted && _draggingId != null) setState(() => _draggingId = null);
  }

  /// Converts a drop slot in a list that may contain the dragged item at
  /// [current] (-1 when it is not in that list) into the index the item takes
  /// once it has been removed from that list.
  static int _targetIndex(int slot, int current) =>
      current != -1 && current < slot ? slot - 1 : slot;

  /// Places [item] at [slot] in the top-level order (folders and root
  /// documents). A document from a folder is moved out of it.
  void _dropAtRoot(ProjectWorkspaceState state, SidebarDragItem item, int slot) {
    _endDrag();
    final List<RootItem> items = state.rootItems();
    final int current = items.indexWhere((RootItem it) => it.id == item.id);
    final int target = _targetIndex(slot, current);
    if (current == target) return; // Dropped where it already is.
    if (item.isFolder) {
      if (current != -1) state.reorderRootItems(current, target);
    } else {
      state.moveDocument(item.id, null, target);
    }
  }

  /// Places the dragged document at [slot] in [folderId]'s document order,
  /// moving it into that folder first if needed.
  void _dropInFolder(
    ProjectWorkspaceState state,
    SidebarDragItem item,
    String folderId,
    int slot,
  ) {
    _endDrag();
    if (item.isFolder) return; // Folders do not nest.
    final List<Document> documents = state.documentsIn(folderId);
    final int current =
        documents.indexWhere((Document d) => d.id == item.id);
    final int target = _targetIndex(slot, current);
    if (current == target) return;
    state.moveDocument(item.id, folderId, target);
  }

  /// Handles a drop on the folder entry at root [index]: before / after places
  /// the item beside the folder at the top level; inside appends a document to
  /// the end of the folder (a no-op when it is already there).
  void _dropOnFolder(
    ProjectWorkspaceState state,
    SidebarDragItem item,
    Folder folder,
    int index,
    SidebarDropPlacement placement,
  ) {
    switch (placement) {
      case SidebarDropPlacement.before:
        _dropAtRoot(state, item, index);
      case SidebarDropPlacement.after:
        _dropAtRoot(state, item, index + 1);
      case SidebarDropPlacement.inside:
        if (state.documentsIn(folder.id).any((Document d) => d.id == item.id)) {
          _endDrag();
          return;
        }
        _dropInFolder(
            state, item, folder.id, state.documentsIn(folder.id).length);
    }
  }

  /// A root-level document row. The whole row is draggable, and it accepts any
  /// dragged item: the top half places it before this document, the bottom
  /// half after it, at the top level.
  Widget _buildRootDocumentEntry(
    BuildContext context,
    ProjectWorkspaceState state,
    Document doc,
    int index,
  ) {
    return _SidebarDropZone(
      key: ValueKey<String>('root-doc-${doc.id}'),
      placementFor: (SidebarDragItem item, double fraction) =>
          _halfPlacement(fraction),
      onDrop: (SidebarDragItem item, SidebarDropPlacement placement) =>
          _dropAtRoot(
        state,
        item,
        placement == SidebarDropPlacement.after ? index + 1 : index,
      ),
      child: _buildDraggableDocumentRow(context, state, doc),
    );
  }

  /// A document row inside [folder]. The whole row is draggable, and it
  /// accepts dragged documents: the top half places them before this one, the
  /// bottom half after it, inside [folder].
  Widget _buildFolderDocumentRow(
    BuildContext context,
    ProjectWorkspaceState state,
    Folder folder,
    Document doc,
    int index,
  ) {
    return _SidebarDropZone(
      key: ValueKey<String>('folder-doc-${doc.id}'),
      accepts: (SidebarDragItem item) => !item.isFolder,
      placementFor: (SidebarDragItem item, double fraction) =>
          _halfPlacement(fraction),
      onDrop: (SidebarDragItem item, SidebarDropPlacement placement) =>
          _dropInFolder(
        state,
        item,
        folder.id,
        placement == SidebarDropPlacement.after ? index + 1 : index,
      ),
      child: _buildDraggableDocumentRow(context, state, doc),
    );
  }

  /// A document row that can be dragged from anywhere on it (unless it is
  /// being renamed or belongs to a read-only guide), dimmed while dragged.
  Widget _buildDraggableDocumentRow(
    BuildContext context,
    ProjectWorkspaceState state,
    Document doc,
  ) {
    final Widget row = _buildDocumentRow(context, state, doc);
    if (!_isDraggable(state, doc.id)) return row;
    final SidebarDragItem item = SidebarDragItem.document(doc);
    return _fadeWhileDragging(
      item,
      _draggable(
        context,
        item: item,
        icon: Icons.description_outlined,
        label: doc.title.trim().isEmpty ? 'Untitled Document' : doc.title,
        child: row,
      ),
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

/// What is being dragged in the Project_Sidebar: one document or one folder.
@immutable
class SidebarDragItem {
  const SidebarDragItem.document(Document this.document) : folder = null;
  const SidebarDragItem.folder(Folder this.folder) : document = null;

  /// The dragged document, or `null` when a folder is dragged.
  final Document? document;

  /// The dragged folder, or `null` when a document is dragged.
  final Folder? folder;

  bool get isFolder => folder != null;

  /// The dragged item's id (folder and document ids are UUIDs, never equal).
  String get id => folder?.id ?? document!.id;
}

/// Where a dragged item lands relative to the row it is dropped on.
enum SidebarDropPlacement {
  /// Above the row, in the row's container.
  before,

  /// Below the row, in the row's container.
  after,

  /// Into the row (a document dropped on a folder).
  inside,
}

/// A drop target around one sidebar row (or area). It decides the placement
/// from the pointer's vertical position within the row, shows where the item
/// will land (a line above or below, or an outline for "inside"), and reports
/// the drop.
class _SidebarDropZone extends StatefulWidget {
  const _SidebarDropZone({
    super.key,
    required this.placementFor,
    required this.onDrop,
    required this.child,
    this.accepts,
    this.hoverHint,
  });

  /// Whether this zone takes [item]; all items when null. A rejected item
  /// falls through to the enclosing zone, if any.
  final bool Function(SidebarDragItem item)? accepts;

  /// The placement for [item] at [fraction] of this zone's height (0 = top).
  final SidebarDropPlacement Function(SidebarDragItem item, double fraction)
      placementFor;

  final void Function(SidebarDragItem item, SidebarDropPlacement placement)
      onDrop;

  /// Optional text shown centred in the zone while an item hovers over it.
  final String? hoverHint;

  final Widget child;

  @override
  State<_SidebarDropZone> createState() => _SidebarDropZoneState();
}

class _SidebarDropZoneState extends State<_SidebarDropZone> {
  /// The placement under the pointer while an accepted item hovers here.
  SidebarDropPlacement? _placement;

  bool _accepts(SidebarDragItem item) => widget.accepts?.call(item) ?? true;

  SidebarDropPlacement _placementAt(SidebarDragItem item, Offset global) {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.height <= 0) {
      return widget.placementFor(item, 0.5);
    }
    final double fraction =
        (box.globalToLocal(global).dy / box.size.height).clamp(0.0, 1.0);
    return widget.placementFor(item, fraction);
  }

  void _show(SidebarDropPlacement? placement) {
    if (placement != _placement) setState(() => _placement = placement);
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<SidebarDragItem>(
      onWillAcceptWithDetails: (DragTargetDetails<SidebarDragItem> d) =>
          _accepts(d.data),
      // A zone that refused the item may still get moves; ignore them.
      onMove: (DragTargetDetails<SidebarDragItem> d) {
        if (_accepts(d.data)) _show(_placementAt(d.data, d.offset));
      },
      onLeave: (_) => _show(null),
      onAcceptWithDetails: (DragTargetDetails<SidebarDragItem> d) {
        final SidebarDropPlacement placement = _placementAt(d.data, d.offset);
        _show(null);
        widget.onDrop(d.data, placement);
      },
      builder: (
        BuildContext context,
        List<SidebarDragItem?> candidates,
        List<dynamic> rejected,
      ) {
        final SidebarDropPlacement? shown =
            candidates.isEmpty ? null : _placement;
        return Stack(
          children: <Widget>[
            widget.child,
            if (shown == SidebarDropPlacement.inside)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: AppPalette.primary, width: 2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
            if (shown == SidebarDropPlacement.before ||
                shown == SidebarDropPlacement.after)
              Positioned(
                left: AppSpacing.sm,
                right: AppSpacing.sm,
                top: shown == SidebarDropPlacement.before ? 0 : null,
                bottom: shown == SidebarDropPlacement.after ? 0 : null,
                height: 2,
                child: const IgnorePointer(
                  child: ColoredBox(color: AppPalette.primary),
                ),
              ),
            if (shown != null && widget.hoverHint != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Text(
                      widget.hoverHint!,
                      style: const TextStyle(color: AppPalette.textSecondary),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The chip that follows the pointer while a sidebar row is dragged.
class _SidebarDragChip extends StatelessWidget {
  const _SidebarDragChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    // The drag is anchored at the pointer; nudge the chip off the cursor.
    return Transform.translate(
      offset: const Offset(12, -18),
      child: Material(
        color: AppPalette.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 280),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppPalette.surfaceVariant,
            borderRadius: AppStyle.pillRadius,
            border: Border.all(color: AppPalette.primary),
            boxShadow: AppStyle.hoverShadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 16, color: AppPalette.textSecondary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppPalette.textPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
