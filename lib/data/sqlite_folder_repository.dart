/// Data layer: the SQLite-backed [FolderRepository] implementation.
///
/// [SqliteFolderRepository] fulfils the domain [FolderRepository] contract over
/// an already-open [Database]. Every statement binds its values as `?`
/// parameters (no interpolation of user-supplied values), avoiding SQL
/// injection and quoting errors from user-entered folder names (Req 9.2). Only
/// table and column identifiers — which come from trusted constants, never user
/// input — are interpolated into the SQL text.
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/document.dart';
import '../domain/folder.dart';
import '../domain/folder_repository.dart';
import 'database_provider.dart';

/// A [FolderRepository] backed by a local SQLite [Database].
///
/// The repository does not own the database lifecycle: it operates on an open
/// [Database] supplied by [DatabaseProvider.openAppDatabase] and passed into the
/// constructor. This keeps platform factory selection and schema bootstrap in
/// one place (the provider) while the repository stays platform-agnostic.
class SqliteFolderRepository implements FolderRepository {
  /// The open database this repository reads from and writes to.
  final Database _db;

  /// The `folders` table name, sourced from the provider so the table
  /// identifier used here matches the one the schema was created with.
  static const String _foldersTable = DatabaseProvider.foldersTable;

  /// The `documents` table name, used by [deleteCascade] to remove the folder's
  /// documents within the same transaction.
  static const String _documentsTable = DatabaseProvider.documentsTable;

  /// Creates a repository over the given open [database].
  const SqliteFolderRepository(Database database) : _db = database;

  /// Returns the folders of [projectId] ordered by last-modified timestamp
  /// descending, then by name ascending (case-insensitive) as a tie-breaker
  /// (Req 6.2). The `ORDER BY` clause mirrors the shared [compareFolders] rule
  /// so the query and any in-memory re-sort agree. The project identifier is
  /// bound as a parameter. Returns an empty list when the project has no
  /// folders.
  @override
  Future<List<Folder>> getByProject(String projectId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      _foldersTable,
      where: '${FolderColumns.projectId} = ?',
      whereArgs: <Object?>[projectId],
      orderBy: '${FolderColumns.modifiedAt} DESC, ${FolderColumns.name} ASC',
    );
    return rows.map(Folder.fromRow).toList(growable: false);
  }

  /// Returns the folder whose id equals [id], or `null` when no such folder
  /// exists. The identifier is bound as a parameter.
  @override
  Future<Folder?> getById(String id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      _foldersTable,
      where: '${FolderColumns.id} = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Folder.fromRow(rows.first);
  }

  /// Inserts [folder] as a new row (Req 7.2) and returns the persisted entity.
  /// The row values are bound as parameters via [Folder.toRow].
  @override
  Future<Folder> create(Folder folder) async {
    await _db.insert(
      _foldersTable,
      folder.toRow(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
    return folder;
  }

  /// Persists name / last-modified changes for the existing folder identified
  /// by `folder.id` (Req 8.2). All values, including the id in the `WHERE`
  /// clause, are bound as parameters.
  @override
  Future<void> update(Folder folder) async {
    await _db.update(
      _foldersTable,
      folder.toRow(),
      where: '${FolderColumns.id} = ?',
      whereArgs: <Object?>[folder.id],
    );
  }

  /// Removes the folder identified by [id] **and all documents it contains**,
  /// transactionally (Req 9.2).
  ///
  /// The cascade is performed explicitly here — first delete the folder's
  /// documents (by `folder_id`), then delete the folder row (by `id`) — inside a
  /// single [Database.transaction] so the operation is all-or-nothing and
  /// behaves identically on web and native regardless of the `foreign_keys`
  /// PRAGMA. Every value is bound as a parameter.
  @override
  Future<void> deleteCascade(String id) async {
    await _db.transaction((Transaction txn) async {
      await txn.delete(
        _documentsTable,
        where: '${DocumentColumns.folderId} = ?',
        whereArgs: <Object?>[id],
      );
      await txn.delete(
        _foldersTable,
        where: '${FolderColumns.id} = ?',
        whereArgs: <Object?>[id],
      );
    });
  }
}
