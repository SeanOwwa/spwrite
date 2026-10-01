import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/data/sqlite_project_repository.dart';
import 'package:spwrite/domain/project.dart';

/// Migration test for the schema v7 upgrade: `projects.cover_image` (a
/// nullable BLOB) is added to an existing v6 store without touching any
/// existing row, and covers then round-trip through the repository.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spwrite_migration_v7_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Seeds a v6-shaped store: the v6 `projects` table has no cover column.
  /// Only the tables relevant to the assertion are created; the app's open
  /// path creates the rest idempotently.
  Future<void> seedV6Database(String path) async {
    final Database db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 6),
    );
    try {
      await db.execute('''
        CREATE TABLE projects (
          id          TEXT    PRIMARY KEY NOT NULL,
          name        TEXT    NOT NULL DEFAULT '',
          created_at  INTEGER NOT NULL,
          modified_at INTEGER NOT NULL
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
      await db.execute('PRAGMA user_version = 6');
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

  Future<Set<String>> projectColumns(Database db) async {
    final rows = await db.rawQuery('PRAGMA table_info(projects)');
    return rows.map((row) => row['name'] as String).toSet();
  }

  test('upgrading v6 -> v7 adds projects.cover_image and preserves data',
      () async {
    final String path = '${tempDir.path}/spwrite_v6.db';
    await seedV6Database(path);

    final Database db = await DatabaseProvider.openAppDatabase(
      overridePath: path,
    );
    try {
      final versionRows = await db.rawQuery('PRAGMA user_version');
      expect(versionRows.first.values.first, DatabaseProvider.schemaVersion);
      expect(DatabaseProvider.schemaVersion, greaterThanOrEqualTo(7));
      expect(await projectColumns(db), contains(ProjectColumns.coverImage));

      // The existing project survives unchanged, with no cover.
      final SqliteProjectRepository repo = SqliteProjectRepository(db);
      final List<Project> projects = await repo.getAll();
      expect(projects, hasLength(1));
      expect(projects.single.id, 'proj-1');
      expect(projects.single.name, 'Legacy Project');
      expect(projects.single.createdAt.millisecondsSinceEpoch, 100);
      expect(projects.single.modifiedAt.millisecondsSinceEpoch, 200);
      expect(projects.single.coverImage, isNull);

      final documents = await db.query('documents');
      expect(documents, hasLength(1));
      expect(documents.single['content'], 'It was a dark and stormy night.');

      // A cover can now be saved on the migrated row and read back.
      final Uint8List cover = Uint8List.fromList(<int>[0xFF, 0xD8, 1, 2, 3]);
      await repo.update(projects.single.copyWith(coverImage: cover));
      final Project? reread = await repo.getById('proj-1');
      expect(reread!.coverImage, cover);
      expect(reread.name, 'Legacy Project');
    } finally {
      await db.close();
    }
  });

  test('reopening a migrated v7 store is idempotent', () async {
    final String path = '${tempDir.path}/spwrite_idempotent.db';
    await seedV6Database(path);
    final Database first =
        await DatabaseProvider.openAppDatabase(overridePath: path);
    await first.close();

    final Database db =
        await DatabaseProvider.openAppDatabase(overridePath: path);
    try {
      expect(await projectColumns(db), contains(ProjectColumns.coverImage));
      expect(await db.query('projects'), hasLength(1));
    } finally {
      await db.close();
    }
  });

  test('a fresh v7 database has the cover column and round-trips covers',
      () async {
    final Database db = await DatabaseProvider.openAppDatabase(
      overridePath: '${tempDir.path}/fresh.db',
    );
    try {
      expect(await projectColumns(db), contains(ProjectColumns.coverImage));
      final SqliteProjectRepository repo = SqliteProjectRepository(db);
      final Uint8List cover = Uint8List.fromList(List<int>.generate(
        2048,
        (int i) => i % 256,
      ));
      final Project project = Project.create(
        id: 'p1',
        name: 'With cover',
        now: DateTime.utc(2026, 1, 2),
        coverImage: cover,
      );
      await repo.create(project);
      expect(await repo.getById('p1'), project);

      // Clearing the cover persists NULL.
      await repo.update(project.copyWith(clearCoverImage: true));
      expect((await repo.getById('p1'))!.coverImage, isNull);
    } finally {
      await db.close();
    }
  });
}
