/// Domain layer: the [FolderRepository] abstraction over persistence.
///
/// The state layer (`ProjectWorkspaceState`) depends only on this interface,
/// never on SQLite directly, keeping it decoupled from the persistence
/// implementation. The data layer's `SqliteFolderRepository` implements each
/// method against the open database.
library;

import 'folder.dart';

/// Abstracts persistence of [Folder]s so the state layer never touches the
/// SQLite database directly.
///
/// Implementations must use **parameterized SQL only** — values are bound as
/// `?` placeholders and never interpolated into the SQL string; only trusted
/// table/column name constants may be interpolated. Failures are surfaced by
/// throwing, so the state layer can retain in-memory truth and present
/// recoverable error messages.
abstract class FolderRepository {
  /// Returns the folders of [projectId] ordered by last-modified timestamp
  /// descending, then by name ascending (case-insensitive) as a tie-breaker
  /// (Req 6.2).
  ///
  /// Returns an empty list when the project has no folders.
  Future<List<Folder>> getByProject(String projectId);

  /// Returns the single folder with the given [id], or `null` when no folder
  /// with that identifier is present.
  Future<Folder?> getById(String id);

  /// Inserts a new [folder] into the store and returns the persisted entity
  /// (Req 7.2).
  Future<Folder> create(Folder folder);

  /// Persists name / last-modified changes for an existing folder (Req 8.2).
  Future<void> update(Folder folder);

  /// Persists the `position` of each of [folders] transactionally, for
  /// drag-and-drop reordering of the folder list. All-or-nothing.
  Future<void> updatePositions(List<Folder> folders);

  /// Removes the folder identified by [id] **and all documents it contains**,
  /// transactionally (Req 9.2).
  ///
  /// The cascade is performed explicitly in the implementation (delete the
  /// folder's documents, then the folder, within one transaction), not left to
  /// the database, so behavior is identical on web and native. Throws on
  /// failure.
  Future<void> deleteCascade(String id);
}
