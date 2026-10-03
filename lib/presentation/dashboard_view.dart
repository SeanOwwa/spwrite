/// Presentation layer: [DashboardView], the landing surface that lists every
/// Project and hosts the project-management controls — create, edit (rename +
/// cover photo), delete, and open (Req 1.1, 1.2, 1.3, 1.4, 1.5, 2.1, 3.1, 4.1,
/// 5.1).
///
/// The view is a thin observer over [AppNavigationState]: it watches the
/// state's `projects`, `projectsStatus`, and `transientError`, and dispatches
/// every user intent back to the state layer (`createProject`,
/// `updateProject`, `deleteProject`, `openProject`, `clearTransientError`). It
/// owns no project data of its own. Create and edit both go through the
/// [ProjectDetailsDialog], which collects the name and optional cover photo.
///
/// Ordering is already applied by the state layer (Req 1.2, 1.4), so the grid
/// is rendered in the order [AppNavigationState.projects] returns. The grid is
/// responsive: portrait cover cards flow into as many columns as fit. Cmd+N
/// (macOS) / Ctrl+N (Windows, Linux) opens the create dialog. Every color is
/// drawn from [AppPalette] (Req 18.2, 18.5).
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_info.dart';

import '../domain/project.dart';
import '../state/app_navigation_state.dart';
import '../state/guide_visibility_state.dart';
import '../state/load_status.dart';
import '../theme/app_theme.dart';
import 'delete_confirmation_dialog.dart';
import 'error_surfaces.dart';
import 'project_card.dart';
import 'project_details_dialog.dart';

/// Whether the platform uses Cmd (Apple) rather than Ctrl for shortcuts.
bool _usesCommandKey(TargetPlatform platform) =>
    platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;

/// The Dashboard: a header with the New-project control, an optional projects
/// load-error banner, and the responsive grid of portrait cover cards (or an
/// empty state when zero projects exist).
class DashboardView extends StatefulWidget {
  /// Picks the source bytes for a cover photo. Defaults to the native file
  /// dialog; injectable for tests.
  final CoverBytesPicker pickCoverBytes;

  /// Normalizes picked cover bytes. Defaults to the isolate-backed
  /// normalizer; injectable for tests.
  final CoverNormalizer? normalizeCover;

  const DashboardView({
    super.key,
    this.pickCoverBytes = pickCoverBytesWithFileSelector,
    this.normalizeCover,
  });

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  /// The smallest comfortable card width; the grid adds columns as the window
  /// widens past multiples of it.
  static const double _minCardWidth = 190;

  /// The spacing between cards.
  static const double _gridSpacing = AppSpacing.xl;

  /// Whether a create / edit dialog is already showing (guards the shortcut).
  bool _dialogOpen = false;

  Future<ProjectDetailsResult?> _showDetails({Project? project}) async {
    if (_dialogOpen) return null;
    _dialogOpen = true;
    try {
      final CoverNormalizer? normalizer = widget.normalizeCover;
      return normalizer == null
          ? await ProjectDetailsDialog.show(
              context,
              project: project,
              pickCoverBytes: widget.pickCoverBytes,
            )
          : await ProjectDetailsDialog.show(
              context,
              project: project,
              pickCoverBytes: widget.pickCoverBytes,
              normalizeCover: normalizer,
            );
    } finally {
      _dialogOpen = false;
    }
  }

  /// Opens the create dialog and forwards a confirmed result to the
  /// authoritative create flow (Req 2.1, 2.2).
  Future<void> _create(AppNavigationState state) async {
    final ProjectDetailsResult? result = await _showDetails();
    if (result == null) return;
    await state.createProject(result.name, coverImage: result.coverImage);
  }

  /// Opens the edit dialog for [project] (Req 3.1) and forwards a confirmed
  /// rename / cover change to the state layer, which re-validates and
  /// persists it. Cancelling keeps everything unchanged (Req 3.6).
  Future<void> _edit(AppNavigationState state, Project project) async {
    final ProjectDetailsResult? result = await _showDetails(project: project);
    if (result == null) return;
    if (!result.coverChanged) {
      await state.renameProject(project.id, result.name);
      return;
    }
    await state.updateProject(
      project.id,
      name: result.name,
      coverImage: result.coverImage,
      clearCoverImage: result.coverImage == null,
    );
  }

  /// Shows the delete confirmation prompt for [project]; on confirmation,
  /// dispatches the delete to the state layer (Req 4.1). Cancelling leaves the
  /// project untouched (Req 4.3).
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
    final AppNavigationState state = context.watch<AppNavigationState>();
    // The built-in guides are pinned first, unless the "Guides" switch hides
    // them. The visibility state is optional so the dashboard also works
    // without it (guides then stay visible).
    final bool showGuides =
        context.watch<GuideVisibilityState?>()?.visible ?? true;
    final List<Project> projects = <Project>[
      if (showGuides) ...state.builtInProjects,
      ...state.userProjects,
    ];
    final bool hasLoadError = state.projectsStatus == LoadStatus.error;
    final bool isLoading =
        state.projectsStatus == LoadStatus.loading && projects.isEmpty;

    // Cmd+N / Ctrl+N opens the create dialog from anywhere on the Dashboard.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () {
          if (_usesCommandKey(defaultTargetPlatform)) _create(state);
        },
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () {
          if (!_usesCommandKey(defaultTargetPlatform)) _create(state);
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: AppPalette.background,
          body: DecoratedBox(
            decoration: const BoxDecoration(gradient: AppStyle.appBackground),
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1440),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _buildHeader(context, state),
                      // The load-error banner sits above the grid and retains
                      // the previously displayed projects beneath it (Req 1.5).
                      if (hasLoadError)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xl,
                          ),
                          child: ErrorBanner(
                            message: state.transientError ??
                                'Projects could not be loaded.',
                            onDismiss: state.clearTransientError,
                          ),
                        ),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: AppMotion.medium,
                          child: isLoading
                              ? const Center(
                                  key: ValueKey<String>('loading'),
                                  child: CircularProgressIndicator(),
                                )
                              : projects.isEmpty
                                  ? _buildEmptyState(state)
                                  : _buildProjectGrid(context, state, projects),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The Dashboard header: the brand mark, the "Projects" title with the app
  /// version label and a count, and the New-project control (Req 2.1).
  Widget _buildHeader(BuildContext context, AppNavigationState state) {
    final TextTheme text = Theme.of(context).textTheme;
    // Count only the writer's own projects; the guides are always there.
    final int count = state.userProjects.length;
    final String subtitle = count == 0
        ? 'No projects yet'
        : count == 1
            ? '1 project'
            : '$count projects';
    final String shortcut =
        _usesCommandKey(Theme.of(context).platform) ? '⌘N' : 'Ctrl+N';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.lg,
      ),
      child: Row(
        children: <Widget>[
          const _LogoTile(size: 48, radius: 14, padding: 3),
          const SizedBox(width: AppSpacing.md + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: <Widget>[
                    Semantics(
                      header: true,
                      child: Text('Projects', style: text.headlineMedium),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    // Small, subtle release label (e.g. "Beta 1.3.4") so
                    // testers can tell which build they are running.
                    Semantics(
                      container: true,
                      label: 'Version ${AppInfo.version}',
                      excludeSemantics: true,
                      child: Text(
                        AppInfo.version,
                        key: const ValueKey<String>('app-version-label'),
                        style: text.labelSmall?.copyWith(
                          color: AppPalette.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  subtitle,
                  style: text.bodyMedium?.copyWith(
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          if (state.builtInProjects.isNotEmpty) ...<Widget>[
            const _GuidesSwitch(),
            const SizedBox(width: AppSpacing.md),
          ],
          Tooltip(
            message: 'New project ($shortcut)',
            child: FilledButton.icon(
              onPressed: () => _create(state),
              icon: const Icon(Icons.add, size: 20),
              label: const Text('New project'),
            ),
          ),
        ],
      ),
    );
  }

  /// The centered empty-state message shown when there are zero projects,
  /// prompting the user to create one (Req 1.3).
  Widget _buildEmptyState(AppNavigationState state) {
    final TextTheme text = Theme.of(context).textTheme;
    return Center(
      key: const ValueKey<String>('empty'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const _LogoTile(size: 140, radius: 28, padding: 10),
            const SizedBox(height: AppSpacing.xl),
            Text(
              'No projects yet',
              textAlign: TextAlign.center,
              style: text.titleLarge,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Create your first project to start writing.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.xl - 4),
            FilledButton.icon(
              onPressed: () => _create(state),
              icon: const Icon(Icons.add, size: 20),
              label: const Text('New project'),
            ),
          ],
        ),
      ),
    );
  }

  /// The ordered, responsive grid of portrait cover cards (Req 1.1, 1.2). The
  /// column count adapts to the window width; each cell keeps the cover at a
  /// 1:1.6 ratio above a fixed-height footer.
  Widget _buildProjectGrid(
    BuildContext context,
    AppNavigationState state,
    List<Project> projects,
  ) {
    return LayoutBuilder(
      key: const ValueKey<String>('grid'),
      builder: (BuildContext context, BoxConstraints constraints) {
        const double padding = AppSpacing.xl;
        final double available = math.max(
          0,
          constraints.maxWidth - padding * 2,
        );
        final int columns = math.max(
          1,
          ((available + _gridSpacing) / (_minCardWidth + _gridSpacing))
              .floor(),
        );
        final double tileWidth =
            (available - _gridSpacing * (columns - 1)) / columns;
        // Cover width = tile minus the card's inner padding and border.
        final double coverWidth = math.max(0, tileWidth - AppSpacing.sm * 2 - 2);
        final double tileHeight = coverWidth / AppStyle.coverAspectRatio +
            ProjectCard.footerHeight +
            AppSpacing.sm +
            2;

        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(
            padding,
            AppSpacing.sm,
            padding,
            AppSpacing.xxl,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: tileHeight,
            crossAxisSpacing: _gridSpacing,
            mainAxisSpacing: _gridSpacing,
          ),
          itemCount: projects.length,
          itemBuilder: (BuildContext context, int index) {
            final Project project = projects[index];
            // Built-in guides open like any project but cannot be edited or
            // deleted; the header switch hides them instead.
            final bool builtIn = state.isBuiltIn(project.id);
            return ProjectCard(
              key: ValueKey<String>('project-card-${project.id}'),
              project: project,
              onOpen: () => state.openProject(project.id),
              onRename: builtIn ? null : () => _edit(state, project),
              onDelete: builtIn
                  ? null
                  : () => _confirmDelete(context, state, project),
              caption: builtIn ? 'Built-in guide · read-only' : null,
            );
          },
        );
      },
    );
  }
}

/// The Spwrite brand mark on its light tile (the logo art is drawn for a light
/// background, so it is shown in full on [AppPalette.logoTile]).
class _LogoTile extends StatelessWidget {
  final double size;
  final double radius;
  final double padding;

  const _LogoTile({
    required this.size,
    required this.radius,
    required this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: AppPalette.logoTile,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: AppStyle.cardShadow,
      ),
      child: Image.asset(
        'assets/images/spwrite_logo.png',
        fit: BoxFit.contain,
        semanticLabel: 'Spwrite logo',
      ),
    );
  }
}

/// The "Guides" switch beside New project: shows or hides the built-in User
/// Guide and Developer Guide projects. The choice is remembered.
class _GuidesSwitch extends StatelessWidget {
  const _GuidesSwitch();

  @override
  Widget build(BuildContext context) {
    final GuideVisibilityState? guides = context.watch<GuideVisibilityState?>();
    if (guides == null) return const SizedBox.shrink();
    final bool visible = guides.visible;
    return Tooltip(
      message: visible ? 'Hide the built-in guides' : 'Show the built-in guides',
      child: MergeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Guides',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: AppPalette.textSecondary,
                  ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Switch(
              key: const ValueKey<String>('dashboard-guides-switch'),
              value: visible,
              onChanged: guides.setVisible,
            ),
          ],
        ),
      ),
    );
  }
}
