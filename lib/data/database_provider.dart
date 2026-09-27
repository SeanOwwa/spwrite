/// Data layer: persistence bootstrap.
///
/// [DatabaseProvider] owns the platform split in the app. It selects and
/// configures the platform-appropriate `DatabaseFactory`, resolves the
/// database location, and opens the database while creating the v2 relational
/// schema on first run. The rest of the application is platform-agnostic and
/// talks only to the open [Database].
///
/// Platforms:
/// - Mobile (iOS, Android): the default `sqflite` plugin factory.
/// - Desktop (macOS, Windows, Linux): the FFI factory ([databaseFactoryFfi]).
/// - Web (Chrome and other browsers): the IndexedDB-backed WASM factory
///   ([databaseFactoryFfiWebNoWebWorker]); the database is stored in the
///   browser rather than as an on-disk file.
///
/// v2 is a fresh start with respect to stored data: the store lives in a new
/// file ([databaseFileName] == `writing_app_v2.db`) and the schema is the
/// three-table Project → Folder → Document relational model. No v1 data is
/// migrated.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import '../domain/document.dart';
import '../domain/folder.dart';
import '../domain/project.dart';
import 'db_path_io.dart' if (dart.library.html) 'db_path_web.dart' as pathres;

/// Selects the platform SQLite factory, resolves the database path, and opens
/// the app database (creating the file and v2 schema on first run, Req 17.7).
class DatabaseProvider {
  const DatabaseProvider._();

  /// The file name of the app's SQLite database. A fresh v2 store — a new file
  /// distinct from any v1 database, so v2 never migrates or touches v1 data.
  static const String databaseFileName = 'writing_app_v2.db';

  /// The `projects` table name.
  static const String projectsTable = 'projects';

  /// The `folders` table name.
  static const String foldersTable = 'folders';

  /// The `documents` table name.
  static const String documentsTable = 'documents';

  /// The index backing the Dashboard project ordering (Req 1.2).
  static const String projectsModifiedIndexName = 'idx_projects_modified';

  /// The index backing per-project folder listing and ordering (Req 6.2).
  static const String foldersProjectModifiedIndexName =
      'idx_folders_project_modified';

  /// The index scoping documents to a project (Req 6.3).
  static const String documentsProjectIndexName = 'idx_documents_project';

  /// The index backing per-container document ordering (Req 6.3).
  static const String documentsContainerModifiedIndexName =
      'idx_documents_container_modified';

  /// The current schema version, carried in `PRAGMA user_version`. Bumped to 2
  /// for the v2 relational schema; there is no migration from v1.
  static const int schemaVersion = 2;

  /// Selects and configures the platform-appropriate `DatabaseFactory`.
  ///
  /// - Web: sets the global [databaseFactory] to the IndexedDB-backed
  ///   [databaseFactoryFfiWebNoWebWorker] (main-thread WASM, no shared worker).
  /// - Desktop (macOS, Windows, Linux): initializes the FFI implementation via
  ///   [sqfliteFfiInit] and sets [databaseFactory] to [databaseFactoryFfi].
  /// - Mobile (iOS, Android): the default `sqflite` plugin factory is used, so
  ///   no override is required.
  ///
  /// Must be called once during startup, before [openAppDatabase].
  static void initPlatformFactory() {
    if (kIsWeb) {
      // Run SQLite on the main thread via the WASM binary rather than a shared
      // web worker. The shared-worker factory (databaseFactoryFfiWeb) can fail
      // to initialize its worker in some browser/dev-server setups, surfacing
      // as an "unsupported result null" during openDatabase; the no-web-worker
      // factory avoids that by not spawning a worker at all.
      databaseFactory = databaseFactoryFfiWebNoWebWorker;
      return;
    }
    if (pathres.isDesktop) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    // Mobile (iOS, Android): the default sqflite factory needs no override.
  }

  /// Resolves the database location.
  ///
  /// On web this is a plain name the browser storage keys on; on native
  /// platforms it is an on-disk path (see the conditional `db_path_*`
  /// implementations).
  static Future<String> resolveDbPath() async {
    if (kIsWeb) return databaseFileName;
    return pathres.resolveDbPath(databaseFileName);
  }

  /// Opens (creating if absent) the app database and ensures the v2 schema
  /// exists.
  ///
  /// Implements Req 17.7: the database and schema are created before any
  /// persistence or load operation. The schema is created in the [onCreate]
  /// callback (guarded with `IF NOT EXISTS`), and the schema version is
  /// recorded in `PRAGMA user_version`.
  ///
  /// Pass [overridePath] to open at a specific location; tests may pass
  /// [inMemoryDatabasePath] to use an in-memory factory. When omitted, the
  /// path is resolved via [resolveDbPath].
  static Future<Database> openAppDatabase({String? overridePath}) async {
    final String path = overridePath ?? await resolveDbPath();
    return openDatabase(
      path,
      version: schemaVersion,
      onCreate: (Database db, int version) async {
        await _createSchema(db);
      },
      onConfigure: (Database db) async {
        // The web (WASM) factory rejects this PRAGMA during open. On native
        // factories it is a harmless safeguard; the app additionally enforces
        // cascade deletes in the repository layer within a transaction, so
        // cascade behavior is identical on web (where this is skipped) and
        // native.
        if (!kIsWeb) {
          await db.execute('PRAGMA foreign_keys = ON');
        }
      },
    );
  }

  /// Creates the v2 relational schema — the `projects`, `folders`, and
  /// `documents` tables and their supporting indexes — if they do not already
  /// exist, and sets the schema version via `PRAGMA user_version`.
  ///
  /// The `ON DELETE CASCADE` foreign keys are declared for correctness where
  /// the `foreign_keys` PRAGMA is enabled (native), but the app does not rely
  /// on them: cascade deletes are also performed explicitly in the repository
  /// layer within a transaction, so behavior matches on web where the PRAGMA is
  /// skipped.
  ///
  /// Only trusted table/column-name constants are interpolated into the SQL.
  static Future<void> _createSchema(Database db) async {
    // projects (Req 17.1).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $projectsTable (
        ${ProjectColumns.id}          TEXT    PRIMARY KEY NOT NULL,
        ${ProjectColumns.name}        TEXT    NOT NULL DEFAULT '',
        ${ProjectColumns.createdAt}   INTEGER NOT NULL,
        ${ProjectColumns.modifiedAt}  INTEGER NOT NULL
      )
    ''');

    // folders — each belongs to exactly one project (Req 17.2).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $foldersTable (
        ${FolderColumns.id}          TEXT    PRIMARY KEY NOT NULL,
        ${FolderColumns.name}        TEXT    NOT NULL DEFAULT '',
        ${FolderColumns.projectId}   TEXT    NOT NULL,
        ${FolderColumns.createdAt}   INTEGER NOT NULL,
        ${FolderColumns.modifiedAt}  INTEGER NOT NULL,
        FOREIGN KEY (${FolderColumns.projectId})
          REFERENCES $projectsTable (${ProjectColumns.id}) ON DELETE CASCADE
      )
    ''');

    // documents — a document belongs to one project and at most one folder
    // (folder_id NULL == Root-Level Document) (Req 17.3).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $documentsTable (
        ${DocumentColumns.id}          TEXT    PRIMARY KEY NOT NULL,
        ${DocumentColumns.title}       TEXT    NOT NULL DEFAULT '',
        ${DocumentColumns.content}     TEXT    NOT NULL DEFAULT '',
        ${DocumentColumns.projectId}   TEXT    NOT NULL,
        ${DocumentColumns.folderId}    TEXT,
        ${DocumentColumns.createdAt}   INTEGER NOT NULL,
        ${DocumentColumns.modifiedAt}  INTEGER NOT NULL,
        FOREIGN KEY (${DocumentColumns.projectId})
          REFERENCES $projectsTable (${ProjectColumns.id}) ON DELETE CASCADE,
        FOREIGN KEY (${DocumentColumns.folderId})
          REFERENCES $foldersTable (${FolderColumns.id}) ON DELETE CASCADE
      )
    ''');

    // Dashboard ordering: last-modified desc, then name asc (Req 1.2).
    await db.execute('''
      CREATE INDEX IF NOT EXISTS $projectsModifiedIndexName
        ON $projectsTable (
          ${ProjectColumns.modifiedAt} DESC,
          ${ProjectColumns.name} ASC
        )
    ''');

    // Folder listing per project, ordered (Req 6.2).
    await db.execute('''
      CREATE INDEX IF NOT EXISTS $foldersProjectModifiedIndexName
        ON $foldersTable (
          ${FolderColumns.projectId},
          ${FolderColumns.modifiedAt} DESC,
          ${FolderColumns.name} ASC
        )
    ''');

    // Document scoping to a project (Req 6.3).
    await db.execute('''
      CREATE INDEX IF NOT EXISTS $documentsProjectIndexName
        ON $documentsTable (${DocumentColumns.projectId})
    ''');

    // Per-container document ordering: last-modified desc, then title asc
    // (Req 6.3).
    await db.execute('''
      CREATE INDEX IF NOT EXISTS $documentsContainerModifiedIndexName
        ON $documentsTable (
          ${DocumentColumns.projectId},
          ${DocumentColumns.folderId},
          ${DocumentColumns.modifiedAt} DESC,
          ${DocumentColumns.title} ASC
        )
    ''');

    await db.execute('PRAGMA user_version = $schemaVersion');
  }
}
