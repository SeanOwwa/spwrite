/// Data layer: the SQLite-backed [SqliteIndexStateStore] over the schema v6
/// `ai_index_state` table — the concrete per-source resume marker store that
/// backs [ProjectIndexer]'s resume support (design §"Per-source index state",
/// Req 9.3, 4.2).
///
/// The indexer records, per `(project, source)`, the full-source content hash it
/// last indexed and whether that build reached `complete` or only `partial`.
/// A first-time build interrupted by app close or a project switch can then
/// resume: on the next [ProjectIndexer.reindexProject] the indexer consults
/// [isComplete] and skips any source already recorded `complete` at exactly its
/// current content hash, re-processing only sources that are unknown, partial,
/// or recorded at a stale hash (Req 9.3).
///
/// This is the concrete implementation of the [IndexStateStore] seam declared in
/// `project_indexer.dart`; the indexer defaults to [NoopIndexStateStore], and
/// the composition root swaps in this store to enable resume. It owns the
/// `ai_index_state` row shape and nothing more.
///
/// Persistence hygiene mirrors [ChunkEmbeddingRepository] and the other
/// repositories: every value is bound as a `?` parameter (no interpolation of
/// user-supplied data), only trusted table and column-name constants are
/// interpolated into SQL text, and the store operates on an already-open
/// [Database] whose lifecycle it does not own. A marker is written with
/// `ConflictAlgorithm.replace` on the `(project_id, source_id)` primary key so a
/// re-mark updates the row in place rather than duplicating it.
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database_provider.dart';
import 'chunker.dart';
import 'project_indexer.dart';

/// SQLite column names for the `ai_index_state` table. Centralized so the
/// store's row mapping and SQL agree on the exact column identifiers, mirroring
/// the `ChunkEmbeddingColumns` / `DocumentColumns` convention (Req 9.3, 4.2).
class IndexStateColumns {
  const IndexStateColumns._();

  /// The owning project; half of the composite primary key and the scope of
  /// every query (Req 9.3).
  static const String projectId = 'project_id';

  /// The document or character this marker tracks; the other half of the
  /// composite primary key.
  static const String sourceId = 'source_id';

  /// Whether the source is a document or a character ('document' |
  /// 'character'), stored as [ChunkSourceType.storageValue].
  static const String sourceType = 'source_type';

  /// Hash of the full source content last indexed, so a resume can tell whether
  /// the source changed since it was marked (Req 9.3, 4.2).
  static const String sourceHash = 'source_hash';

  /// How many chunks were stored at [sourceHash] (recorded for observability).
  static const String chunkCount = 'chunk_count';

  /// Last-marked time, integer milliseconds since the Unix epoch (UTC).
  static const String indexedAt = 'indexed_at';

  /// The resume marker: 'complete' | 'partial', stored as
  /// [IndexSourceStatus.storageValue].
  static const String status = 'status';
}

/// A SQLite-backed [IndexStateStore] over the project-scoped `ai_index_state`
/// table (schema v6), enabling [ProjectIndexer] resume (Req 9.3).
///
/// Like the other repositories, it does not own the database lifecycle: it
/// operates on an open [Database] supplied by
/// [DatabaseProvider.openAppDatabase]. Every operation is project-scoped and
/// binds its values as parameters; only trusted identifier constants are
/// interpolated into SQL text.
class SqliteIndexStateStore implements IndexStateStore {
  /// The open database this store reads from and writes to.
  final Database _db;

  /// The `ai_index_state` table name, sourced from the provider so the
  /// identifier used here matches the one the schema was created with.
  static const String _table = DatabaseProvider.aiIndexStateTable;

  /// Creates a store over the given open [database].
  const SqliteIndexStateStore(Database database) : _db = database;

  /// Records that [sourceId] in [projectId] has reached [status] at [sourceHash]
  /// with [chunkCount] chunks stored, replacing any existing marker for that
  /// `(project, source)` pair (Req 9.3, 4.2).
  ///
  /// Uses `ConflictAlgorithm.replace` on the composite primary key so re-marking
  /// a source (partial then complete) updates the row in place. `indexed_at` is
  /// set to now. All values are bound as parameters.
  @override
  Future<void> markSource(
    String projectId,
    String sourceId,
    ChunkSourceType sourceType, {
    required String sourceHash,
    required int chunkCount,
    required IndexSourceStatus status,
  }) async {
    final int now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.insert(
      _table,
      <String, Object?>{
        IndexStateColumns.projectId: projectId,
        IndexStateColumns.sourceId: sourceId,
        IndexStateColumns.sourceType: sourceType.storageValue,
        IndexStateColumns.sourceHash: sourceHash,
        IndexStateColumns.chunkCount: chunkCount,
        IndexStateColumns.indexedAt: now,
        IndexStateColumns.status: status.storageValue,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Removes any resume marker for [sourceId] in [projectId] (e.g. when the
  /// source was deleted), so a stale marker never masks a re-add (Req 4.4).
  ///
  /// Scoped to the project so a shared source id across projects can never clear
  /// another project's marker. Both identifiers are bound as parameters.
  @override
  Future<void> clearSource(String projectId, String sourceId) async {
    await _db.delete(
      _table,
      where: '${IndexStateColumns.projectId} = ? '
          'AND ${IndexStateColumns.sourceId} = ?',
      whereArgs: <Object?>[projectId, sourceId],
    );
  }

  /// Returns whether [sourceId] in [projectId] is already recorded as
  /// [IndexSourceStatus.complete] at exactly [sourceHash], meaning a resuming
  /// build may skip re-processing it (Req 9.3).
  ///
  /// Returns `false` when there is no marker, when the marker is
  /// [IndexSourceStatus.partial], or when it is recorded at a different hash
  /// (the source changed since it was marked). All values are bound as
  /// parameters; the row is matched on the composite primary key so at most one
  /// row is read.
  @override
  Future<bool> isComplete(
    String projectId,
    String sourceId,
    String sourceHash,
  ) async {
    final List<Map<String, Object?>> rows = await _db.query(
      _table,
      columns: <String>[IndexStateColumns.status],
      where: '${IndexStateColumns.projectId} = ? '
          'AND ${IndexStateColumns.sourceId} = ? '
          'AND ${IndexStateColumns.sourceHash} = ?',
      whereArgs: <Object?>[projectId, sourceId, sourceHash],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final String? status = rows.first[IndexStateColumns.status] as String?;
    return status == IndexSourceStatus.complete.storageValue;
  }
}
