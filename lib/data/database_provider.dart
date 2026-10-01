/// Data layer: persistence bootstrap.
///
/// [DatabaseProvider] owns the platform split in the app. It selects and
/// configures the platform-appropriate `DatabaseFactory`, resolves the
/// database location, and opens the database while creating the v2 relational
/// schema on first run. The rest of the application is platform-agnostic and
/// talks only to the open [Database].
///
/// Platforms (Spwrite targets desktop and web only):
/// - Desktop (macOS, Windows, Linux): the FFI factory ([databaseFactoryFfi]).
/// - Web (Chrome and other browsers): the IndexedDB-backed WASM factory
///   ([databaseFactoryFfiWebNoWebWorker]); the database is stored in the
///   browser rather than as an on-disk file.
///
/// v2 is a fresh start with respect to stored data: the store lives in a new
/// file ([databaseFileName] == `spwrite_v2.db`) and the schema is the
/// three-table Project → Folder → Document relational model. No v1 data is
/// migrated.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import '../domain/character.dart';
import '../domain/document.dart';
import '../domain/folder.dart';
import '../domain/project.dart';
import 'db_path_io.dart' if (dart.library.html) 'db_path_web.dart' as pathres;
import 'sqlite_ai_conversation_repository.dart' show AiConversationColumns;
import 'sqlite_app_settings_repository.dart' show AppSettingsColumns;

/// Selects the platform SQLite factory, resolves the database path, and opens
/// the app database (creating the file and v2 schema on first run, Req 17.7).
class DatabaseProvider {
  const DatabaseProvider._();

  /// The file name of the app's SQLite database. A fresh v2 store — a new file
  /// distinct from any v1 database, so v2 never migrates or touches v1 data.
  static const String databaseFileName = 'spwrite_v2.db';

  /// The `projects` table name.
  static const String projectsTable = 'projects';

  /// The `folders` table name.
  static const String foldersTable = 'folders';

  /// The `documents` table name.
  static const String documentsTable = 'documents';

  /// The `characters` table name (project-scoped fictional characters).
  static const String charactersTable = 'characters';

  /// The `ai_conversations` table name (project-scoped AI Panel conversation,
  /// Req 9.3).
  static const String aiConversationsTable = 'ai_conversations';

  /// The `ai_chunk_embeddings` table name (project-scoped semantic vector
  /// index; one row per chunk embedding, schema v6, Req 4.1, 4.7, 8.4).
  static const String aiChunkEmbeddingsTable = 'ai_chunk_embeddings';

  /// The `ai_index_state` table name (per-source incremental-reindex/resume
  /// markers, schema v6, Req 9.3, 4.2).
  static const String aiIndexStateTable = 'ai_index_state';

  /// The `app_settings` table name (app-wide key/value preferences such as the
  /// last export folder, schema v8).
  static const String appSettingsTable = 'app_settings';

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

  /// The index backing per-project character listing and name ordering.
  static const String charactersProjectNameIndexName =
      'idx_characters_project_name';

  /// The index backing per-project AI-conversation retrieval, ordered by
  /// timestamp (Req 9.3).
  static const String aiConversationsProjectTimestampIndexName =
      'idx_ai_conversations_project_timestamp';

  /// The index scoping chunk embeddings to a project (the per-query paged
  /// cosine scan, Req 1.5, 2.5, 8.4).
  static const String aiChunkEmbeddingsProjectIndexName =
      'idx_ai_chunk_embeddings_project';

  /// The index backing per-source chunk retrieval and ordered incremental
  /// diffing (Req 4.2, 4.7).
  static const String aiChunkEmbeddingsSourceIndexName =
      'idx_ai_chunk_embeddings_source';

  /// The current schema version, carried in `PRAGMA user_version`.
  ///
  /// - v2: the three-table Project → Folder → Document relational model.
  /// - v3: adds the project-scoped `characters` table (Character Panel).
  /// - v4: adds a `position` column to `folders` and `documents` so the user's
  ///   manual drag-and-drop ordering in the sidebar is persisted.
  /// - v5: adds the project-scoped `ai_conversations` table so the AI Panel
  ///   conversation can persist across app launches (Req 9.3).
  /// - v6: adds the project-scoped `ai_chunk_embeddings` (semantic vector
  ///   index) and `ai_index_state` (incremental-reindex/resume markers) tables
  ///   backing on-device semantic retrieval (Req 4.1, 4.7, 9.3, 10.5).
  /// - v7: adds a nullable `cover_image` BLOB column to `projects` holding the
  ///   project's normalized 1600 × 2560 JPEG cover photo.
  /// - v8: adds the app-wide `app_settings` key/value table (e.g. the last
  ///   folder a .docx export was saved to).
  ///
  /// Bumping this triggers [openAppDatabase]'s `onUpgrade` so an existing store
  /// gains the new column / table without losing its projects / documents.
  static const int schemaVersion = 8;

  /// Selects and configures the platform-appropriate `DatabaseFactory`.
  ///
  /// - Web: sets the global [databaseFactory] to the IndexedDB-backed
  ///   [databaseFactoryFfiWebNoWebWorker] (main-thread WASM, no shared worker).
  /// - Desktop (macOS, Windows, Linux): initializes the FFI implementation via
  ///   [sqfliteFfiInit] and sets [databaseFactory] to [databaseFactoryFfi].
  ///
  /// Any other platform (e.g. mobile) is unsupported and throws
  /// [UnsupportedError].
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
    if (!pathres.isDesktop) {
      throw UnsupportedError(
        'Spwrite supports macOS, Windows, Linux and web only.',
      );
    }
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        // v2 -> v3: add the project-scoped characters table. Guarded with
        // IF NOT EXISTS so re-running is harmless. Existing projects, folders,
        // and documents are untouched.
        if (oldVersion < 3) {
          await _createCharactersTable(db);
        }
        // v3 -> v4: add the `position` column to folders and documents so the
        // user's manual sidebar ordering persists.
        if (oldVersion < 4) {
          await _addPositionColumns(db);
        }
        // v4 -> v5: add the project-scoped ai_conversations table. Guarded with
        // IF NOT EXISTS so re-running is harmless.
        if (oldVersion < 5) {
          await _createAiConversationsTable(db);
        }
        // v5 -> v6: add the project-scoped semantic-retrieval tables
        // (ai_chunk_embeddings + ai_index_state). Both are created with
        // IF NOT EXISTS so re-running is harmless; existing projects,
        // documents, characters, and conversations are untouched.
        if (oldVersion < 6) {
          await _createAiChunkEmbeddingsTable(db);
          await _createAiIndexStateTable(db);
        }
        // v6 -> v7: add the nullable projects.cover_image BLOB. Existing rows
        // get NULL (no cover); no other data is touched. Idempotent.
        if (oldVersion < 7) {
          await _addProjectCoverColumn(db);
        }
        // v7 -> v8: add the app-wide app_settings key/value table. Guarded
        // with IF NOT EXISTS so re-running is harmless; no existing data is
        // touched.
        if (oldVersion < 8) {
          await _createAppSettingsTable(db);
        }
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
      onOpen: (Database db) async {
        // Safety net for the v3 characters table: `onUpgrade` handles the
        // v2 -> v3 migration on native, but the web (WASM/IndexedDB) factory
        // does not always run version-upgrade callbacks reliably. Because the
        // table creation is idempotent (`IF NOT EXISTS`), ensuring it here on
        // every open guarantees the Character Panel has its table on both fresh
        // and pre-existing databases, on every platform.
        await _createCharactersTable(db);
        // Same safety net for the v4 `position` columns: the web factory does
        // not reliably run onUpgrade, and SQLite has no "ADD COLUMN IF NOT
        // EXISTS", so [_addPositionColumns] swallows the duplicate-column error
        // and is safe to call on every open.
        await _addPositionColumns(db);
        // Safety net for the v5 ai_conversations table, mirroring the
        // characters table: idempotent (`IF NOT EXISTS`), so ensuring it here
        // on every open guarantees the AI Panel has its table on both fresh and
        // pre-existing databases, on every platform (the web factory does not
        // reliably run onUpgrade).
        await _createAiConversationsTable(db);
        // Same safety net for the v6 semantic-retrieval tables
        // (ai_chunk_embeddings + ai_index_state): idempotent (`IF NOT EXISTS`),
        // so ensuring them here on every open guarantees the vector index and
        // resume markers exist on both fresh and pre-existing databases, on
        // every platform (the web factory does not reliably run onUpgrade).
        await _createAiChunkEmbeddingsTable(db);
        await _createAiIndexStateTable(db);
        // Same safety net for the v7 projects.cover_image column: the web
        // factory does not reliably run onUpgrade, and
        // [_addProjectCoverColumn] swallows the duplicate-column error, so it is
        // safe to call on every open.
        await _addProjectCoverColumn(db);
        // Same safety net for the v8 app_settings table: idempotent
        // (`IF NOT EXISTS`), so ensuring it on every open guarantees it exists
        // on every platform (the web factory does not reliably run onUpgrade).
        await _createAppSettingsTable(db);
      },
    );
  }

  /// Creates the app-wide `app_settings` key/value table if it does not
  /// already exist (schema v8). Invoked by [_createSchema] (fresh database),
  /// the v7 -> v8 `onUpgrade` migration, and `onOpen` (idempotent safety net).
  /// Only trusted table/column-name constants are interpolated into the SQL.
  static Future<void> _createAppSettingsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $appSettingsTable (
        ${AppSettingsColumns.key}    TEXT PRIMARY KEY NOT NULL,
        ${AppSettingsColumns.value}  TEXT NOT NULL
      )
    ''');
  }

  /// Adds the nullable `cover_image` BLOB column to the `projects` table if it
  /// is not already present (the v6 -> v7 migration). Like
  /// [_addPositionColumns], the ALTER is wrapped in a try/catch that swallows
  /// the "duplicate column name" error, making this idempotent and safe to run
  /// from both `onUpgrade` and `onOpen`.
  static Future<void> _addProjectCoverColumn(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE $projectsTable ADD COLUMN ${ProjectColumns.coverImage} BLOB',
      );
    } catch (_) {
      // Column already exists — nothing to do.
    }
  }

  /// Adds the `position` column to the `folders` and `documents` tables if it
  /// is not already present (the v3 -> v4 migration). SQLite lacks
  /// `ADD COLUMN IF NOT EXISTS`, so each ALTER is wrapped in a try/catch that
  /// swallows the "duplicate column name" error, making this idempotent and
  /// safe to run from both `onUpgrade` and `onOpen` (the latter covers the web
  /// factory, which does not reliably invoke `onUpgrade`).
  static Future<void> _addPositionColumns(Database db) async {
    for (final String table in <String>[foldersTable, documentsTable]) {
      try {
        await db.execute(
          'ALTER TABLE $table ADD COLUMN '
          '${FolderColumns.position} INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {
        // Column already exists — nothing to do.
      }
    }
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
        ${ProjectColumns.modifiedAt}  INTEGER NOT NULL,
        ${ProjectColumns.coverImage}  BLOB
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
        ${FolderColumns.position}    INTEGER NOT NULL DEFAULT 0,
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
        ${DocumentColumns.position}    INTEGER NOT NULL DEFAULT 0,
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

    // characters — project-scoped fictional characters (schema v3).
    await _createCharactersTable(db);

    // ai_conversations — project-scoped AI Panel conversation (schema v5).
    await _createAiConversationsTable(db);

    // ai_chunk_embeddings + ai_index_state — semantic vector index and
    // incremental-reindex/resume markers (schema v6).
    await _createAiChunkEmbeddingsTable(db);
    await _createAiIndexStateTable(db);

    // app_settings — app-wide key/value preferences (schema v8).
    await _createAppSettingsTable(db);

    await db.execute('PRAGMA user_version = $schemaVersion');
  }

  /// Creates the `characters` table and its supporting index if they do not
  /// already exist. Split out so it can be invoked both by [_createSchema] (on
  /// a fresh database) and by the v2 -> v3 `onUpgrade` migration (on an
  /// existing store). Only trusted table/column-name constants are interpolated
  /// into the SQL.
  static Future<void> _createCharactersTable(Database db) async {
    // A character belongs to exactly one project; deleting the project removes
    // its characters (cascade declared for native; the app does not rely on it
    // for correctness — the project delete cascade is enforced explicitly in
    // the repository layer, which is extended to include characters).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $charactersTable (
        ${CharacterColumns.id}          TEXT    PRIMARY KEY NOT NULL,
        ${CharacterColumns.projectId}   TEXT    NOT NULL,
        ${CharacterColumns.name}        TEXT    NOT NULL DEFAULT '',
        ${CharacterColumns.role}        TEXT    NOT NULL DEFAULT '',
        -- Legacy column, retained so existing databases keep a stable schema.
        -- No longer written or read by the app (the character "summary" field
        -- was removed); kept NOT NULL DEFAULT '' so inserts that omit it work.
        summary                         TEXT    NOT NULL DEFAULT '',
        ${CharacterColumns.notes}       TEXT    NOT NULL DEFAULT '',
        ${CharacterColumns.image}       BLOB,
        ${CharacterColumns.createdAt}   INTEGER NOT NULL,
        ${CharacterColumns.modifiedAt}  INTEGER NOT NULL,
        FOREIGN KEY (${CharacterColumns.projectId})
          REFERENCES $projectsTable (${ProjectColumns.id}) ON DELETE CASCADE
      )
    ''');

    // Character listing per project, ordered by name.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS $charactersProjectNameIndexName
        ON $charactersTable (
          ${CharacterColumns.projectId},
          ${CharacterColumns.name} ASC
        )
    ''');
  }

  /// Creates the `ai_conversations` table and its supporting index if they do
  /// not already exist (schema v5, Req 9.3). Split out so it can be invoked by
  /// [_createSchema] (fresh database), the v4 -> v5 `onUpgrade` migration
  /// (existing store), and `onOpen` (idempotent safety net for the web
  /// factory). Only trusted table/column-name constants are interpolated into
  /// the SQL.
  static Future<void> _createAiConversationsTable(Database db) async {
    // Each message belongs to exactly one project; deleting the project removes
    // its conversation (cascade declared for native, matching the other
    // project-scoped tables). The grounding sources are stored as a JSON TEXT
    // column; the timestamp is integer milliseconds since the Unix epoch (UTC).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $aiConversationsTable (
        ${AiConversationColumns.id}          TEXT    PRIMARY KEY NOT NULL,
        ${AiConversationColumns.projectId}   TEXT    NOT NULL,
        ${AiConversationColumns.role}        TEXT    NOT NULL DEFAULT '',
        ${AiConversationColumns.text}        TEXT    NOT NULL DEFAULT '',
        ${AiConversationColumns.timestamp}   INTEGER NOT NULL,
        ${AiConversationColumns.sources}     TEXT    NOT NULL DEFAULT '[]',
        FOREIGN KEY (${AiConversationColumns.projectId})
          REFERENCES $projectsTable (${ProjectColumns.id}) ON DELETE CASCADE
      )
    ''');

    // Conversation retrieval per project, ordered chronologically.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS $aiConversationsProjectTimestampIndexName
        ON $aiConversationsTable (
          ${AiConversationColumns.projectId},
          ${AiConversationColumns.timestamp} ASC
        )
    ''');
  }

  /// Creates the `ai_chunk_embeddings` table and its supporting indexes if they
  /// do not already exist (schema v6, Req 4.1, 4.7, 8.4, 10.5). Split out so it
  /// can be invoked by [_createSchema] (fresh database), the v5 -> v6
  /// `onUpgrade` migration (existing store), and `onOpen` (idempotent safety
  /// net for the web factory, which does not reliably run `onUpgrade`).
  ///
  /// One row per chunk embedding, scoped to a project. The vector is stored as
  /// a little-endian Float32 BLOB (`dim * 4` bytes); `model_id`/`dim` tag the
  /// producing model so a model change can be detected and the project
  /// reindexed. `content_hash` drives the per-chunk incremental diff so
  /// unchanged chunks are never re-embedded (Req 4.2). Deleting the owning
  /// project cascades (declared for native; enforced explicitly in the
  /// repository layer as with the other project-scoped tables).
  ///
  /// Only trusted table/column-name constants are interpolated into the SQL;
  /// the column identifiers are literal trusted constants (the
  /// `ChunkEmbeddingRepository` in task 4.3 centralizes them, mirroring the
  /// `AiConversationColumns` convention).
  static Future<void> _createAiChunkEmbeddingsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $aiChunkEmbeddingsTable (
        id            TEXT    PRIMARY KEY NOT NULL,
        project_id    TEXT    NOT NULL,
        source_id     TEXT    NOT NULL,
        source_type   TEXT    NOT NULL,
        source_title  TEXT    NOT NULL DEFAULT '',
        chunk_index   INTEGER NOT NULL,
        content_hash  TEXT    NOT NULL,
        text          TEXT    NOT NULL DEFAULT '',
        model_id      TEXT    NOT NULL,
        dim           INTEGER NOT NULL,
        embedding     BLOB    NOT NULL,
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL,
        FOREIGN KEY (project_id)
          REFERENCES $projectsTable (${ProjectColumns.id}) ON DELETE CASCADE
      )
    ''');

    // Per-query paged cosine scan scopes to a project (Req 1.5, 2.5, 8.4).
    await db.execute('''
      CREATE INDEX IF NOT EXISTS $aiChunkEmbeddingsProjectIndexName
        ON $aiChunkEmbeddingsTable (project_id)
    ''');

    // Per-source chunk retrieval, ordered for the incremental diff (Req 4.2).
    await db.execute('''
      CREATE INDEX IF NOT EXISTS $aiChunkEmbeddingsSourceIndexName
        ON $aiChunkEmbeddingsTable (project_id, source_id, chunk_index)
    ''');
  }

  /// Creates the `ai_index_state` table if it does not already exist (schema
  /// v6, Req 9.3, 4.2). Split out so it can be invoked by [_createSchema]
  /// (fresh database), the v5 -> v6 `onUpgrade` migration (existing store), and
  /// `onOpen` (idempotent safety net for the web factory).
  ///
  /// One row per (project, source) records the full-source content hash last
  /// indexed, the chunk count, and a `status` of 'complete' | 'partial', so a
  /// first-time build interrupted by app close or project switch resumes from
  /// where it stopped rather than restarting. Deleting the owning project
  /// cascades. Only trusted table/column-name constants are interpolated.
  static Future<void> _createAiIndexStateTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $aiIndexStateTable (
        project_id    TEXT    NOT NULL,
        source_id     TEXT    NOT NULL,
        source_type   TEXT    NOT NULL,
        source_hash   TEXT    NOT NULL,
        chunk_count   INTEGER NOT NULL,
        indexed_at    INTEGER NOT NULL,
        status        TEXT    NOT NULL,
        PRIMARY KEY (project_id, source_id),
        FOREIGN KEY (project_id)
          REFERENCES $projectsTable (${ProjectColumns.id}) ON DELETE CASCADE
      )
    ''');
  }
}
