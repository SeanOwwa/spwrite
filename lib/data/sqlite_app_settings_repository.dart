/// Data layer: SQLite-backed [AppSettingsRepository] over the `app_settings`
/// key/value table (schema v8).
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/app_settings_repository.dart';
import 'database_provider.dart';

/// Column names of the `app_settings` table.
class AppSettingsColumns {
  const AppSettingsColumns._();

  /// The setting's unique key (primary key).
  static const String key = 'key';

  /// The setting's string value.
  static const String value = 'value';
}

/// Persists app-wide string preferences in the app database. All values are
/// bound as `?` parameters; only trusted table/column constants are
/// interpolated.
class SqliteAppSettingsRepository implements AppSettingsRepository {
  SqliteAppSettingsRepository(this._db);

  final Database _db;

  static const String _table = DatabaseProvider.appSettingsTable;

  @override
  Future<String?> getString(String key) async {
    final List<Map<String, Object?>> rows = await _db.query(
      _table,
      columns: <String>[AppSettingsColumns.value],
      where: '${AppSettingsColumns.key} = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first[AppSettingsColumns.value] as String?;
  }

  @override
  Future<void> setString(String key, String value) async {
    await _db.insert(
      _table,
      <String, Object?>{
        AppSettingsColumns.key: key,
        AppSettingsColumns.value: value,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> remove(String key) async {
    await _db.delete(
      _table,
      where: '${AppSettingsColumns.key} = ?',
      whereArgs: <Object?>[key],
    );
  }
}
