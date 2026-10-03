/// State layer: [AppNavigationState], the `ChangeNotifier` that owns the
/// projects Dashboard concern — the ordered project list, the Active_Project
/// reference, dashboard load status, transient errors, and (when a project is
/// open) the active workspace notifier.
///
/// It mirrors v1's `DocumentAppState` at the project level: the UI observes it
/// via `provider`; it depends only on the [ProjectRepository] abstraction,
/// never on SQLite directly; ordering is re-applied in memory after each
/// mutation (Req 1.4); startup vs. later load failures are distinguished
/// (Req 17.8 vs. Req 1.5); and failures retain in-memory truth while surfacing
/// a recoverable [transientError] (Req 2.6, 3.7, 4.4).
///
/// Opening a project constructs a workspace notifier via the injected
/// [WorkspaceFactory]; returning to the Dashboard (or deleting the
/// Active_Project) disposes it, which cleanly clears the editor (Req 5.4,
/// 4.6). The concrete factory (wired in `main()`) builds a
/// `ProjectWorkspaceState`; this file avoids importing that concrete type so
/// the two states can be built in parallel — the workspace is exposed only as
/// a [ChangeNotifier] via [activeWorkspace].
library;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../domain/guides/built_in_guide.dart';
import '../domain/project.dart';
import '../domain/project_repository.dart';
import 'load_status.dart';

/// Builds the workspace notifier for a freshly opened [project] (Req 5.1, 5.2).
///
/// Defined here — rather than importing the concrete `ProjectWorkspaceState` —
/// so [AppNavigationState] can be built independently of the workspace state.
/// The concrete wiring in `main()` supplies a factory that constructs a
/// `ProjectWorkspaceState`; here the returned object is treated only as a
/// [ChangeNotifier].
typedef WorkspaceFactory = ChangeNotifier Function(Project project);

/// The single source of truth for the Dashboard the UI observes. Owns the
/// ordered project list, the Active_Project, dashboard status, and the active
/// workspace notifier.
class AppNavigationState extends ChangeNotifier {
  /// Persistence abstraction. The state layer talks only to this interface,
  /// keeping it decoupled from SQLite.
  final ProjectRepository _repository;

  /// Builds the workspace notifier when a project is opened (Req 5.1, 5.2).
  final WorkspaceFactory _workspaceFactory;

  /// Generates UUID v4 identifiers for new projects (Req 2.2).
  final Uuid _uuid;

  /// The ordered project list backing store, kept sorted by the shared
  /// [compareProjects] rule (Req 1.4).
  List<Project> _projects = <Project>[];

  /// The Active_Project, or `null` when on the Dashboard.
  Project? _activeProject;

  /// The workspace notifier for the open project, or `null` on the Dashboard.
  /// Exposed as a [ChangeNotifier] so the concrete type stays decoupled.
  ChangeNotifier? _activeWorkspace;

  /// Status of the project-list load (Req 1.1, 1.5, 17.8).
  LoadStatus _projectsStatus = LoadStatus.idle;

  /// A recoverable message surfaced via a transient banner / snackbar, or
  /// `null` when there is nothing to show (Req 2.6, 3.7, 4.4).
  String? _transientError;

  /// Whether the initial startup load has occurred. Distinguishes a startup
  /// load failure (expose an empty set with an error, Req 17.8) from a later
  /// reload failure (retain the previous list with an error, Req 1.5).
  bool _hasStartedUp = false;

  /// Creates the state over a [repository] and a [workspaceFactory]. A custom
  /// [uuid] generator may be injected for tests; otherwise the default is used.
  AppNavigationState(
    ProjectRepository repository,
    WorkspaceFactory workspaceFactory, {
    Uuid? uuid,
    BuiltInProjectPolicy? builtInPolicy,
  })  : _repository = repository,
        _workspaceFactory = workspaceFactory,
        _uuid = uuid ?? const Uuid(),
        _builtIn = builtInPolicy;

  /// Identifies built-in guide projects, which can be opened but never
  /// deleted, renamed, or re-covered. `null` means there are none.
  final BuiltInProjectPolicy? _builtIn;

  /// Whether [projectId] is a built-in guide project.
  bool isBuiltIn(String projectId) => _builtIn?.isBuiltIn(projectId) ?? false;

  /// The built-in guide projects, in their fixed dashboard order.
  List<Project> get builtInProjects {
    final BuiltInProjectPolicy? policy = _builtIn;
    if (policy == null) return const <Project>[];
    return _projects.where((Project p) => policy.isBuiltIn(p.id)).toList()
      ..sort((Project a, Project b) =>
          policy.orderOf(a.id).compareTo(policy.orderOf(b.id)));
  }

  /// The writer's own projects (everything except the guides), in the usual
  /// last-edited order.
  List<Project> get userProjects =>
      _projects.where((Project p) => !isBuiltIn(p.id)).toList();

  /// The ordered project list for the Dashboard (Req 1.2, 1.4). Returned as an
  /// unmodifiable view so listeners cannot mutate the backing store.
  List<Project> get projects => List<Project>.unmodifiable(_projects);

  /// The Active_Project, or `null` when on the Dashboard.
  Project? get activeProject => _activeProject;

  /// The workspace notifier for the open project, or `null` on the Dashboard.
  ChangeNotifier? get activeWorkspace => _activeWorkspace;

  /// Status of the project-list load.
  LoadStatus get projectsStatus => _projectsStatus;

  /// The current transient error message, or `null` when none is pending.
  String? get transientError => _transientError;

  /// Clears the pending transient error (e.g. after the banner / snackbar has
  /// been shown or dismissed) and notifies listeners if anything changed.
  void clearTransientError() {
    if (_transientError == null) return;
    _transientError = null;
    notifyListeners();
  }

  /// Loads all projects from the repository, ordered by the shared
  /// [compareProjects] rule (Req 1.1, 1.2, 1.4, 17.5).
  ///
  /// On success the list is replaced and [projectsStatus] becomes
  /// [LoadStatus.loaded]. An empty store yields an empty list without error.
  ///
  /// On failure the behavior depends on whether startup has occurred:
  /// - **Startup failure** (first load): an empty set is exposed and
  ///   [projectsStatus] is set to [LoadStatus.error] with a [transientError]
  ///   message (Req 17.8).
  /// - **Post-startup failure** (a later reload): the previously displayed
  ///   list is retained and [projectsStatus] is set to [LoadStatus.error] with
  ///   a [transientError] message (Req 1.5).
  Future<void> loadProjects() async {
    final bool isStartup = !_hasStartedUp;

    _projectsStatus = LoadStatus.loading;
    notifyListeners();

    try {
      final List<Project> loaded = await _repository.getAll();
      // Re-apply the shared ordering in memory so the in-memory list and the
      // SQL `ORDER BY` always agree, even if an implementation returns rows
      // unsorted (Req 1.4).
      final List<Project> ordered = List<Project>.of(loaded)
        ..sort(compareProjects);
      _projects = ordered;
      _projectsStatus = LoadStatus.loaded;
      _transientError = null;
    } catch (_) {
      if (isStartup) {
        // Req 17.8: on startup failure, make an empty set available with an
        // error set.
        _projects = <Project>[];
      }
      // Req 1.5: after startup, retain the previously displayed list.
      _projectsStatus = LoadStatus.error;
      _transientError = 'Projects could not be loaded.';
    } finally {
      _hasStartedUp = true;
      notifyListeners();
    }
  }

  /// Creates a new project named [name], persists it, and inserts it into the
  /// ordered in-memory list (Req 2.2, 2.5).
  ///
  /// Leading / trailing whitespace is trimmed and validated:
  /// - **empty / whitespace-only** — rejected (Req 2.3): a [transientError]
  ///   states that a name is required.
  /// - **longer than 255 characters** — rejected (Req 2.4): a [transientError]
  ///   states the maximum name length.
  /// - **1..255 characters** — accepted (Req 2.2): a fresh UUID v4 identifies
  ///   the project, [Project.create] sets `modifiedAt == createdAt`, the entity
  ///   is persisted via [ProjectRepository.create], added to the list, the
  ///   shared [compareProjects] ordering is re-applied (Req 1.4), and any
  ///   pending transient error is cleared.
  ///
  /// On a repository failure the existing list is retained unchanged and a
  /// [transientError] is surfaced (Req 2.6).
  ///
  /// [coverImage] is an optional, already-normalized cover photo (see
  /// `normalizeCoverImage`) persisted with the new project.
  Future<void> createProject(String name, {Uint8List? coverImage}) async {
    final String trimmed = name.trim();

    // Req 2.3: empty / whitespace-only name — reject.
    if (trimmed.isEmpty) {
      _transientError = 'A name is required.';
      notifyListeners();
      return;
    }

    // Req 2.4: over-length name — reject.
    if (trimmed.length > 255) {
      _transientError = 'Name exceeds the 255 character maximum.';
      notifyListeners();
      return;
    }

    // Req 2.2: accept — build the entity with equal creation / modified stamps.
    final Project draft = Project.create(
      id: _uuid.v4(),
      name: trimmed,
      now: DateTime.now().toUtc(),
      coverImage: coverImage,
    );

    try {
      final Project created = await _repository.create(draft);
      // Add to the in-memory backing store and re-apply the shared ordering so
      // the list and the SQL `ORDER BY` agree (Req 1.4).
      final List<Project> updated = List<Project>.of(_projects)
        ..add(created)
        ..sort(compareProjects);
      _projects = updated;
      _transientError = null;
    } catch (_) {
      // Req 2.6: retain the existing list unchanged; surface a recoverable
      // error.
      _transientError = 'Project could not be created.';
    } finally {
      notifyListeners();
    }
  }

  /// Renames the project identified by [id] to [name] (Req 3.2, 3.3, 3.4).
  ///
  /// Leading / trailing whitespace is trimmed and validated against the trimmed
  /// value:
  /// - **1..255 characters** — accepted (Req 3.2): the project's name is set to
  ///   the trimmed value, its last-modified timestamp is advanced to now, the
  ///   change is persisted via [ProjectRepository.update], the in-memory list
  ///   entry is replaced, the shared [compareProjects] ordering is re-applied
  ///   (Req 1.4), and — when the renamed project is the Active_Project — the
  ///   active reference is updated too. Any pending transient error is cleared.
  /// - **empty / whitespace-only** — rejected (Req 3.3): the name and
  ///   last-modified timestamp are retained unchanged and a [transientError]
  ///   states that a name is required.
  /// - **longer than 255 characters** — rejected (Req 3.4): the name and
  ///   last-modified timestamp are retained unchanged and a [transientError]
  ///   states the maximum name length.
  ///
  /// On a repository failure the in-memory state is retained unchanged and a
  /// [transientError] indicating the save failed is surfaced (Req 3.7).
  ///
  /// Unknown [id]s (no matching in-memory project) are ignored.
  Future<void> renameProject(String id, String name) {
    // A rename keeps the existing cover photo untouched.
    return _saveProjectEdit(
      id,
      name,
      (Project current, String trimmed, DateTime now) =>
          current.copyWith(name: trimmed, modifiedAt: now),
      failureMessage: 'Rename could not be saved.',
    );
  }

  /// Updates the project identified by [id] from the create/edit dialog: its
  /// [name] (validated exactly like [renameProject]) and, optionally, its cover
  /// photo.
  ///
  /// - [coverImage] non-null replaces the cover with the given (already
  ///   normalized) bytes.
  /// - [clearCoverImage] removes the cover.
  /// - Neither leaves the cover unchanged.
  ///
  /// The last-modified timestamp advances, the change is persisted via
  /// [ProjectRepository.update], ordering is re-applied, and the Active_Project
  /// reference is refreshed when it is the edited project. On a repository
  /// failure the in-memory state is retained and a [transientError] surfaces.
  Future<void> updateProject(
    String id, {
    required String name,
    Uint8List? coverImage,
    bool clearCoverImage = false,
  }) {
    return _saveProjectEdit(
      id,
      name,
      (Project current, String trimmed, DateTime now) => current.copyWith(
        name: trimmed,
        modifiedAt: now,
        coverImage: coverImage,
        clearCoverImage: clearCoverImage,
      ),
      failureMessage: 'Project changes could not be saved.',
    );
  }

  /// Shared validate → build → persist → re-sort flow behind [renameProject]
  /// and [updateProject].
  Future<void> _saveProjectEdit(
    String id,
    String name,
    Project Function(Project current, String trimmedName, DateTime now) apply, {
    required String failureMessage,
  }) async {
    // Built-in guides keep the name and cover they ship with.
    if (isBuiltIn(id)) return;

    final String trimmed = name.trim();

    // Req 3.3: empty / whitespace-only name — retain name and timestamp.
    if (trimmed.isEmpty) {
      _transientError = 'A name is required.';
      notifyListeners();
      return;
    }

    // Req 3.4: over-length name — retain name and timestamp.
    if (trimmed.length > 255) {
      _transientError = 'Name exceeds the 255 character maximum.';
      notifyListeners();
      return;
    }

    final int index = _projects.indexWhere((Project p) => p.id == id);
    if (index == -1) return; // Unknown id — nothing to rename.

    final Project current = _projects[index];
    // Req 3.2: accept the trimmed name and advance the last-modified stamp.
    final Project renamed = apply(current, trimmed, DateTime.now().toUtc());

    try {
      await _repository.update(renamed);
      // Replace the in-memory entry and re-apply the shared ordering so the
      // list and the SQL `ORDER BY` agree (Req 1.4).
      final List<Project> updated = List<Project>.of(_projects)
        ..[index] = renamed
        ..sort(compareProjects);
      _projects = updated;
      if (_activeProject?.id == id) {
        _activeProject = renamed;
      }
      _transientError = null;
    } catch (_) {
      // Req 3.7: retain the in-memory state unchanged; surface a recoverable
      // error.
      _transientError = failureMessage;
    } finally {
      notifyListeners();
    }
  }

  /// Deletes the project identified by [id] and all of its folders and
  /// documents via [ProjectRepository.deleteCascade], then removes it from the
  /// in-memory list (Req 4.2).
  ///
  /// When the deleted project was the Active_Project, [closeProject] is invoked
  /// so the open workspace is disposed and the editor cleared (Req 4.6).
  ///
  /// On failure the project is retained unchanged and a [transientError] is
  /// surfaced (Req 4.4).
  Future<void> deleteProject(String id) async {
    // Built-in guides cannot be deleted (they can be hidden instead).
    if (isBuiltIn(id)) return;
    try {
      await _repository.deleteCascade(id);
      final bool wasActive = _activeProject?.id == id;

      // Remove from the in-memory backing store and re-apply the shared
      // ordering so the list and the SQL `ORDER BY` agree (Req 1.4).
      final List<Project> remaining = List<Project>.of(_projects)
        ..removeWhere((Project p) => p.id == id)
        ..sort(compareProjects);
      _projects = remaining;

      if (wasActive) {
        // Req 4.6: deleting the Active_Project also closes the workspace.
        closeProject();
      }
      _transientError = null;
    } catch (_) {
      // Req 4.4: retain the project unchanged; surface a recoverable error.
      _transientError = 'Deletion did not complete.';
    } finally {
      notifyListeners();
    }
  }

  /// Opens the project identified by [id] as the Active_Project and constructs
  /// its workspace notifier via the injected [WorkspaceFactory] (Req 5.1, 5.2).
  ///
  /// The project is resolved from the in-memory list, or fetched via
  /// [ProjectRepository.getById] when not present. On success the resolved
  /// project becomes the Active_Project, the workspace notifier is built and
  /// stored as [activeWorkspace], and listeners are notified. The workspace's
  /// own asynchronous contents load is triggered by the factory or by `main()`;
  /// here the workspace is only constructed.
  ///
  /// If the project cannot be resolved or the factory throws, the Active_Project
  /// and workspace are cleared (staying on the Dashboard) and a [transientError]
  /// is surfaced (Req 5.3).
  Future<void> openProject(String id) async {
    try {
      // Resolve from the in-memory list first; fall back to the repository.
      Project? target;
      final int index = _projects.indexWhere((Project p) => p.id == id);
      if (index != -1) {
        target = _projects[index];
      } else {
        target = await _repository.getById(id);
      }

      if (target == null) {
        // Req 5.3: nothing to open — stay on the Dashboard.
        _activeProject = null;
        _activeWorkspace = null;
        _transientError = 'Could not open the project.';
        notifyListeners();
        return;
      }

      // Dispose any previously open workspace before replacing it.
      _activeWorkspace?.dispose();

      // Req 5.1 / 5.2: set the Active_Project and construct its workspace.
      _activeProject = target;
      _activeWorkspace = _workspaceFactory(target);
      _transientError = null;
    } catch (_) {
      // Req 5.3: building / loading failed — clear state, stay on the Dashboard.
      _activeWorkspace?.dispose();
      _activeWorkspace = null;
      _activeProject = null;
      _transientError = 'Could not open the project.';
    } finally {
      notifyListeners();
    }
  }

  /// Returns to the Dashboard: disposes the active workspace (cancelling its
  /// debouncer and dropping the Active_Document, which cleanly clears the
  /// editor), nulls out the workspace and the Active_Project, and notifies
  /// (Req 5.4).
  void closeProject() {
    _activeWorkspace?.dispose();
    _activeWorkspace = null;
    _activeProject = null;
    notifyListeners();
  }

  /// Disposes the active workspace (if any) so no notifier / timer outlives this
  /// state, then completes the base `ChangeNotifier` disposal.
  @override
  void dispose() {
    _activeWorkspace?.dispose();
    super.dispose();
  }
}
