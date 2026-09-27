import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spwrite/data/database_provider.dart';

void main() {
  setUpAll(() {
    // Use the in-memory FFI factory so the smoke test runs on the dev machine
    // without touching disk or a real platform database.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('DatabaseProvider.openAppDatabase (v2 bootstrap)', () {
    test('creates the v2 schema on a fresh in-memory database', () async {
      final db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );

      try {
        // The three v2 tables exist.
        final tableRows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table'",
        );
        final tableNames =
            tableRows.map((row) => row['name'] as String).toSet();
        expect(tableNames, containsAll(<String>['projects', 'folders', 'documents']));

        // The supporting indexes exist.
        final indexRows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index'",
        );
        final indexNames =
            indexRows.map((row) => row['name'] as String).toSet();
        expect(
          indexNames,
          containsAll(<String>[
            'idx_projects_modified',
            'idx_folders_project_modified',
            'idx_documents_project',
            'idx_documents_container_modified',
          ]),
        );

        // The schema version is recorded as the current schemaVersion.
        final versionRows = await db.rawQuery('PRAGMA user_version');
        expect(
          versionRows.first.values.first,
          DatabaseProvider.schemaVersion,
        );

        // The v4 `position` column exists on folders and documents (drag order).
        final folderCols = await db.rawQuery('PRAGMA table_info(folders)');
        expect(
          folderCols.map((row) => row['name'] as String),
          contains('position'),
        );
        final docCols = await db.rawQuery('PRAGMA table_info(documents)');
        expect(
          docCols.map((row) => row['name'] as String),
          contains('position'),
        );

        // Each table is queryable and starts empty (no "no such table" error).
        expect(await db.query('projects'), isEmpty);
        expect(await db.query('folders'), isEmpty);
        expect(await db.query('documents'), isEmpty);
      } finally {
        await db.close();
      }
    });
  });
}
