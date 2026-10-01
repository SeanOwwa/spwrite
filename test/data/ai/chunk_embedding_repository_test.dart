import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spwrite/data/ai/chunk_embedding_repository.dart';
import 'package:spwrite/data/ai/chunker.dart';
import 'package:spwrite/data/ai/vector_codec.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/domain/project.dart';

/// Unit tests for [ChunkEmbeddingRepository] (Task 4.4, Req 2.5, 4.7, 8.4).
///
/// Exercises the project-scoped `ai_chunk_embeddings` vector index against an
/// in-memory SQLite database (the FFI factory, matching the other sqlite
/// repository tests):
///
/// - [ChunkEmbeddingRepository.upsertChunks] inserts new rows and replaces a row
///   in place by its stable chunk id, preserving `created_at` while moving
///   `updated_at` forward;
/// - [ChunkEmbeddingRepository.deleteBySource] /
///   [ChunkEmbeddingRepository.deleteAllForProject] are project-scoped and never
///   touch another project's or source's rows;
/// - [ChunkEmbeddingRepository.countForProject] reflects the stored row count;
/// - [ChunkEmbeddingRepository.scanProject] pages through rows in stable order,
///   covers every row, and skips corrupt BLOBs without crashing;
/// - [ChunkEmbeddingRepository.readStoredHashesForSource] returns the stored
///   per-chunk hashes ordered by `chunk_index`.
void main() {
  setUpAll(() {
    // In-memory FFI factory so the tests run on the dev machine without touching
    // disk or a real platform database (matches the conversation repo tests).
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const String modelId = 'bge-small-en-v1.5';
  const int dim = 4;

  late Database db;
  late ChunkEmbeddingRepository repo;

  setUp(() async {
    db = await DatabaseProvider.openAppDatabase(
      overridePath: inMemoryDatabasePath,
    );
    repo = ChunkEmbeddingRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  /// Seeds a parent project row so the `ai_chunk_embeddings` FK to `projects`
  /// is satisfied (the FFI factory enables `PRAGMA foreign_keys = ON`).
  Future<void> seedProject(String id) async {
    final DateTime now = DateTime.utc(2024, 1, 1);
    await db.insert(
      DatabaseProvider.projectsTable,
      Project.create(id: id, name: 'Project $id', now: now).toRow(),
    );
  }

  /// Builds a [SourceChunk] with a stable id derived from `(sourceId, index)`
  /// and a content hash over [text], exactly as the chunker would.
  SourceChunk chunk(
    String sourceId,
    int index,
    String text, {
    ChunkSourceType sourceType = ChunkSourceType.document,
    String sourceTitle = 'A Title',
  }) {
    return SourceChunk(
      id: DocumentChunker.chunkId(sourceId, index),
      sourceId: sourceId,
      sourceType: sourceType,
      sourceTitle: sourceTitle,
      chunkIndex: index,
      text: text,
      contentHash: DocumentChunker.contentHashOf(text),
    );
  }

  /// A tiny embedded chunk pairing [chunk] with a [dim]-length vector.
  EmbeddedChunk embedded(SourceChunk source, List<double> vector) =>
      EmbeddedChunk(chunk: source, vector: vector);

  /// Reads the raw stored row for [id] (bypassing the repository decoder) so a
  /// test can assert on the persisted `created_at` / `updated_at` / `text`.
  Future<Map<String, Object?>?> rawRow(String id) async {
    final List<Map<String, Object?>> rows = await db.query(
      DatabaseProvider.aiChunkEmbeddingsTable,
      where: '${ChunkEmbeddingColumns.id} = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Drains a paged scan into a single flat list preserving batch order.
  Future<List<StoredChunkEmbedding>> drain(
    Stream<List<StoredChunkEmbedding>> stream,
  ) async {
    final List<StoredChunkEmbedding> all = <StoredChunkEmbedding>[];
    await for (final List<StoredChunkEmbedding> batch in stream) {
      all.addAll(batch);
    }
    return all;
  }

  group('upsertChunks round-trip', () {
    test('inserts new rows readable back through a scan with fields intact',
        () async {
      await seedProject('p1');

      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[
          embedded(
            chunk('doc-1', 0, 'first chunk',
                sourceTitle: 'Chapter 1'),
            <double>[1.0, 0.0, 0.0, 0.0],
          ),
          embedded(
            chunk('doc-1', 1, 'second chunk', sourceTitle: 'Chapter 1'),
            <double>[0.0, 1.0, 0.0, 0.0],
          ),
        ],
        modelId: modelId,
        dim: dim,
      );

      final List<StoredChunkEmbedding> stored =
          await drain(repo.scanProject('p1'));
      expect(stored, hasLength(2));

      final StoredChunkEmbedding byIndex0 =
          stored.firstWhere((StoredChunkEmbedding s) => s.chunkIndex == 0);
      expect(byIndex0.sourceId, 'doc-1');
      expect(byIndex0.sourceType, ChunkSourceType.document);
      expect(byIndex0.sourceTitle, 'Chapter 1');
      expect(byIndex0.text, 'first chunk');
      expect(byIndex0.modelId, modelId);
      expect(byIndex0.dim, dim);
      expect(byIndex0.embedding, hasLength(dim));
      // Stored vectors are L2-normalized; a one-hot input is already unit-length.
      expect(byIndex0.embedding[0], closeTo(1.0, 1e-6));
    });

    test('normalizes the vector on write so the stored bytes are unit-length',
        () async {
      await seedProject('p1');
      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[
          embedded(chunk('doc-1', 0, 'text'), <double>[3.0, 4.0, 0.0, 0.0]),
        ],
        modelId: modelId,
        dim: dim,
      );

      final StoredChunkEmbedding s =
          (await drain(repo.scanProject('p1'))).single;
      // (3,4) has norm 5 → normalized (0.6, 0.8).
      expect(s.embedding[0], closeTo(0.6, 1e-6));
      expect(s.embedding[1], closeTo(0.8, 1e-6));
      expect(VectorCodec.l2Norm(s.embedding), closeTo(1.0, 1e-6));
    });

    test('an empty chunk list is a no-op', () async {
      await seedProject('p1');
      await repo.upsertChunks('p1', const <EmbeddedChunk>[],
          modelId: modelId, dim: dim);
      expect(await repo.countForProject('p1'), 0);
    });

    test(
        'replaces a row in place by stable id, preserving created_at and moving '
        'updated_at', () async {
      await seedProject('p1');

      final SourceChunk original = chunk('doc-1', 0, 'original text');
      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[embedded(original, <double>[1.0, 0.0, 0.0, 0.0])],
        modelId: modelId,
        dim: dim,
      );

      final Map<String, Object?> firstRow = (await rawRow(original.id))!;
      final int createdAt =
          (firstRow[ChunkEmbeddingColumns.createdAt] as num).toInt();
      final int firstUpdatedAt =
          (firstRow[ChunkEmbeddingColumns.updatedAt] as num).toInt();

      // Ensure a strictly later wall-clock millisecond for the replace.
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // Same stable id (same source + index), new text/vector.
      final SourceChunk revised = chunk('doc-1', 0, 'revised text');
      expect(revised.id, original.id); // stable id precondition
      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[embedded(revised, <double>[0.0, 1.0, 0.0, 0.0])],
        modelId: modelId,
        dim: dim,
      );

      // Still exactly one row for this chunk (replace, not orphan/insert).
      expect(await repo.countForProject('p1'), 1);

      final Map<String, Object?> secondRow = (await rawRow(original.id))!;
      expect(secondRow[ChunkEmbeddingColumns.text], 'revised text');
      // created_at preserved across the replace.
      expect((secondRow[ChunkEmbeddingColumns.createdAt] as num).toInt(),
          createdAt);
      // updated_at moved forward.
      expect(
        (secondRow[ChunkEmbeddingColumns.updatedAt] as num).toInt(),
        greaterThan(firstUpdatedAt),
      );
    });
  });

  group('deleteBySource is source- and project-scoped', () {
    test('removes only the target source, leaving other sources and projects',
        () async {
      await seedProject('p1');
      await seedProject('p2');

      // Two sources in p1, and a distinct source in p2 (source ids are globally
      // unique in the app, so distinct ids also cover cross-project isolation).
      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[
          embedded(chunk('p1-doc-1', 0, 'a'), <double>[1, 0, 0, 0]),
          embedded(chunk('p1-doc-1', 1, 'b'), <double>[0, 1, 0, 0]),
          embedded(chunk('p1-doc-2', 0, 'c'), <double>[0, 0, 1, 0]),
        ],
        modelId: modelId,
        dim: dim,
      );
      await repo.upsertChunks(
        'p2',
        <EmbeddedChunk>[
          embedded(chunk('p2-doc-1', 0, 'p2 source'), <double>[0, 0, 0, 1]),
        ],
        modelId: modelId,
        dim: dim,
      );

      final int deleted = await repo.deleteBySource('p1', 'p1-doc-1');
      expect(deleted, 2);

      final List<StoredChunkEmbedding> p1 =
          await drain(repo.scanProject('p1'));
      expect(p1.map((StoredChunkEmbedding s) => s.sourceId),
          everyElement('p1-doc-2'));
      expect(p1, hasLength(1));

      // p2's source is untouched.
      expect(await repo.countForProject('p2'), 1);
    });

    test('deleting a source with no rows returns 0 and changes nothing',
        () async {
      await seedProject('p1');
      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[embedded(chunk('doc-1', 0, 'a'), <double>[1, 0, 0, 0])],
        modelId: modelId,
        dim: dim,
      );
      expect(await repo.deleteBySource('p1', 'missing'), 0);
      expect(await repo.countForProject('p1'), 1);
    });
  });

  group('deleteAllForProject is project-scoped', () {
    test('wipes only the target project', () async {
      await seedProject('p1');
      await seedProject('p2');

      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[
          embedded(chunk('doc-1', 0, 'a'), <double>[1, 0, 0, 0]),
          embedded(chunk('doc-2', 0, 'b'), <double>[0, 1, 0, 0]),
        ],
        modelId: modelId,
        dim: dim,
      );
      await repo.upsertChunks(
        'p2',
        <EmbeddedChunk>[embedded(chunk('doc-9', 0, 'c'), <double>[0, 0, 1, 0])],
        modelId: modelId,
        dim: dim,
      );

      final int deleted = await repo.deleteAllForProject('p1');
      expect(deleted, 2);
      expect(await repo.countForProject('p1'), 0);
      // p2 untouched.
      expect(await repo.countForProject('p2'), 1);
    });
  });

  group('countForProject', () {
    test('reflects stored rows and is project-scoped', () async {
      await seedProject('p1');
      await seedProject('p2');
      expect(await repo.countForProject('p1'), 0);

      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[
          embedded(chunk('p1-doc-1', 0, 'a'), <double>[1, 0, 0, 0]),
          embedded(chunk('p1-doc-1', 1, 'b'), <double>[0, 1, 0, 0]),
          embedded(chunk('p1-doc-2', 0, 'c'), <double>[0, 0, 1, 0]),
        ],
        modelId: modelId,
        dim: dim,
      );
      await repo.upsertChunks(
        'p2',
        <EmbeddedChunk>[embedded(chunk('p2-doc-1', 0, 'x'), <double>[0, 0, 0, 1])],
        modelId: modelId,
        dim: dim,
      );

      expect(await repo.countForProject('p1'), 3);
      expect(await repo.countForProject('p2'), 1);
      expect(await repo.countForProject('unknown'), 0);
    });
  });

  group('scanProject', () {
    test('pages through all rows in a stable id order across multiple batches',
        () async {
      await seedProject('p1');

      // 5 chunks; page size 2 forces 3 batches (2 + 2 + 1).
      final List<EmbeddedChunk> chunks = <EmbeddedChunk>[
        for (int i = 0; i < 5; i++)
          embedded(chunk('doc-1', i, 'chunk $i'),
              <double>[i.toDouble(), 1, 0, 0]),
      ];
      await repo.upsertChunks('p1', chunks, modelId: modelId, dim: dim);

      // Collect per-batch to assert batching, then flatten for coverage.
      final List<int> batchSizes = <int>[];
      final List<StoredChunkEmbedding> flat = <StoredChunkEmbedding>[];
      await for (final List<StoredChunkEmbedding> batch
          in repo.scanProject('p1', pageSize: 2)) {
        batchSizes.add(batch.length);
        flat.addAll(batch);
      }

      // Batches respected the page size (2, 2, 1).
      expect(batchSizes, <int>[2, 2, 1]);
      // Every row is covered exactly once.
      expect(flat, hasLength(5));
      expect(
        flat.map((StoredChunkEmbedding s) => s.text).toSet(),
        <String>{'chunk 0', 'chunk 1', 'chunk 2', 'chunk 3', 'chunk 4'},
      );

      // Order is stable: repeating the scan yields the same id sequence.
      final List<String> firstOrder =
          flat.map((StoredChunkEmbedding s) => s.id).toList();
      final List<StoredChunkEmbedding> again =
          await drain(repo.scanProject('p1', pageSize: 2));
      expect(again.map((StoredChunkEmbedding s) => s.id).toList(), firstOrder);
    });

    test('is project-scoped', () async {
      await seedProject('p1');
      await seedProject('p2');
      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[embedded(chunk('p1-doc-1', 0, 'p1'), <double>[1, 0, 0, 0])],
        modelId: modelId,
        dim: dim,
      );
      await repo.upsertChunks(
        'p2',
        <EmbeddedChunk>[embedded(chunk('p2-doc-1', 0, 'p2'), <double>[0, 1, 0, 0])],
        modelId: modelId,
        dim: dim,
      );

      final List<StoredChunkEmbedding> p1 =
          await drain(repo.scanProject('p1'));
      expect(p1.single.text, 'p1');
    });

    test('skips rows with a corrupt (non-Float32-shaped) BLOB without crashing',
        () async {
      await seedProject('p1');

      // Two good rows.
      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[
          embedded(chunk('doc-1', 0, 'good a'), <double>[1, 0, 0, 0]),
          embedded(chunk('doc-1', 1, 'good b'), <double>[0, 1, 0, 0]),
        ],
        modelId: modelId,
        dim: dim,
      );

      // One deliberately corrupt row: a 3-byte BLOB (not a multiple of 4) that
      // VectorCodec.decode rejects. Inserted raw to bypass the encoder.
      await db.insert(
        DatabaseProvider.aiChunkEmbeddingsTable,
        <String, Object?>{
          ChunkEmbeddingColumns.id: DocumentChunker.chunkId('doc-corrupt', 0),
          ChunkEmbeddingColumns.projectId: 'p1',
          ChunkEmbeddingColumns.sourceId: 'doc-corrupt',
          ChunkEmbeddingColumns.sourceType:
              ChunkSourceType.document.storageValue,
          ChunkEmbeddingColumns.sourceTitle: 'Corrupt',
          ChunkEmbeddingColumns.chunkIndex: 0,
          ChunkEmbeddingColumns.contentHash: 'deadbeef',
          ChunkEmbeddingColumns.text: 'corrupt',
          ChunkEmbeddingColumns.modelId: modelId,
          ChunkEmbeddingColumns.dim: dim,
          ChunkEmbeddingColumns.embedding: Uint8List.fromList(<int>[1, 2, 3]),
          ChunkEmbeddingColumns.createdAt: 1000,
          ChunkEmbeddingColumns.updatedAt: 1000,
        },
      );

      // The corrupt row still counts as a stored row...
      expect(await repo.countForProject('p1'), 3);

      // ...but the scan skips it and returns only the two decodable rows.
      final List<StoredChunkEmbedding> stored =
          await drain(repo.scanProject('p1', pageSize: 1));
      expect(stored, hasLength(2));
      expect(
        stored.map((StoredChunkEmbedding s) => s.text).toSet(),
        <String>{'good a', 'good b'},
      );
    });

    test('an empty project yields no batches', () async {
      await seedProject('p1');
      expect(await drain(repo.scanProject('p1')), isEmpty);
    });

    test('a non-positive page size falls back to the default and still scans',
        () async {
      await seedProject('p1');
      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[embedded(chunk('doc-1', 0, 'a'), <double>[1, 0, 0, 0])],
        modelId: modelId,
        dim: dim,
      );
      expect(await drain(repo.scanProject('p1', pageSize: 0)), hasLength(1));
    });
  });

  group('readStoredHashesForSource', () {
    test('returns per-chunk hashes ordered by chunk_index, source-scoped',
        () async {
      await seedProject('p1');

      final SourceChunk c0 = chunk('doc-1', 0, 'alpha');
      final SourceChunk c1 = chunk('doc-1', 1, 'beta');
      final SourceChunk c2 = chunk('doc-1', 2, 'gamma');
      // Insert out of order to prove ordering comes from chunk_index, not
      // insertion order.
      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[
          embedded(c2, <double>[0, 0, 1, 0]),
          embedded(c0, <double>[1, 0, 0, 0]),
          embedded(c1, <double>[0, 1, 0, 0]),
        ],
        modelId: modelId,
        dim: dim,
      );
      // A different source that must not leak in.
      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[embedded(chunk('doc-2', 0, 'other'), <double>[0, 0, 0, 1])],
        modelId: modelId,
        dim: dim,
      );

      final List<StoredChunkHash> hashes =
          await repo.readStoredHashesForSource('p1', 'doc-1');

      expect(hashes.map((StoredChunkHash h) => h.chunkIndex), <int>[0, 1, 2]);
      expect(hashes[0].contentHash, DocumentChunker.contentHashOf('alpha'));
      expect(hashes[1].contentHash, DocumentChunker.contentHashOf('beta'));
      expect(hashes[2].contentHash, DocumentChunker.contentHashOf('gamma'));
      expect(hashes[0].id, c0.id);
      expect(hashes[1].id, c1.id);
      expect(hashes[2].id, c2.id);
    });

    test('is project-scoped and returns empty for an unknown source', () async {
      await seedProject('p1');
      await seedProject('p2');
      await repo.upsertChunks(
        'p1',
        <EmbeddedChunk>[embedded(chunk('doc-1', 0, 'a'), <double>[1, 0, 0, 0])],
        modelId: modelId,
        dim: dim,
      );
      // Same source id under a different project must not be returned.
      expect(await repo.readStoredHashesForSource('p2', 'doc-1'), isEmpty);
      expect(await repo.readStoredHashesForSource('p1', 'missing'), isEmpty);
    });
  });
}
