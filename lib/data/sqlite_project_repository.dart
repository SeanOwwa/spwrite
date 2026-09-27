/// Data layer: the SQLite-backed [ProjectRepository] implementation.
///
/// [SqliteProjectRepository] fulfils the domain [ProjectRepository] contract
/// over an already-open [Database]. Every statement binds its values as `?`
/// parameters (no interpolation of user-supplied values), avoiding SQL
/// injection and quoting errors from user-entered project names. Only table
/// and column identifiers — which come from trusted constants, never user
/// input — are interpolated into the SQL text.
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/character.dart';
import '../domain/document.dart';
import '../domain/folder.dart';
import '../domain/project.dart';
import '../domain/project_repository.dart';
import 'database_provider.dart';

/// A [ProjectRepository] backed by a local SQLite [Database].
///
/// The repository does not own the database lifecycle: it operates on an open
/// [Database] supplied by [DatabaseProvider.openAppDatabase] and passed into
/// the constructor. This keeps platform factory selection and schema bootstrap
/// in one place (the provider) while the repository stays platform-agnostic.
class SqliteProjectRepository implements ProjectRepository {
  /// The open database this repository reads from and writes to.
  final Database _db;

  /// The `projects` table name, sourced from the provider so the table
  /// identifier used here matches the one the schema was created with.
  static const String _projectsTable = DatabaseProvider.projectsTable;

  /// The `folders` table name, used by the cascade delete.
  static const String _foldersTable = DatabaseProvider.foldersTable;

  /// The `documents` table name, used by the cascade delete.
  static const String _documentsTable = DatabaseProvider.documentsTable;

  /// The `characters` table name, used by the cascade delete.
  static const String _charactersTable = DatabaseProvider.charactersTable;

  /// Creates a repository over the given open [database].
  const SqliteProjectRepository(Database database) : _db = database;

  /// Returns every project ordered by last-modified timestamp descending, then
  /// by name ascending as a tie-breaker (Req 1.2). The `ORDER BY` clause
  /// mirrors the shared [compareProjects] rule so the query and any in-memory
  /// re-sort agree. Returns an empty list when the store holds no projects.
  @override
  Future<List<Project>> getAll() async {
    final List<Map<String, Object?>> rows = await _db.query(
      _projectsTable,
      orderBy:
          '${ProjectColumns.modifiedAt} DESC, ${ProjectColumns.name} ASC',
    );
    return rows.map(Project.fromRow).toList(growable: false);
  }

  /// Returns the project whose id equals [id], or `null` when no such project
  /// exists. The identifier is bound as a parameter.
  @override
  Future<Project?> getById(String id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      _projectsTable,
      where: '${ProjectColumns.id} = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Project.fromRow(rows.first);
  }

  /// Inserts [project] as a new row (Req 2.2) and returns the persisted entity.
  /// The row values (id, name, timestamps) are bound as parameters via
  /// [Project.toRow].
  @override
  Future<Project> create(Project project) async {
    await _db.insert(
      _projectsTable,
      project.toRow(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
    return project;
  }

  /// Persists name / last-modified changes for the existing project identified
  /// by `project.id` (Req 3.2). All values, including the id in the `WHERE`
  /// clause, are bound as parameters.
  @override
  Future<void> update(Project project) async {
    await _db.update(
      _projectsTable,
      project.toRow(),
      where: '${ProjectColumns.id} = ?',
      whereArgs: <Object?>[project.id],
    );
  }

  /// Removes the project identified by [id] together with all of its folders
  /// and documents, transactionally (Req 4.2).
  ///
  /// The cascade is performed explicitly here — deleting documents, then
  /// folders, then the project row, all within a single [Database.transaction]
  /// so it is all-or-nothing. Doing it in the repository (rather than relying
  /// on the `ON DELETE CASCADE` foreign keys) makes cascade behavior identical
  /// on web, where the `foreign_keys` PRAGMA is skipped, and on native. All
  /// values are bound as parameters.
  @override
  Future<void> deleteCascade(String id) async {
    await _db.transaction((Transaction txn) async {
      await txn.delete(
        _documentsTable,
        where: '${DocumentColumns.projectId} = ?',
        whereArgs: <Object?>[id],
      );
      await txn.delete(
        _foldersTable,
        where: '${FolderColumns.projectId} = ?',
        whereArgs: <Object?>[id],
      );
      // Characters are project-scoped too; remove them in the same transaction
      // so a deleted project leaves no orphaned characters (behavior identical
      // on web, where the FK cascade PRAGMA is skipped).
      await txn.delete(
        _charactersTable,
        where: '${CharacterColumns.projectId} = ?',
        whereArgs: <Object?>[id],
      );
      await txn.delete(
        _projectsTable,
        where: '${ProjectColumns.id} = ?',
        whereArgs: <Object?>[id],
      );
    });
  }
}
