/// Domain layer: the [ProjectRepository] abstraction over persistence.
///
/// The state layer (`AppNavigationState`) depends only on this interface, never
/// on SQLite directly, keeping it decoupled from the persistence
/// implementation. The data layer's `SqliteProjectRepository` implements each
/// method against the open database.
library;

import 'project.dart';

/// Abstracts persistence of [Project]s so the state layer never touches the
/// SQLite database directly.
///
/// Implementations must use **parameterized SQL only** — values are bound as
/// `?` placeholders and never interpolated into the SQL string; only trusted
/// table/column name constants may be interpolated. Failures are surfaced by
/// throwing, so the state layer can retain in-memory truth and present
/// recoverable error messages.
abstract class ProjectRepository {
  /// Returns all projects ordered by last-modified timestamp descending, then
  /// by name ascending (case-insensitive) as a tie-breaker (Req 1.2).
  ///
  /// Returns an empty list when no projects exist.
  Future<List<Project>> getAll();

  /// Returns the single project with the given [id], or `null` when no project
  /// with that identifier is present.
  Future<Project?> getById(String id);

  /// Inserts a new [project] into the store and returns the persisted entity
  /// (Req 2.2).
  Future<Project> create(Project project);

  /// Persists name / cover-photo / last-modified changes for an existing
  /// project (Req 3.2).
  Future<void> update(Project project);

  /// Removes the project identified by [id] **and all of its folders and
  /// documents**, transactionally (Req 4.2).
  ///
  /// The cascade is performed explicitly in the implementation (delete
  /// documents, then folders, then the project, all within one transaction),
  /// not left to the database, so behavior is identical on web and native.
  /// Throws on failure.
  Future<void> deleteCascade(String id);
}
