/// Data layer: the SQLite-backed [ChunkEmbeddingRepository] over the schema v6
/// `ai_chunk_embeddings` table — the project-scoped on-device vector index that
/// the semantic retriever scans and the indexer writes (design §"Data Models —
/// ai_chunk_embeddings", Req 4.1, 4.7, 8.4, 10.5).
///
/// The repository is the single owner of the `ai_chunk_embeddings` row shape. It
/// exposes exactly the operations the retriever and indexer need and nothing
/// more:
///
/// - **upsert (batch)** — write the embeddings for a source's chunks in one
///   transaction, replacing any existing rows with the same stable chunk id so
///   an incremental reindex updates rows in place rather than orphaning them
///   (Req 4.2, 4.7).
/// - **delete-by-source** — remove every row for a source that vanished or was
///   deleted, scoped to the project (Req 4.4, 4.7).
/// - **delete-chunk-by-id** — remove one chunk that vanished from a source (the
///   source got shorter) without touching its surviving chunks, so the
///   incremental reindex never re-embeds unchanged passages (Req 4.2, 4.4).
/// - **countForProject** — how many chunk vectors a project has, backing
///   `SemanticContextRetriever.hasProjectMaterial` (Req 2.5).
/// - **paged scan-by-project** — stream a project's stored vectors in bounded
///   pages so a single query never deserializes the whole index at once
///   (design §"Retrieval", Req 2.5, 8.4).
/// - **read-stored-chunk-hashes-for-source** — the per-chunk `content_hash`es a
///   source currently has stored, so the indexer can diff against freshly
///   chunked text and re-embed only what changed (Req 4.2).
///
/// Persistence hygiene mirrors the other repositories: every value is bound as
/// a `?` parameter (no interpolation of user-supplied data), only trusted table
/// and column-name constants are interpolated into SQL text, and the repository
/// operates on an already-open [Database] it does not own. Vectors are encoded
/// to / decoded from the little-endian Float32 BLOB via [VectorCodec], the same
/// definition the retriever compares with, and each write carries the producing
/// model's `model_id` / `dim` so a model change can be detected downstream.
library;

import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database_provider.dart';
import 'chunker.dart';
import 'vector_codec.dart';

/// SQLite column names for the `ai_chunk_embeddings` table. Centralized so the
/// repository's row mapping and SQL agree on the exact column identifiers,
/// mirroring the `AiConversationColumns` / `DocumentColumns` convention.
class ChunkEmbeddingColumns {
  const ChunkEmbeddingColumns._();

  /// Stable chunk id, derived from `(sourceId, chunkIndex)` by the chunker.
  static const String id = 'id';

  /// The owning project, the scope of every query (Req 1.5, 4.7, 8.4).
  static const String projectId = 'project_id';

  /// The document or character this chunk came from.
  static const String sourceId = 'source_id';

  /// Whether the source is a document or a character ('document' |
  /// 'character'), stored as [ChunkSourceType.storageValue].
  static const String sourceType = 'source_type';

  /// Human-readable source label carried for citation (Req 1.4).
  static const String sourceTitle = 'source_title';

  /// Zero-based order of the chunk within its source; the deterministic
  /// retrieval tie-break key (Req 1.6).
  static const String chunkIndex = 'chunk_index';

  /// Per-chunk hash of the chunk text, driving the incremental diff (Req 4.2).
  static const String contentHash = 'content_hash';

  /// The passage text handed to the embedding model, kept so a retrieved chunk
  /// can be returned as grounding without re-reading the source.
  static const String text = 'text';

  /// The embedding model that produced the stored vector (mismatch guard).
  static const String modelId = 'model_id';

  /// The vector dimension (mismatch / corruption guard against the BLOB).
  static const String dim = 'dim';

  /// The Float32 little-endian embedding BLOB (`dim * 4` bytes).
  static const String embedding = 'embedding';

  /// Creation time, integer milliseconds since the Unix epoch (UTC).
  static const String createdAt = 'created_at';

  /// Last-update time, integer milliseconds since the Unix epoch (UTC).
  static const String updatedAt = 'updated_at';
}

/// A chunk paired with the embedding vector produced for it, the unit the
/// indexer hands to [ChunkEmbeddingRepository.upsertChunks].
///
/// The [chunk] carries all the identity/metadata the row needs ([SourceChunk.id],
/// source identity, title, index, content hash, and text); [vector] is the
/// embedding to persist. The vector is L2-normalized on write via [VectorCodec]
/// so the stored bytes are unit-length and cosine reduces to a dot product at
/// retrieval (design §"Embedding encoding").
class EmbeddedChunk {
  /// The chunk whose text was embedded.
  final SourceChunk chunk;

  /// The embedding vector for [chunk], as produced by the embedding model
  /// (normalized on write).
  final List<double> vector;

  const EmbeddedChunk({required this.chunk, required this.vector});
}

/// A stored chunk vector read back from the index during a paged cosine scan
/// (the read side of the row, design §"Retrieval").
///
/// Carries everything the retriever needs to score the chunk and, if it wins,
/// turn it into a `RetrievedPassage`: the [embedding] to compare against the
/// query vector, its declared [modelId] / [dim] (so a stale or mis-shaped row
/// can be skipped), the [sourceId] / [sourceTitle] for citation and scoping,
/// the [chunkIndex] for the deterministic tie-break, and the [text] to return.
class StoredChunkEmbedding {
  /// Stable chunk id (the row's primary key).
  final String id;

  /// The source document or character this chunk came from.
  final String sourceId;

  /// Whether the source is a document or a character.
  final ChunkSourceType sourceType;

  /// Human-readable source label for citation (Req 1.4).
  final String sourceTitle;

  /// Zero-based order within the source; the deterministic tie-break key
  /// (Req 1.6).
  final int chunkIndex;

  /// The passage text to return as grounding when this chunk is selected.
  final String text;

  /// The embedding model that produced [embedding]; compared against the
  /// current model to detect a stale index (Req 7.4).
  final String modelId;

  /// The declared vector dimension; compared against `embedding.length` to
  /// detect a corrupt or mis-shaped row (Req 7.4).
  final int dim;

  /// The decoded embedding vector (already L2-normalized as stored).
  final List<double> embedding;

  const StoredChunkEmbedding({
    required this.id,
    required this.sourceId,
    required this.sourceType,
    required this.sourceTitle,
    required this.chunkIndex,
    required this.text,
    required this.modelId,
    required this.dim,
    required this.embedding,
  });
}

/// The stored identity/hash of one currently-indexed chunk of a source, the
/// unit the incremental diff compares against freshly re-chunked text (Req 4.2).
///
/// The indexer re-chunks a saved source, then compares each new chunk's
/// [SourceChunk.contentHash] against the [contentHash]es already stored (keyed
/// by [chunkIndex] / [id]) so it re-embeds only chunks whose text changed,
/// deletes chunks that vanished, and leaves unchanged chunks untouched.
class StoredChunkHash {
  /// Stable chunk id (the row's primary key).
  final String id;

  /// Zero-based order within the source.
  final int chunkIndex;

  /// The stored per-chunk content hash to diff against the freshly chunked text.
  final String contentHash;

  const StoredChunkHash({
    required this.id,
    required this.chunkIndex,
    required this.contentHash,
  });
}

/// A SQLite-backed repository over the project-scoped `ai_chunk_embeddings`
/// vector index (schema v6).
///
/// Like the other repositories, this one does not own the database lifecycle:
/// it operates on an open [Database] supplied by
/// [DatabaseProvider.openAppDatabase]. Every operation is project-scoped and
/// binds its values as parameters; only trusted identifier constants are
/// interpolated into SQL text.
class ChunkEmbeddingRepository {
  /// The open database this repository reads from and writes to.
  final Database _db;

  /// The `ai_chunk_embeddings` table name, sourced from the provider so the
  /// identifier used here matches the one the schema was created with.
  static const String _table = DatabaseProvider.aiChunkEmbeddingsTable;

  /// Default page size for [scanProject]: how many rows are read (and their
  /// vectors decoded) per batch, so a single query never materializes the whole
  /// project index at once (Req 2.5, 8.4).
  static const int defaultScanPageSize = 256;

  /// Creates a repository over the given open [database].
  const ChunkEmbeddingRepository(Database database) : _db = database;

  /// Upserts the embeddings for [chunks] into [projectId] in a single
  /// transaction, replacing any existing row with the same stable chunk id
  /// (Req 4.2, 4.7).
  ///
  /// Each vector is L2-normalized and encoded to a little-endian Float32 BLOB
  /// via [VectorCodec], and tagged with [modelId] / [dim] so a later model
  /// change can be detected. `created_at` is preserved on replace when the row
  /// already exists (an update keeps the original creation time); `updated_at`
  /// is always set to now. All values are bound as parameters. An empty
  /// [chunks] list is a no-op.
  Future<void> upsertChunks(
    String projectId,
    List<EmbeddedChunk> chunks, {
    required String modelId,
    required int dim,
  }) async {
    if (chunks.isEmpty) return;
    final int now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.transaction((Transaction txn) async {
      for (final EmbeddedChunk embedded in chunks) {
        final SourceChunk chunk = embedded.chunk;
        // Preserve the original created_at across a replace so updated_at is the
        // only timestamp that moves when an existing chunk is re-embedded.
        final List<Map<String, Object?>> existing = await txn.query(
          _table,
          columns: <String>[ChunkEmbeddingColumns.createdAt],
          where: '${ChunkEmbeddingColumns.id} = ?',
          whereArgs: <Object?>[chunk.id],
          limit: 1,
        );
        final int createdAt = existing.isEmpty
            ? now
            : (existing.first[ChunkEmbeddingColumns.createdAt] as num?)
                    ?.toInt() ??
                now;

        await txn.insert(
          _table,
          _toRow(
            projectId: projectId,
            embedded: embedded,
            modelId: modelId,
            dim: dim,
            createdAt: createdAt,
            updatedAt: now,
          ),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// Removes every stored chunk of [sourceId] within [projectId] (Req 4.4,
  /// 4.7), returning the number of rows deleted.
  ///
  /// Scoped to the project so a shared source id across projects can never
  /// delete another project's rows. Both identifiers are bound as parameters.
  Future<int> deleteBySource(String projectId, String sourceId) async {
    return _db.delete(
      _table,
      where: '${ChunkEmbeddingColumns.projectId} = ? '
          'AND ${ChunkEmbeddingColumns.sourceId} = ?',
      whereArgs: <Object?>[projectId, sourceId],
    );
  }

  /// Removes the single stored chunk with the stable chunk [chunkId] within
  /// [projectId], returning the number of rows deleted (0 or 1).
  ///
  /// Used by the incremental reindex to drop a chunk that vanished from a source
  /// (e.g. the source got shorter) without disturbing the source's surviving
  /// chunks, so unchanged chunks are never touched (Req 4.2, 4.4). Scoped to the
  /// project so a chunk id can only ever delete its own project's row; both
  /// identifiers are bound as parameters.
  Future<int> deleteChunkById(String projectId, String chunkId) async {
    return _db.delete(
      _table,
      where: '${ChunkEmbeddingColumns.projectId} = ? '
          'AND ${ChunkEmbeddingColumns.id} = ?',
      whereArgs: <Object?>[projectId, chunkId],
    );
  }

  /// Refreshes the citation label ([ChunkEmbeddingColumns.sourceTitle]) on every
  /// stored chunk of [sourceId] within [projectId] to [sourceTitle], returning
  /// the number of rows updated (Req 4.5).
  ///
  /// This is the metadata-only half of a rename: the body chunks' text (and
  /// therefore their embedding) does not change, so they must not be
  /// re-embedded, but the human-readable label carried for citation does move.
  /// Scoped to the project so a shared source id across projects can never touch
  /// another project's rows; the new title and both identifiers are bound as
  /// parameters and `updated_at` is left untouched (the embedding did not
  /// change). An unknown source updates nothing and returns 0.
  Future<int> updateSourceTitle(
    String projectId,
    String sourceId,
    String sourceTitle,
  ) async {
    return _db.update(
      _table,
      <String, Object?>{ChunkEmbeddingColumns.sourceTitle: sourceTitle},
      where: '${ChunkEmbeddingColumns.projectId} = ? '
          'AND ${ChunkEmbeddingColumns.sourceId} = ?',
      whereArgs: <Object?>[projectId, sourceId],
    );
  }

  /// Removes every stored chunk for [projectId] (a full index wipe for that
  /// project, e.g. before a stale-model rebuild), returning the number of rows
  /// deleted. The identifier is bound as a parameter.
  Future<int> deleteAllForProject(String projectId) async {
    return _db.delete(
      _table,
      where: '${ChunkEmbeddingColumns.projectId} = ?',
      whereArgs: <Object?>[projectId],
    );
  }

  /// Returns how many chunk vectors [projectId] has stored, backing
  /// `hasProjectMaterial` (Req 2.5). The identifier is bound as a parameter.
  Future<int> countForProject(String projectId) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM $_table '
      'WHERE ${ChunkEmbeddingColumns.projectId} = ?',
      <Object?>[projectId],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// Streams [projectId]'s stored chunk vectors in bounded pages of at most
  /// [pageSize] rows, so a single cosine scan never deserializes the whole
  /// project index at once (Req 2.5, 8.4).
  ///
  /// Each yielded batch is a list of decoded [StoredChunkEmbedding]s. Rows are
  /// read in a stable order — `(source_id, chunk_index, id)` — so the scan
  /// visits the same rows in the same order every call, which combined with the
  /// retriever's deterministic tie-break makes repeated identical queries yield
  /// a stable result (Req 1.6). Paging uses a keyset cursor on the row id rather
  /// than OFFSET so cost does not grow with the page number.
  ///
  /// A row whose BLOB length is not a whole multiple of 4 (a corrupt or
  /// mis-shaped vector) is skipped rather than crashing the scan; the caller
  /// additionally guards on `dim` / `model_id` (Req 7.4).
  Stream<List<StoredChunkEmbedding>> scanProject(
    String projectId, {
    int pageSize = defaultScanPageSize,
  }) async* {
    // Guard against a nonsensical page size that would loop forever or read
    // nothing.
    final int limit = pageSize < 1 ? defaultScanPageSize : pageSize;
    String? cursor; // last id read; null on the first page.

    while (true) {
      final String where = cursor == null
          ? '${ChunkEmbeddingColumns.projectId} = ?'
          : '${ChunkEmbeddingColumns.projectId} = ? '
              'AND ${ChunkEmbeddingColumns.id} > ?';
      final List<Object?> whereArgs = cursor == null
          ? <Object?>[projectId]
          : <Object?>[projectId, cursor];

      final List<Map<String, Object?>> rows = await _db.query(
        _table,
        where: where,
        whereArgs: whereArgs,
        orderBy: '${ChunkEmbeddingColumns.id} ASC',
        limit: limit,
      );
      if (rows.isEmpty) return;

      final List<StoredChunkEmbedding> batch = <StoredChunkEmbedding>[];
      for (final Map<String, Object?> row in rows) {
        final StoredChunkEmbedding? decoded = _tryDecodeRow(row);
        if (decoded != null) batch.add(decoded);
      }
      if (batch.isNotEmpty) yield batch;

      // Advance the keyset cursor to the last row read (regardless of whether it
      // decoded) so a corrupt row can never stall the scan.
      cursor = rows.last[ChunkEmbeddingColumns.id] as String?;
      if (cursor == null || rows.length < limit) return;
    }
  }

  /// Returns the stored per-chunk content hashes for [sourceId] within
  /// [projectId], ordered by `chunk_index`, for the incremental reindex diff
  /// (Req 4.2).
  ///
  /// The indexer compares these against the hashes of freshly re-chunked text to
  /// re-embed only changed chunks, delete vanished ones, and leave unchanged
  /// chunks untouched. Both identifiers are bound as parameters.
  Future<List<StoredChunkHash>> readStoredHashesForSource(
    String projectId,
    String sourceId,
  ) async {
    final List<Map<String, Object?>> rows = await _db.query(
      _table,
      columns: <String>[
        ChunkEmbeddingColumns.id,
        ChunkEmbeddingColumns.chunkIndex,
        ChunkEmbeddingColumns.contentHash,
      ],
      where: '${ChunkEmbeddingColumns.projectId} = ? '
          'AND ${ChunkEmbeddingColumns.sourceId} = ?',
      whereArgs: <Object?>[projectId, sourceId],
      orderBy: '${ChunkEmbeddingColumns.chunkIndex} ASC',
    );
    return rows
        .map((Map<String, Object?> row) => StoredChunkHash(
              id: (row[ChunkEmbeddingColumns.id] as String?) ?? '',
              chunkIndex:
                  (row[ChunkEmbeddingColumns.chunkIndex] as num?)?.toInt() ?? 0,
              contentHash:
                  (row[ChunkEmbeddingColumns.contentHash] as String?) ?? '',
            ))
        .toList(growable: false);
  }

  /// Serializes an [embedded] chunk (belonging to [projectId]) to a SQLite row.
  ///
  /// The vector is L2-normalized and encoded to a little-endian Float32 BLOB via
  /// [VectorCodec]; the source type is stored as its
  /// [ChunkSourceType.storageValue]; timestamps are integer milliseconds since
  /// the Unix epoch in UTC (matching the project's timestamp convention).
  static Map<String, Object?> _toRow({
    required String projectId,
    required EmbeddedChunk embedded,
    required String modelId,
    required int dim,
    required int createdAt,
    required int updatedAt,
  }) {
    final SourceChunk chunk = embedded.chunk;
    final List<double> normalized = VectorCodec.normalize(embedded.vector);
    return <String, Object?>{
      ChunkEmbeddingColumns.id: chunk.id,
      ChunkEmbeddingColumns.projectId: projectId,
      ChunkEmbeddingColumns.sourceId: chunk.sourceId,
      ChunkEmbeddingColumns.sourceType: chunk.sourceType.storageValue,
      ChunkEmbeddingColumns.sourceTitle: chunk.sourceTitle,
      ChunkEmbeddingColumns.chunkIndex: chunk.chunkIndex,
      ChunkEmbeddingColumns.contentHash: chunk.contentHash,
      ChunkEmbeddingColumns.text: chunk.text,
      ChunkEmbeddingColumns.modelId: modelId,
      ChunkEmbeddingColumns.dim: dim,
      ChunkEmbeddingColumns.embedding: VectorCodec.encode(normalized),
      ChunkEmbeddingColumns.createdAt: createdAt,
      ChunkEmbeddingColumns.updatedAt: updatedAt,
    };
  }

  /// Decodes a scan row into a [StoredChunkEmbedding], or returns `null` when
  /// the row's BLOB is not a valid Float32 vector (length not a multiple of 4),
  /// so a corrupt or mis-shaped row is skipped rather than crashing the scan
  /// (Req 7.4).
  static StoredChunkEmbedding? _tryDecodeRow(Map<String, Object?> row) {
    final Object? blob = row[ChunkEmbeddingColumns.embedding];
    if (blob is! Uint8List) return null;
    final List<double> vector;
    try {
      vector = VectorCodec.decode(blob);
    } on ArgumentError {
      return null;
    }
    final String typeName =
        (row[ChunkEmbeddingColumns.sourceType] as String?) ?? '';
    final ChunkSourceType sourceType = ChunkSourceType.values.firstWhere(
      (ChunkSourceType t) => t.storageValue == typeName,
      orElse: () => ChunkSourceType.document,
    );
    return StoredChunkEmbedding(
      id: (row[ChunkEmbeddingColumns.id] as String?) ?? '',
      sourceId: (row[ChunkEmbeddingColumns.sourceId] as String?) ?? '',
      sourceType: sourceType,
      sourceTitle: (row[ChunkEmbeddingColumns.sourceTitle] as String?) ?? '',
      chunkIndex: (row[ChunkEmbeddingColumns.chunkIndex] as num?)?.toInt() ?? 0,
      text: (row[ChunkEmbeddingColumns.text] as String?) ?? '',
      modelId: (row[ChunkEmbeddingColumns.modelId] as String?) ?? '',
      dim: (row[ChunkEmbeddingColumns.dim] as num?)?.toInt() ?? vector.length,
      embedding: vector,
    );
  }
}
