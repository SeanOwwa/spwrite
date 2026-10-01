import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/data/sqlite_app_settings_repository.dart';
import 'package:spwrite/data/sqlite_project_repository.dart';

/// Migration test for the schema v8 upgrade: the app-wide `app_settings`
/// key/value table is added to an existing v7 store without touching existing
/// projects or documents.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spwrite_migration_v8_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Seeds a v7-shaped store (no app_settings table) with one project and one
  /// document. The app's open path creates the remaining tables idempotently.
  Future<void> seedV7Database(String path) async {
    final Database db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 7),
    );
    try {
      await db.execute('''
        CREATE TABLE projects (
          id          TEXT    PRIMARY KEY NOT NULL,
          name        TEXT    NOT NULL DEFAULT '',
          created_at  INTEGER NOT NULL,
          modified_at INTEGER NOT NULL,
          cover_image BLOB
        )
      ''');
      await db.execute('''
        CREATE TABLE folders (
          id          TEXT    PRIMARY KEY NOT NULL,
          name        TEXT    NOT NULL DEFAULT '',
          project_id  TEXT    NOT NULL,
          created_at  INTEGER NOT NULL,
          modified_at INTEGER NOT NULL,
          position    INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('''
        CREATE TABLE documents (
          id          TEXT    PRIMARY KEY NOT NULL,
          title       TEXT    NOT NULL DEFAULT '',
          content     TEXT    NOT NULL DEFAULT '',
          project_id  TEXT    NOT NULL,
          folder_id   TEXT,
          created_at  INTEGER NOT NULL,
          modified_at INTEGER NOT NULL,
          position    INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('PRAGMA user_version = 7');
      await db.insert('projects', <String, Object?>{
        'id': 'proj-1',
        'name': 'Legacy Project',
        'created_at': 100,
        'modified_at': 200,
      });
      await db.insert('documents', <String, Object?>{
        'id': 'doc-1',
        'title': 'Opening Scene',
        'content': 'It was a dark and stormy night.',
        'project_id': 'proj-1',
        'folder_id': null,
        'created_at': 120,
        'modified_at': 220,
        'position': 0,
      });
    } finally {
      await db.close();
    }
  }

  Future<bool> hasSettingsTable(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[DatabaseProvider.appSettingsTable],
    );
    return rows.isNotEmpty;
  }

  test('upgrading v7 -> v8 adds app_settings and preserves data', () async {
    final String path = '${tempDir.path}/spwrite_v7.db';
    await seedV7Database(path);

    final Database db =
        await DatabaseProvider.openAppDatabase(overridePath: path);
    try {
      final versionRows = await db.rawQuery('PRAGMA user_version');
      expect(versionRows.first.values.first, 8);
      expect(DatabaseProvider.schemaVersion, 8);
      expect(await hasSettingsTable(db), isTrue);

      final projects = await SqliteProjectRepository(db).getAll();
      expect(projects.single.id, 'proj-1');
      expect(projects.single.name, 'Legacy Project');
      final documents = await db.query('documents');
      expect(documents.single['content'], 'It was a dark and stormy night.');

      final SqliteAppSettingsRepository settings =
          SqliteAppSettingsRepository(db);
      expect(await settings.getString('k'), isNull);
      await settings.setString('k', 'v1');
      await settings.setString('k', 'v2');
      expect(await settings.getString('k'), 'v2');
      await settings.remove('k');
      expect(await settings.getString('k'), isNull);
    } finally {
      await db.close();
    }
  });

  test('settings survive reopening; fresh databases have the table', () async {
    final String path = '${tempDir.path}/fresh.db';
    final Database first =
        await DatabaseProvider.openAppDatabase(overridePath: path);
    expect(await hasSettingsTable(first), isTrue);
    await SqliteAppSettingsRepository(first)
        .setString('export.last_folder', '/tmp/out');
    await first.close();

    final Database db =
        await DatabaseProvider.openAppDatabase(overridePath: path);
    try {
      expect(
        await SqliteAppSettingsRepository(db).getString('export.last_folder'),
        '/tmp/out',
      );
    } finally {
      await db.close();
    }
  });
}
