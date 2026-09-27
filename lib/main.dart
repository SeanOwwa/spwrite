/// Application entry point and root composition for Writing_App v2
/// (Req 4.6, 5.1, 5.4, 17.4, 17.7, 18.1, 18.4, 19.5).
///
/// [main] runs the v2 startup sequence in order: it initializes the Flutter
/// binding, selects the platform SQLite factory
/// ([DatabaseProvider.initPlatformFactory]), and awaits
/// [DatabaseProvider.openAppDatabase] so the v2 schema exists before the first
/// frame renders (Req 17.7, 18.4). It then wires the layers together — the three
/// `Sqlite*Repository` implementations over the one open [Database], and
/// [AppNavigationState] over the [ProjectRepository] with a workspace factory
/// that builds a [ProjectWorkspaceState] from the folder / document
/// repositories (Req 5.1, 5.2) — and hands the navigation state to [SpwriteApp]
/// before triggering the initial [AppNavigationState.loadProjects] (Req 1.1,
/// 17.5).
///
/// [SpwriteApp] is the root `MaterialApp`: it hosts [AppNavigationState] via
/// `provider` and applies [AppTheme.dark] at the root so every surface inherits
/// the dark palette before it renders (Req 18.1, 18.4). [AppRoot] switches
/// between the [DashboardView] (no Active_Project) and the [WorkspaceShell] (a
/// project is open) (Req 5.1, 5.4, 4.6). [WorkspaceShell] — the v2 evolution of
/// v1's `AppShell` — lays the Project_Sidebar and Editor out responsively (side
/// by side on wide screens, Sidebar in a navigation drawer on narrow ones),
/// hosts the back-to-dashboard control, and surfaces the transient errors of
/// both notifiers as snackbars.
library;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:provider/provider.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;

import 'data/database_provider.dart';
import 'data/sqlite_character_repository.dart';
import 'data/sqlite_document_repository.dart';
import 'data/sqlite_folder_repository.dart';
import 'data/sqlite_project_repository.dart';
import 'domain/character_repository.dart';
import 'domain/document_repository.dart';
import 'domain/folder_repository.dart';
import 'domain/project.dart';
import 'domain/project_repository.dart';
import 'presentation/dashboard_view.dart';
import 'presentation/editor_view.dart';
import 'presentation/error_surfaces.dart';
import 'presentation/project_sidebar_view.dart';
import 'state/app_navigation_state.dart';
import 'state/character_panel_state.dart';
import 'state/load_status.dart';
import 'state/project_workspace_state.dart';
import 'theme/app_theme.dart';

/// Runs the v2 startup sequence and launches [SpwriteApp] (Req 17.4, 17.7,
/// 5.1, 5.2).
///
/// The database is opened with `await` so the file and v2 schema are created
/// before the first frame, guaranteeing that the initial project load and any
/// early persistence operate against an existing schema (Req 17.7). The three
/// repositories are constructed over the one open [Database] and shared: the
/// [ProjectRepository] backs [AppNavigationState], and the folder / document
/// repositories are captured by the workspace factory so each opened project
/// gets a [ProjectWorkspaceState] over the same store (Req 5.1, 5.2).
///
/// Once the widget tree is running, the initial project-list load is triggered
/// (Req 1.1, 17.5); it runs fire-and-forget so the first frame is not blocked
/// on it — the Dashboard reflects the load status as it progresses.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Select and configure the platform-appropriate SQLite factory before any
  // database call (web uses the IndexedDB WASM factory; desktop uses FFI;
  // mobile uses the default plugin factory) (Req 17.4).
  DatabaseProvider.initPlatformFactory();

  // Open (creating if absent) the v2 database and create the schema up front,
  // so the schema exists before the first frame renders (Req 17.7).
  //
  // The open is wrapped so that a startup failure never leaves the app stuck
  // on a blank frame: the error is logged and re-thrown so the platform console
  // shows the concrete cause.
  final Database db;
  try {
    db = await DatabaseProvider.openAppDatabase();
  } catch (error, stack) {
    debugPrint('DATABASE OPEN FAILED: $error');
    debugPrintStack(stackTrace: stack);
    rethrow;
  }

  // Wire the layers: the repositories over the one open database.
  final ProjectRepository projectRepository = SqliteProjectRepository(db);
  final FolderRepository folderRepository = SqliteFolderRepository(db);
  final DocumentRepository documentRepository = SqliteDocumentRepository(db);
  final CharacterRepository characterRepository =
      SqliteCharacterRepository(db);

  // The workspace factory builds a ProjectWorkspaceState for a freshly opened
  // project over the folder / document repositories and kicks off its contents
  // load (Req 5.1, 5.2). AppNavigationState treats the result only as a
  // ChangeNotifier, keeping the concrete workspace type out of the state layer.
  final appState = AppNavigationState(
    projectRepository,
    (Project project) {
      final workspace = ProjectWorkspaceState(
        project,
        folderRepository,
        documentRepository,
      );
      // Req 5.2: load the opened project's folders and documents. Fire-and-
      // forget so opening a project stays responsive; the Sidebar observes the
      // contents-load status.
      workspace.loadContents();
      return workspace;
    },
  );

  runApp(SpwriteApp(
    appState: appState,
    characterRepository: characterRepository,
  ));

  // Trigger the initial project-list load after startup (Req 1.1, 17.5).
  // Fire-and-forget so it does not block the first frame; the Dashboard
  // observes the load status.
  appState.loadProjects();
}

/// The root application widget.
///
/// Hosts the [AppNavigationState] created in [main] via
/// [ChangeNotifierProvider.value] (the instance is owned by [main] and lives
/// for the life of the app) and applies [AppTheme.dark] as both `theme` and
/// `darkTheme` with [ThemeMode.dark], so the dark palette is applied at the
/// root before any surface renders (Req 18.1, 18.4).
class SpwriteApp extends StatelessWidget {
  /// The single [AppNavigationState] the whole widget tree observes,
  /// constructed in [main].
  final AppNavigationState appState;

  /// The character persistence abstraction, provided to the tree so the
  /// per-project [CharacterPanelState] can be built when a project is open.
  final CharacterRepository characterRepository;

  const SpwriteApp({
    super.key,
    required this.appState,
    required this.characterRepository,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppNavigationState>.value(value: appState),
        Provider<CharacterRepository>.value(value: characterRepository),
      ],
      child: MaterialApp(
        title: 'Spwrite',
        debugShowCheckedModeBanner: false,
        // flutter_quill requires its localization delegate (plus the global
        // Material/Widgets/Cupertino delegates it bundles) to be registered on
        // the app; without them the Quill editor and toolbar throw
        // MissingFlutterQuillLocalizationException at build time.
        localizationsDelegates: FlutterQuillLocalizations.localizationsDelegates,
        supportedLocales: FlutterQuillLocalizations.supportedLocales,
        // Apply the dark theme unconditionally at the root (Req 18.1, 18.4).
        theme: AppTheme.dark,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        home: const AppRoot(),
      ),
    );
  }
}

/// Switches between the two top-level navigation surfaces based on whether a
/// project is open (Req 5.1, 5.4, 4.6).
///
/// When [AppNavigationState.activeProject] is `null` the [DashboardView] is
/// shown. When a project is open, the [AppNavigationState.activeWorkspace]
/// (a [ProjectWorkspaceState]) is provided to the subtree and the
/// [WorkspaceShell] is shown. Because the active workspace is keyed by the
/// project id, opening a different project (or reopening after a close) rebuilds
/// the shell against the fresh workspace rather than reusing a stale one.
class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    // Observe the navigation state so the root rebuilds when the Active_Project
    // is opened, closed, or deleted (Req 5.1, 5.4, 4.6).
    final AppNavigationState nav = context.watch<AppNavigationState>();
    final Project? activeProject = nav.activeProject;
    final ChangeNotifier? workspace = nav.activeWorkspace;

    // No Active_Project: show the Dashboard (Req 5.1). Returning here after a
    // close / delete naturally clears the Editor because the workspace is gone
    // (Req 5.4, 4.6).
    if (activeProject == null || workspace is! ProjectWorkspaceState) {
      return const DashboardView();
    }

    // A project is open: provide its workspace and a project-scoped
    // CharacterPanelState to the subtree, then show the shell. The value keys
    // tie both providers to the open project's id so opening a different
    // project (or reopening) rebuilds them against the fresh project rather
    // than reusing stale state. The CharacterPanelState is created here (and
    // disposed by the provider when the project changes) and kicks off its
    // initial load.
    final CharacterRepository characterRepository =
        context.read<CharacterRepository>();
    return MultiProvider(
      key: ValueKey<String>(activeProject.id),
      providers: [
        ChangeNotifierProvider<ProjectWorkspaceState>.value(value: workspace),
        ChangeNotifierProvider<CharacterPanelState>(
          create: (_) =>
              CharacterPanelState(activeProject.id, characterRepository)
                ..load(),
        ),
      ],
      child: const WorkspaceShell(),
    );
  }
}

/// The responsive layout host for the Project_Sidebar and Editor while a
/// project is open (Req 5.4, 6, 14).
///
/// On wide screens (width at or above [_wideBreakpoint]) the Project_Sidebar
/// sits beside the Editor in a [Row]. On narrow screens the Sidebar becomes a
/// navigation [Drawer] opened from an [AppBar] menu button, and the Editor
/// fills the body; selecting a document closes the drawer.
///
/// This is the v2 evolution of v1's `AppShell`. A [StatefulWidget] so it can
/// register listeners on both notifiers to surface their transient errors as
/// snackbars and, on narrow layouts, close the drawer when the Active_Document
/// changes.
class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({super.key});

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  /// The width at or above which the Sidebar and Editor are shown side by side;
  /// below it the Sidebar collapses into a navigation drawer.
  static const double _wideBreakpoint = 700;

  /// The fixed width of the Project_Sidebar in the wide, side-by-side layout.
  static const double _sidebarWidth = 320;

  /// Controls the narrow-layout [Scaffold] so the active-document listener can
  /// close the drawer on selection.
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// The navigation state being observed, captured so its listener can be
  /// removed in [dispose].
  AppNavigationState? _nav;

  /// The workspace state being observed, captured so its listener can be
  /// removed in [dispose] and re-registered when the open project changes.
  ProjectWorkspaceState? _workspace;

  /// The id of the Active_Document at the time of the last workspace callback,
  /// used to detect a change so the drawer is closed only on a genuine
  /// selection.
  String? _lastActiveId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // (Re)register the navigation-state listener if the provided instance
    // changed, so a failed open / delete / rename surfaces as a snackbar.
    final AppNavigationState nav = context.read<AppNavigationState>();
    if (!identical(nav, _nav)) {
      _nav?.removeListener(_onNavChanged);
      _nav = nav;
      nav.addListener(_onNavChanged);
    }

    // (Re)register the workspace listener if the provided instance changed
    // (a different project was opened), so folder / document / save errors
    // surface and the drawer closes on selection.
    final ProjectWorkspaceState workspace =
        context.read<ProjectWorkspaceState>();
    if (!identical(workspace, _workspace)) {
      _workspace?.removeListener(_onWorkspaceChanged);
      _workspace = workspace;
      _lastActiveId = workspace.activeDocument?.id;
      workspace.addListener(_onWorkspaceChanged);
    }
  }

  @override
  void dispose() {
    _nav?.removeListener(_onNavChanged);
    _workspace?.removeListener(_onWorkspaceChanged);
    super.dispose();
  }

  /// Reacts to [AppNavigationState] changes: surfaces any pending transient
  /// error (a failed open / delete / rename) as a snackbar then clears it so it
  /// is not shown again on the next rebuild (Req 5.3, 4.4).
  void _onNavChanged() {
    final AppNavigationState? nav = _nav;
    if (nav == null || !mounted) return;
    _surfaceError(nav.transientError, nav.clearTransientError);
  }

  /// Reacts to [ProjectWorkspaceState] changes: closes the navigation drawer
  /// when the Active_Document changes on a narrow layout (so tapping a list item
  /// returns the user to the Editor), and surfaces any pending transient error
  /// (a failed contents load, folder / document mutation, or save) as a
  /// snackbar then clears it (Req 6.11, 7.6, 9.4, 10.7, 13.3, 16.2).
  ///
  /// A contents-load failure is already presented inline by the Sidebar's
  /// error banner (Req 6.11), so the snackbar is skipped in that case to avoid
  /// a duplicate surface.
  void _onWorkspaceChanged() {
    final ProjectWorkspaceState? workspace = _workspace;
    if (workspace == null || !mounted) return;

    // Close the drawer when the Active_Document changes (a selection was made),
    // so tapping a list item on narrow screens returns the user to the Editor.
    final String? activeId = workspace.activeDocument?.id;
    if (activeId != _lastActiveId) {
      _lastActiveId = activeId;
      if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
        Navigator.of(context).pop();
      }
    }

    if (workspace.contentsStatus == LoadStatus.error) {
      // The Sidebar shows the contents-load failure inline; skip the snackbar.
      return;
    }
    _surfaceError(workspace.transientError, workspace.clearTransientError);
  }

  /// Surfaces [error] once as a snackbar (deferred to after the current
  /// notification settles so it does not run during a build / layout phase),
  /// then invokes [clear] so the same error is not shown again on the next
  /// rebuild.
  void _surfaceError(String? error, VoidCallback clear) {
    if (error == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showErrorSnackBar(context, error);
      clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool isWide = constraints.maxWidth >= _wideBreakpoint;
        return isWide ? _buildWideLayout() : _buildNarrowLayout();
      },
    );
  }

  /// Wide layout: the Project_Sidebar (fixed width) sits beside the Editor. The
  /// [Scaffold] hosts the [ScaffoldMessenger] used by [showErrorSnackBar].
  Widget _buildWideLayout() {
    return const Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(width: _sidebarWidth, child: ProjectSidebarView()),
          VerticalDivider(width: 1, thickness: 1),
          Expanded(child: EditorView()),
        ],
      ),
    );
  }

  /// Narrow layout: the Project_Sidebar lives in a navigation [Drawer] opened
  /// from the [AppBar] menu button, and the Editor fills the body. The
  /// [AppBar] title shows the Active_Project name. The [Scaffold] hosts the
  /// [ScaffoldMessenger] used by [showErrorSnackBar].
  Widget _buildNarrowLayout() {
    final String projectName = _workspace?.project.name ?? 'Project';
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(
          projectName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      drawer: const Drawer(
        child: SafeArea(child: ProjectSidebarView()),
      ),
      body: const EditorView(),
    );
  }
}
