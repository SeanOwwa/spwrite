import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spwrite/data/database_provider.dart';

/// Migration test for the schema v6 upgrade (Task 4.2, Property 11).
///
/// Property 11 — Migration preserves prior data: opening a seeded pre-v6 store
/// at schema v6 creates the new `ai_chunk_embeddings` + `ai_index_state`
/// tables and leaves every existing project, folder, document, character, and
/// conversation row intact and readable. (Validates: Requirements 10.5)
///
/// The migration path relies on `onUpgrade` running against a real on-disk
/// database whose recorded `PRAGMA user_version` is below 6, so this test
/// seeds a v5-shaped database in a temp file, closes it, and reopens it via
/// [DatabaseProvider.openAppDatabase] (matching the app's real open path).
void main() {
  setUpAll(() {
    // Use the FFI factory so the test runs on the dev machine against a real
    // on-disk SQLite file (needed to persist across close/reopen and exercise
    // onUpgrade), mirroring the desktop runtime factory.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spwrite_migration_v6_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Creates the v2->v5 schema (everything that existed before v6) on [db] and
  /// records `user_version = 5`, so reopening at v6 triggers the v5 -> v6
  /// `onUpgrade` branch. This mirrors the pre-v6 schema exactly: projects,
  /// folders, documents (with the v4 `position` column), characters (v3), and
  /// ai_conversations (v5) — but NOT the v6 semantic-retrieval tables.
  Future<void> createV5Schema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS projects (
        id          TEXT    PRIMARY KEY NOT NULL,
        name        TEXT    NOT NULL DEFAULT '',
        created_at  INTEGER NOT NULL,
        modified_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS folders (
        id          TEXT    PRIMARY KEY NOT NULL,
        name        TEXT    NOT NULL DEFAULT '',
        project_id  TEXT    NOT NULL,
        created_at  INTEGER NOT NULL,
        modified_at INTEGER NOT NULL,
        position    INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS documents (
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
    await db.execute('''
      CREATE TABLE IF NOT EXISTS characters (
        id          TEXT    PRIMARY KEY NOT NULL,
        project_id  TEXT    NOT NULL,
        name        TEXT    NOT NULL DEFAULT '',
        role        TEXT    NOT NULL DEFAULT '',
        summary     TEXT    NOT NULL DEFAULT '',
        notes       TEXT    NOT NULL DEFAULT '',
        image       BLOB,
        created_at  INTEGER NOT NULL,
        modified_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ai_conversations (
        id          TEXT    PRIMARY KEY NOT NULL,
        project_id  TEXT    NOT NULL,
        role        TEXT    NOT NULL DEFAULT '',
        text        TEXT    NOT NULL DEFAULT '',
        timestamp   INTEGER NOT NULL,
        sources     TEXT    NOT NULL DEFAULT '[]'
      )
    ''');
    await db.execute('PRAGMA user_version = 5');
  }

  /// Opens a plain v5 database at [path], seeds one row into each pre-existing
  /// table, and closes it. Returns nothing — the seeded file is left on disk
  /// for the reopen-at-v6 step.
  Future<void> seedV5Database(String path) async {
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 5),
    );
    try {
      await createV5Schema(db);

      await db.insert('projects', <String, Object?>{
        'id': 'proj-1',
        'name': 'Legacy Project',
        'created_at': 100,
        'modified_at': 200,
      });
      await db.insert('folders', <String, Object?>{
        'id': 'folder-1',
        'name': 'Chapter 1',
        'project_id': 'proj-1',
        'created_at': 110,
        'modified_at': 210,
        'position': 0,
      });
      await db.insert('documents', <String, Object?>{
        'id': 'doc-1',
        'title': 'Opening Scene',
        'content': 'It was a dark and stormy night.',
        'project_id': 'proj-1',
        'folder_id': 'folder-1',
        'created_at': 120,
        'modified_at': 220,
        'position': 0,
      });
      await db.insert('characters', <String, Object?>{
        'id': 'char-1',
        'project_id': 'proj-1',
        'name': 'Ada',
        'role': 'Protagonist',
        'summary': '',
        'notes': 'Curious and brave.',
        'created_at': 130,
        'modified_at': 230,
      });
      await db.insert('ai_conversations', <String, Object?>{
        'id': 'msg-1',
        'project_id': 'proj-1',
        'role': 'user',
        'text': 'Who is Ada?',
        'timestamp': 240,
        'sources': '[]',
      });
    } finally {
      await db.close();
    }
  }

  Future<Set<String>> tableNames(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    return rows.map((row) => row['name'] as String).toSet();
  }

  Future<Set<String>> columnNames(Database db, String table) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.map((row) => row['name'] as String).toSet();
  }

  group('DatabaseProvider schema v6 migration', () {
    test(
        'upgrading a seeded v5 store to v6 adds the new tables and preserves '
        'existing data', () async {
      final path = '${tempDir.path}/spwrite_v5.db';
      await seedV5Database(path);

      // Reopen via the real app open path — this runs onUpgrade (v5 -> v6).
      final db = await DatabaseProvider.openAppDatabase(overridePath: path);
      try {
        // The schema version is bumped to the current v6.
        final versionRows = await db.rawQuery('PRAGMA user_version');
        expect(versionRows.first.values.first, DatabaseProvider.schemaVersion);
        // The store is at the current version (v6 or later, e.g. v7).
        expect(DatabaseProvider.schemaVersion, greaterThanOrEqualTo(6));

        // The two new v6 tables now exist alongside the pre-existing ones.
        final names = await tableNames(db);
        expect(
          names,
          containsAll(<String>[
            'projects',
            'folders',
            'documents',
            'characters',
            'ai_conversations',
            DatabaseProvider.aiChunkEmbeddingsTable,
            DatabaseProvider.aiIndexStateTable,
          ]),
        );

        // ai_chunk_embeddings has the expected columns.
        expect(
          await columnNames(db, DatabaseProvider.aiChunkEmbeddingsTable),
          containsAll(<String>[
            'id',
            'project_id',
            'source_id',
            'source_type',
            'source_title',
            'chunk_index',
            'content_hash',
            'text',
            'model_id',
            'dim',
            'embedding',
            'created_at',
            'updated_at',
          ]),
        );

        // ai_index_state has the expected columns.
        expect(
          await columnNames(db, DatabaseProvider.aiIndexStateTable),
          containsAll(<String>[
            'project_id',
            'source_id',
            'source_type',
            'source_hash',
            'chunk_count',
            'indexed_at',
            'status',
          ]),
        );

        // Pre-existing data survives the migration unchanged.
        final projects = await db.query('projects');
        expect(projects, hasLength(1));
        expect(projects.first['id'], 'proj-1');
        expect(projects.first['name'], 'Legacy Project');

        final folders = await db.query('folders');
        expect(folders, hasLength(1));
        expect(folders.first['id'], 'folder-1');
        expect(folders.first['name'], 'Chapter 1');

        final documents = await db.query('documents');
        expect(documents, hasLength(1));
        expect(documents.first['id'], 'doc-1');
        expect(documents.first['title'], 'Opening Scene');
        expect(documents.first['content'], 'It was a dark and stormy night.');

        final characters = await db.query('characters');
        expect(characters, hasLength(1));
        expect(characters.first['id'], 'char-1');
        expect(characters.first['name'], 'Ada');
        expect(characters.first['notes'], 'Curious and brave.');

        final conversations = await db.query('ai_conversations');
        expect(conversations, hasLength(1));
        expect(conversations.first['id'], 'msg-1');
        expect(conversations.first['text'], 'Who is Ada?');

        // The new v6 tables are queryable and start empty.
        expect(
          await db.query(DatabaseProvider.aiChunkEmbeddingsTable),
          isEmpty,
        );
        expect(await db.query(DatabaseProvider.aiIndexStateTable), isEmpty);
      } finally {
        await db.close();
      }
    });

    test('reopening an already-migrated v6 store is idempotent (repeated '
        'onOpen leaves data intact)', () async {
      final path = '${tempDir.path}/spwrite_idempotent.db';
      await seedV5Database(path);

      // First open migrates v5 -> v6.
      final first = await DatabaseProvider.openAppDatabase(overridePath: path);
      await first.close();

      // Second open runs onOpen's idempotent IF NOT EXISTS safety nets again.
      final db = await DatabaseProvider.openAppDatabase(overridePath: path);
      try {
        final names = await tableNames(db);
        expect(
          names,
          containsAll(<String>[
            DatabaseProvider.aiChunkEmbeddingsTable,
            DatabaseProvider.aiIndexStateTable,
          ]),
        );
        // Data still present and unduplicated after a second open.
        expect(await db.query('projects'), hasLength(1));
        expect(await db.query('documents'), hasLength(1));
        expect(await db.query('characters'), hasLength(1));
        expect(await db.query('ai_conversations'), hasLength(1));
      } finally {
        await db.close();
      }
    });

    test('a fresh v6 create has the new tables with the expected columns',
        () async {
      final path = '${tempDir.path}/spwrite_fresh.db';
      final db = await DatabaseProvider.openAppDatabase(overridePath: path);
      try {
        final versionRows = await db.rawQuery('PRAGMA user_version');
        expect(versionRows.first.values.first, DatabaseProvider.schemaVersion);

        final names = await tableNames(db);
        expect(
          names,
          containsAll(<String>[
            DatabaseProvider.aiChunkEmbeddingsTable,
            DatabaseProvider.aiIndexStateTable,
          ]),
        );

        expect(
          await columnNames(db, DatabaseProvider.aiChunkEmbeddingsTable),
          containsAll(<String>[
            'id',
            'project_id',
            'source_id',
            'source_type',
            'source_title',
            'chunk_index',
            'content_hash',
            'text',
            'model_id',
            'dim',
            'embedding',
            'created_at',
            'updated_at',
          ]),
        );
        expect(
          await columnNames(db, DatabaseProvider.aiIndexStateTable),
          containsAll(<String>[
            'project_id',
            'source_id',
            'source_type',
            'source_hash',
            'chunk_count',
            'indexed_at',
            'status',
          ]),
        );

        // Both new tables are queryable and start empty on a fresh create.
        expect(
          await db.query(DatabaseProvider.aiChunkEmbeddingsTable),
          isEmpty,
        );
        expect(await db.query(DatabaseProvider.aiIndexStateTable), isEmpty);
      } finally {
        await db.close();
      }
    });
  });
}
