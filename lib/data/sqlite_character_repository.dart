/// Data layer: the SQLite-backed [CharacterRepository] implementation.
///
/// [SqliteCharacterRepository] fulfils the domain [CharacterRepository]
/// contract over an already-open [Database]. Every statement binds its values
/// — including the portrait image BLOB — as `?` parameters (no interpolation of
/// user-supplied values), avoiding SQL injection and quoting errors. Only table
/// and column identifiers, which come from trusted constants, are interpolated
/// into the SQL text.
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/character.dart';
import '../domain/character_repository.dart';
import 'database_provider.dart';

/// A [CharacterRepository] backed by a local SQLite [Database].
///
/// Like the other repositories, this one does not own the database lifecycle:
/// it operates on an open [Database] supplied by
/// [DatabaseProvider.openAppDatabase] and passed into the constructor.
class SqliteCharacterRepository implements CharacterRepository {
  /// The open database this repository reads from and writes to.
  final Database _db;

  /// The `characters` table name, sourced from the provider so the identifier
  /// used here matches the one the schema was created with.
  static const String _charactersTable = DatabaseProvider.charactersTable;

  /// Creates a repository over the given open [database].
  const SqliteCharacterRepository(Database database) : _db = database;

  /// Returns every character in [projectId] ordered by name ascending
  /// (case-insensitive via `COLLATE NOCASE`), mirroring the shared
  /// [compareCharacters] rule's primary key. Returns an empty list when the
  /// project has no characters. The project id is bound as a parameter.
  @override
  Future<List<Character>> getAllForProject(String projectId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      _charactersTable,
      where: '${CharacterColumns.projectId} = ?',
      whereArgs: <Object?>[projectId],
      orderBy: '${CharacterColumns.name} COLLATE NOCASE ASC, '
          '${CharacterColumns.modifiedAt} DESC',
    );
    return rows.map(Character.fromRow).toList(growable: false);
  }

  /// Returns the character whose id equals [id], or `null` when no such
  /// character exists. The identifier is bound as a parameter.
  @override
  Future<Character?> getById(String id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      _charactersTable,
      where: '${CharacterColumns.id} = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Character.fromRow(rows.first);
  }

  /// Inserts [character] as a new row and returns the persisted entity. The row
  /// values (id, fields, image BLOB, timestamps) are bound as parameters via
  /// [Character.toRow].
  @override
  Future<Character> create(Character character) async {
    await _db.insert(
      _charactersTable,
      character.toRow(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
    return character;
  }

  /// Persists field / image / last-modified changes for the existing character
  /// identified by `character.id`. All values, including the id in the `WHERE`
  /// clause, are bound as parameters.
  @override
  Future<void> update(Character character) async {
    await _db.update(
      _charactersTable,
      character.toRow(),
      where: '${CharacterColumns.id} = ?',
      whereArgs: <Object?>[character.id],
    );
  }

  /// Removes the character identified by [id]. The identifier is bound as a
  /// parameter.
  @override
  Future<void> delete(String id) async {
    await _db.delete(
      _charactersTable,
      where: '${CharacterColumns.id} = ?',
      whereArgs: <Object?>[id],
    );
  }
}
