/// Presentation layer: [DashboardView], the landing surface that lists every
/// Project and hosts the project-management controls — create, rename, delete,
/// and open (Req 1.1, 1.2, 1.3, 1.4, 1.5, 2.1, 3.1, 4.1, 5.1).
///
/// The view is a thin observer over [AppNavigationState], mirroring v1's
/// `SidebarView` convention: it watches the state's `projects`,
/// `projectsStatus`, and `transientError`, and dispatches every user intent
/// back to the state layer (`createProject`, `renameProject`, `deleteProject`,
/// `openProject`, `clearTransientError`). It owns no project data of its own;
/// the only local state it keeps is whether the create field is open and which
/// card is currently in inline-rename mode.
///
/// Ordering is already applied by the state layer (Req 1.2, 1.4), so the grid
/// is rendered in the order [AppNavigationState.projects] returns. Every color
/// is drawn from [AppPalette] so no surface falls back to a light-mode or
/// system-default color (Req 18.2, 18.5).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/project.dart';
import '../state/app_navigation_state.dart';
import '../state/load_status.dart';
import '../theme/app_theme.dart';
import 'delete_confirmation_dialog.dart';
import 'error_surfaces.dart';
import 'name_field.dart';
import 'project_card.dart';

/// The Dashboard: a header with a create-project (+) control, an optional
/// projects load-error banner, and the ordered project grid (or an empty-state
/// message when zero projects exist).
///
/// A [StatefulWidget] because it tracks two pieces of transient UI state that
/// do not belong in the state layer: whether the inline create field is open
/// ([_isCreating]) and the id of the project currently switched into
/// inline-rename mode ([_renamingId]). All project data itself lives in
/// [AppNavigationState].
class DashboardView extends StatefulWidget {
  const DashboardView({super.key});

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  /// Whether the inline create-project [NameField] is currently open (Req 2.1).
  bool _isCreating = false;

  /// The id of the project currently switched into inline-rename mode, or
  /// `null` when no card is being renamed (Req 3.1). Only one card can be in
  /// rename mode at a time.
  String? _renamingId;

  /// Opens the inline create-project field (Req 2.1).
  void _beginCreate() {
    setState(() {
      _isCreating = true;
      // Leaving rename mode keeps only one inline field open at a time.
      _renamingId = null;
    });
  }

  /// Closes the inline create-project field, discarding the entry (Req 2.1).
  void _endCreate() {
    if (!_isCreating) return;
    setState(() => _isCreating = false);
  }

  /// Confirms a create: forwards the entered name to the authoritative create
  /// flow, then closes the field (Req 2.1, 2.2). The state layer re-validates,
  /// trims, and persists [name].
  void _confirmCreate(AppNavigationState state, String name) {
    state.createProject(name);
    _endCreate();
  }

  /// Enters inline-rename mode for the project identified by [id] (Req 3.1).
  void _beginRename(String id) {
    setState(() {
      _renamingId = id;
      // Only one inline field open at a time.
      _isCreating = false;
    });
  }

  /// Exits inline-rename mode, retaining whatever name the state layer holds
  /// (used on both confirm and cancel, Req 3.6).
  void _endRename() {
    if (_renamingId == null) return;
    setState(() => _renamingId = null);
  }

  /// Confirms a rename: forwards the new name to the authoritative rename flow
  /// then leaves edit mode (Req 3.1, 3.6). The state layer re-validates and
  /// persists [newName].
  void _confirmRename(AppNavigationState state, String id, String newName) {
    state.renameProject(id, newName);
    _endRename();
  }

  /// Shows the delete confirmation prompt for [project]; on confirmation,
  /// dispatches the delete to the state layer (Req 4.1). The prompt warns that
  /// the project's folders and documents will also be removed (Req 4.1).
  /// Cancelling leaves the project untouched (Req 4.3).
  Future<void> _confirmDelete(
    BuildContext context,
    AppNavigationState state,
    Project project,
  ) async {
    final bool confirmed = await DeleteConfirmationDialog.showForProject(
      context,
      projectName: projectDisplayName(project.name),
    );
    if (confirmed) {
      state.deleteProject(project.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Observe the state so the Dashboard rebuilds on any project / status
    // change (Req 1.1, 1.4, 1.5).
    final AppNavigationState state = context.watch<AppNavigationState>();
    final List<Project> projects = state.projects;
    final bool hasLoadError = state.projectsStatus == LoadStatus.error;

    // Scaffold provides the Material ancestor every Material widget in the
    // subtree needs (the inline NameField's TextField, cards, icon buttons)
    // and the ScaffoldMessenger used for snackbars. The Dashboard is a
    // top-level navigation surface rendered directly under MaterialApp, so it
    // must supply its own Scaffold. SafeArea keeps the header clear of device
    // notches / status bars.
    return Scaffold(
      backgroundColor: AppPalette.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(context, state),
            // Projects load-error banner sits above the grid and retains the
            // previously displayed projects beneath it (Req 1.5).
            if (hasLoadError)
              ErrorBanner(
                message:
                    state.transientError ?? 'Projects could not be loaded.',
                onDismiss: state.clearTransientError,
              ),
            Expanded(
              child: projects.isEmpty
                  ? _buildEmptyState()
                  : _buildProjectGrid(context, state, projects),
            ),
          ],
        ),
      ),
    );
  }

  /// The Dashboard header: a "Projects" label and the create-project (+)
  /// control that opens the inline [NameField] (Req 2.1). While the create
  /// field is open it replaces the label row so the user can enter a name.
  Widget _buildHeader(BuildContext context, AppNavigationState state) {
    if (_isCreating) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: NameField(
          initialValue: '',
          onConfirm: (String name) => _confirmCreate(state, name),
          onCancel: _endCreate,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: <Widget>[
          const Expanded(
            child: Text(
              'Projects',
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Create project',
            icon: const Icon(Icons.add, color: AppPalette.primary),
            onPressed: _beginCreate,
          ),
        ],
      ),
    );
  }

  /// The centered empty-state message shown when there are zero projects,
  /// prompting the user to create one (Req 1.3).
  Widget _buildEmptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          'No projects yet. Create one to get started.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppPalette.textSecondary),
        ),
      ),
    );
  }

  /// The ordered project grid (Req 1.1, 1.2). Each cell is either a
  /// [ProjectCard] with open / rename / delete controls, or — when that
  /// project is in rename mode — an inline [NameField] in its place (Req 3.1).
  ///
  /// A responsive [GridView] adapts the column count to the available width so
  /// the grid reads well on both wide desktop / web windows and narrow mobile
  /// screens.
  Widget _buildProjectGrid(
    BuildContext context,
    AppNavigationState state,
    List<Project> projects,
  ) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 320,
        mainAxisExtent: 64,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: projects.length,
      itemBuilder: (BuildContext context, int index) {
        final Project project = projects[index];

        // Inline-rename mode: render the editable field in place of the card
        // (Req 3.1). Confirm forwards to renameProject then exits; cancel
        // simply exits, retaining the name (Req 3.6).
        if (_renamingId == project.id) {
          return Card(
            color: AppPalette.surface,
            surfaceTintColor: AppPalette.surface,
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: NameField(
                initialValue: project.name,
                onConfirm: (String newName) =>
                    _confirmRename(state, project.id, newName),
                onCancel: _endRename,
              ),
            ),
          );
        }

        // Normal card: name, open on tap, trailing rename / delete controls
        // (Req 1.1, 3.1, 4.1, 5.1).
        return ProjectCard(
          project: project,
          onOpen: () => state.openProject(project.id),
          onRename: () => _beginRename(project.id),
          onDelete: () => _confirmDelete(context, state, project),
        );
      },
    );
  }
}
