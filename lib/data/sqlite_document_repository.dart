/// Data layer: the SQLite-backed [DocumentRepository] implementation.
///
/// [SqliteDocumentRepository] fulfils the domain [DocumentRepository] contract
/// over an already-open [Database]. Every statement binds its values as `?`
/// parameters (no interpolation of user-supplied values), avoiding SQL
/// injection and quoting errors from user-entered titles and content. Only
/// table and column identifiers — which come from trusted constants, never
/// user input — are interpolated into the SQL text.
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/document.dart';
import '../domain/document_repository.dart';
import 'database_provider.dart';

/// A [DocumentRepository] backed by a local SQLite [Database].
///
/// The repository does not own the database lifecycle: it operates on an open
/// [Database] supplied by [DatabaseProvider.openAppDatabase] and passed into the
/// constructor. This keeps platform factory selection and schema bootstrap in
/// one place (the provider) while the repository stays platform-agnostic.
class SqliteDocumentRepository implements DocumentRepository {
  /// The open database this repository reads from and writes to.
  final Database _db;

  /// The `documents` table name, sourced from the provider so the table
  /// identifier used here matches the one the schema was created with.
  static const String _table = DatabaseProvider.documentsTable;

  /// The canonical per-container ordering clause: manual position ascending,
  /// then last-modified timestamp descending and title ascending as
  /// tie-breakers. Mirrors the shared [compareDocuments] rule so the query and
  /// any in-memory re-sort agree.
  static const String _orderBy =
      '${DocumentColumns.position} ASC, '
      '${DocumentColumns.modifiedAt} DESC, ${DocumentColumns.title} ASC';

  /// Creates a repository over the given open [database].
  const SqliteDocumentRepository(Database database) : _db = database;

  /// Returns every document belonging to [projectId] across all containers
  /// (root-level documents and documents in any of the project's folders). The
  /// project identifier is bound as a parameter. Rows are ordered by the shared
  /// per-container rule for determinism; callers that need per-container
  /// ordering use [getByContainer]. Returns an empty list when the project has
  /// no documents.
  @override
  Future<List<Document>> getByProject(String projectId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      _table,
      where: '${DocumentColumns.projectId} = ?',
      whereArgs: <Object?>[projectId],
      orderBy: _orderBy,
    );
    return rows.map(Document.fromRow).toList(growable: false);
  }

  /// Returns the documents in a specific container of [projectId], ordered by
  /// last-modified timestamp descending, then title ascending as a tie-breaker
  /// (Req 6.3).
  ///
  /// A null [folderId] selects the project's root-level documents, matched with
  /// `folder_id IS NULL` (a null value cannot be compared with `= ?`); a
  /// non-null [folderId] selects the documents contained in that folder,
  /// matched with `folder_id = ?`. All values are bound as parameters. Returns
  /// an empty list when the container holds no documents.
  @override
  Future<List<Document>> getByContainer(
    String projectId,
    String? folderId,
  ) async {
    final List<Map<String, Object?>> rows;
    if (folderId == null) {
      rows = await _db.query(
        _table,
        where:
            '${DocumentColumns.projectId} = ? AND ${DocumentColumns.folderId} IS NULL',
        whereArgs: <Object?>[projectId],
        orderBy: _orderBy,
      );
    } else {
      rows = await _db.query(
        _table,
        where:
            '${DocumentColumns.projectId} = ? AND ${DocumentColumns.folderId} = ?',
        whereArgs: <Object?>[projectId, folderId],
        orderBy: _orderBy,
      );
    }
    return rows.map(Document.fromRow).toList(growable: false);
  }

  /// Returns the document whose id equals [id], or `null` when no such document
  /// exists. The identifier is bound as a parameter.
  @override
  Future<Document?> getById(String id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      _table,
      where: '${DocumentColumns.id} = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Document.fromRow(rows.first);
  }

  /// Inserts [doc] as a new row (Req 10.1, 10.2) and returns the persisted
  /// entity. The row values are bound as parameters via [Document.toRow]. The
  /// abort conflict algorithm surfaces a duplicate-id insert as a thrown error
  /// rather than silently overwriting.
  @override
  Future<Document> create(Document doc) async {
    await _db.insert(
      _table,
      doc.toRow(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
    return doc;
  }

  /// Persists title / content / folder / last-modified changes for the existing
  /// document identified by `doc.id` (Req 16.1). All values, including the id in
  /// the `WHERE` clause, are bound as parameters.
  @override
  Future<void> update(Document doc) async {
    await _db.update(
      _table,
      doc.toRow(),
      where: '${DocumentColumns.id} = ?',
      whereArgs: <Object?>[doc.id],
    );
  }

  /// Removes the document identified by [id] (Req 13.2). The identifier is bound
  /// as a parameter.
  @override
  Future<void> delete(String id) async {
    await _db.delete(
      _table,
      where: '${DocumentColumns.id} = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Persists the `position` (and possibly changed `folder_id`) of each of
  /// [documents] in a single transaction, so a drag-and-drop reorder or a
  /// move between containers is applied all-or-nothing. Each document's full
  /// row is written via [Document.toRow]; only the id is used in the `WHERE`.
  @override
  Future<void> updatePositions(List<Document> documents) async {
    await _db.transaction((Transaction txn) async {
      for (final Document doc in documents) {
        await txn.update(
          _table,
          doc.toRow(),
          where: '${DocumentColumns.id} = ?',
          whereArgs: <Object?>[doc.id],
        );
      }
    });
  }
}
