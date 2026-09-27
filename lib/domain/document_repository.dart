/// Domain layer: the [DocumentRepository] abstraction over persistence.
///
/// The state layer (`ProjectWorkspaceState`) depends only on this interface,
/// never on SQLite directly, keeping it decoupled from the persistence
/// implementation. The data layer's `SqliteDocumentRepository` implements each
/// method against the open database.
library;

import 'document.dart';

/// Abstracts persistence of [Document]s so the state layer never touches the
/// SQLite database directly.
///
/// Implementations must use **parameterized SQL only** — values are bound as
/// `?` placeholders and never interpolated into the SQL string; only trusted
/// table/column name constants may be interpolated. Failures are surfaced by
/// throwing, so the state layer can retain in-memory truth and present
/// recoverable error messages.
abstract class DocumentRepository {
  /// Returns all documents of [projectId] across every container (both
  /// root-level documents and documents in any of the project's folders).
  ///
  /// Used to build the Project_Sidebar tree and to compute successor selection
  /// scoped to the Active_Project. Returns an empty list when the project has
  /// no documents.
  Future<List<Document>> getByProject(String projectId);

  /// Returns the documents in a specific container of [projectId], ordered by
  /// last-modified timestamp descending, then by title ascending
  /// (case-insensitive) as a tie-breaker (Req 6.3).
  ///
  /// A null [folderId] selects the project's root-level documents; a non-null
  /// [folderId] selects the documents contained in that folder. Returns an
  /// empty list when the container holds no documents.
  Future<List<Document>> getByContainer(String projectId, String? folderId);

  /// Returns the single document with the given [id], or `null` when no
  /// document with that identifier is present.
  Future<Document?> getById(String id);

  /// Inserts a new [doc] into the store and returns the persisted entity
  /// (Req 10.1, 10.2).
  Future<Document> create(Document doc);

  /// Persists title / content / folder / last-modified changes for an existing
  /// document (Req 16.1).
  Future<void> update(Document doc);

  /// Persists the `position` (and any changed containing folder) of each of
  /// [documents] transactionally, for drag-and-drop reordering and moving a
  /// document between containers. All-or-nothing: either every row is updated
  /// or none is.
  Future<void> updatePositions(List<Document> documents);

  /// Removes the document identified by [id] from the store (Req 13.2). Throws
  /// on failure.
  Future<void> delete(String id);
}
