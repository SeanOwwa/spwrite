// Example-based unit tests for [SemanticContextRetriever] (ai_feature_3.6 task
// 7.5).
//
// Where the ordering property test proves the *stable ordering* invariant over
// many generated inputs, these concrete cases pin down the retriever's headline
// behaviors on hand-crafted examples (design §Testing Strategy, Req 1.2, 2.5,
// 5.5, 7.4):
//
//   * a meaning-close query with *no word overlap* with the target chunk still
//     retrieves it, because ranking is by embedding geometry not lexical
//     overlap (Req 1.2);
//   * a blank / whitespace query returns an empty list without ever touching
//     the index (no embed, no scan, no count);
//   * `topN` caps the number of returned passages;
//   * `hasProjectMaterial` reflects the stored count (true when rows exist,
//     false for an empty / unindexed project) (Req 2.5, 5.5);
//   * the paged scan reads the index in bounded batches (a small `pageSize`
//     still returns every matching chunk);
//   * a stale index — stored rows tagged with a different `model_id` / `dim`
//     than the current model — fires the `onStaleIndexDetected` callback and
//     yields no semantic grounding, without throwing (Req 7.4);
//   * a query-time embedding failure propagates as a thrown error so the
//     composite retriever can fall back (Req 7.4).
//
// Like the ordering test, the retriever + repository run end to end against a
// real [ChunkEmbeddingRepository] over an in-memory SQLite database (the FFI
// factory) with a deterministic fake [EmbeddingModel] — no real model and no
// network, so every score is exact and reproducible.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spwrite/data/ai/chunk_embedding_repository.dart';
import 'package:spwrite/data/ai/chunker.dart';
import 'package:spwrite/data/ai/semantic_context_retriever.dart';
import 'package:spwrite/domain/ai/context_retriever.dart';
import 'package:spwrite/domain/ai/embedding_model.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/domain/project.dart';

/// The embedding dimension used throughout — one basis vector per axis.
const int _dim = 4;

/// The model id stored rows and the fake model share, so no row is skipped as a
/// stale-model mismatch (except the dedicated stale-index test, which seeds a
/// deliberately different id).
const String _modelId = 'bge-small-en-v1.5';

/// A deterministic fake [EmbeddingModel] mapping a text to one of the [_dim]
/// one-hot basis vectors via a caller-supplied lookup, so cosine scores are
/// exactly 0.0 or 1.0 and the meaning-close case is expressible without any
/// lexical overlap between query and chunk text.
///
/// Records the texts it was asked to embed in [embedCalls], letting a test
/// assert the index was *not touched* for a blank query. When [failOnEmbed] is
/// set, [embed] throws it, exercising the query-time failure path (Req 7.4).
class _FakeEmbeddingModel implements EmbeddingModel {
  _FakeEmbeddingModel(this._axisOf, {this.failOnEmbed});

  /// Maps a raw text to the basis axis `[0, _dim)` it embeds onto.
  final int Function(String text) _axisOf;

  /// When non-null, [embed] throws this instead of returning a vector.
  final Object? failOnEmbed;

  /// Every text passed to [embed], in call order.
  final List<String> embedCalls = <String>[];

  @override
  int get dimension => _dim;

  @override
  String get modelId => _modelId;

  @override
  Future<void> load() async {}

  @override
  Future<List<double>> embed(String text) async {
    embedCalls.add(text);
    if (failOnEmbed != null) throw failOnEmbed!;
    final int axis = _axisOf(text) % _dim;
    return <double>[
      for (int i = 0; i < _dim; i++) i == axis ? 1.0 : 0.0,
    ];
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async =>
      <List<double>>[for (final String t in texts) await embed(t)];

  @override
  Future<void> dispose() async {}
}

/// A lightweight chunk description: its source, position, basis axis (which
/// fixes its score against a query), and the text stored/returned for it.
class _ChunkSpec {
  const _ChunkSpec({
    required this.sourceId,
    required this.chunkIndex,
    required this.axis,
    required this.text,
  });

  final String sourceId;
  final int chunkIndex;
  final int axis;
  final String text;

  String get id => DocumentChunker.chunkId(sourceId, chunkIndex);
}

void main() {
  setUpAll(() {
    // In-memory FFI factory: a genuine SQLite store on the dev machine, no disk
    // and no platform DB (matches the other sqlite repository tests).
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// Seeds the parent project row so the `ai_chunk_embeddings` FK is satisfied.
  Future<void> seedProject(Database db, String id) async {
    await db.insert(
      DatabaseProvider.projectsTable,
      Project.create(id: id, name: 'Project $id', now: DateTime.utc(2024))
          .toRow(),
    );
  }

  /// Writes [specs] into the repository as one-hot embedded chunks, tagged with
  /// [modelId] / [dim] (defaults to the current model, so nothing is stale).
  Future<void> seedChunks(
    ChunkEmbeddingRepository repo,
    String projectId,
    List<_ChunkSpec> specs, {
    String modelId = _modelId,
    int dim = _dim,
  }) async {
    final List<EmbeddedChunk> embedded = <EmbeddedChunk>[
      for (final _ChunkSpec s in specs)
        EmbeddedChunk(
          chunk: SourceChunk(
            id: s.id,
            sourceId: s.sourceId,
            sourceType: ChunkSourceType.document,
            sourceTitle: 'Title ${s.sourceId}',
            chunkIndex: s.chunkIndex,
            text: s.text,
            contentHash: DocumentChunker.contentHashOf(s.text),
          ),
          vector: <double>[
            for (int i = 0; i < _dim; i++) i == (s.axis % _dim) ? 1.0 : 0.0,
          ],
        ),
    ];
    await repo.upsertChunks(projectId, embedded, modelId: modelId, dim: dim);
  }

  group('SemanticContextRetriever.retrieve — task 7.5 (Req 1.2, 2.5, 5.5)', () {
    test(
        'a meaning-close query with no word overlap still retrieves the right '
        'chunk (Req 1.2)', () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, 'p1');

        // The target chunk's text shares no words with the query, but sits on
        // the same embedding axis (axis 1), so it must still be retrieved.
        // A decoy chunk on a different axis shares no meaning and is dropped by
        // the relevance floor.
        await seedChunks(repo, 'p1', <_ChunkSpec>[
          const _ChunkSpec(
            sourceId: 'doc-a',
            chunkIndex: 0,
            axis: 1,
            text: 'The monarch abdicated the throne in autumn.',
          ),
          const _ChunkSpec(
            sourceId: 'doc-b',
            chunkIndex: 0,
            axis: 2,
            text: 'A recipe for sourdough bread with rye flour.',
          ),
        ]);

        // The query embeds onto axis 1 — the target's axis — despite sharing no
        // words with the target text.
        final SemanticContextRetriever retriever = SemanticContextRetriever(
          embeddingModel: _FakeEmbeddingModel((_) => 1),
          embeddings: repo,
          projectId: 'p1',
        );

        final List<RetrievedPassage> got =
            await retriever.retrieve('who gave up the crown?');

        expect(got, hasLength(1));
        expect(got.single.sourceId, 'doc-a');
        expect(got.single.text, 'The monarch abdicated the throne in autumn.');
        expect(got.single.score, closeTo(1.0, 1e-6));
      } finally {
        await db.close();
      }
    });

    test('a blank / whitespace query returns empty without touching the index',
        () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, 'p1');
        await seedChunks(repo, 'p1', <_ChunkSpec>[
          const _ChunkSpec(
              sourceId: 'doc-a', chunkIndex: 0, axis: 0, text: 'body'),
        ]);

        final _FakeEmbeddingModel model = _FakeEmbeddingModel((_) => 0);
        final SemanticContextRetriever retriever = SemanticContextRetriever(
          embeddingModel: model,
          embeddings: repo,
          projectId: 'p1',
        );

        for (final String blank in <String>['', '   ', '\t\n  ']) {
          final List<RetrievedPassage> got = await retriever.retrieve(blank);
          expect(got, isEmpty, reason: 'blank query "$blank" must return empty');
        }

        // The index was never touched: the model was never asked to embed.
        expect(model.embedCalls, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('topN caps the number of returned passages (Req 5.1)', () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, 'p1');

        // Six chunks all on the query axis (all score 1.0). With topN = 2 only
        // the first two by the deterministic tie-break may be returned.
        await seedChunks(repo, 'p1', <_ChunkSpec>[
          for (int i = 0; i < 6; i++)
            _ChunkSpec(
                sourceId: 'doc-a', chunkIndex: i, axis: 0, text: 'chunk $i'),
        ]);

        final SemanticContextRetriever retriever = SemanticContextRetriever(
          embeddingModel: _FakeEmbeddingModel((_) => 0),
          embeddings: repo,
          projectId: 'p1',
          topN: 2,
        );

        final List<RetrievedPassage> got = await retriever.retrieve('q');
        expect(got, hasLength(2));
        // The cap keeps the lowest (sourceId, chunkIndex) survivors.
        expect(
          got.map((RetrievedPassage p) => p.text).toList(),
          <String>['chunk 0', 'chunk 1'],
        );
      } finally {
        await db.close();
      }
    });

    test('the paged scan returns every match even with a tiny page size '
        '(Req 2.5)', () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, 'p1');

        // Ten chunks, all on the query axis, spread across sources so a scan
        // page boundary lands mid-project. A generous topN lets every match
        // through, so a batching bug would drop rows and shrink the result.
        final List<_ChunkSpec> specs = <_ChunkSpec>[
          for (int i = 0; i < 10; i++)
            _ChunkSpec(
              sourceId: 'doc-${i % 3}',
              chunkIndex: i,
              axis: 0,
              text: 'body $i',
            ),
        ];
        await seedChunks(repo, 'p1', specs);

        // The retriever uses the repository's default page size internally; to
        // prove batching, scan directly with a page size of 3 and confirm the
        // repository yields multiple bounded batches covering all rows, then
        // confirm the retriever returns all ten.
        final List<int> batchSizes = <int>[];
        await for (final List<StoredChunkEmbedding> batch
            in repo.scanProject('p1', pageSize: 3)) {
          batchSizes.add(batch.length);
        }
        expect(batchSizes.length, greaterThan(1),
            reason: 'a tiny page size must produce multiple batches');
        expect(batchSizes.every((int n) => n <= 3), isTrue,
            reason: 'no batch may exceed the page size');
        expect(batchSizes.fold<int>(0, (int a, int b) => a + b), 10,
            reason: 'batches together must cover all stored rows');

        final SemanticContextRetriever retriever = SemanticContextRetriever(
          embeddingModel: _FakeEmbeddingModel((_) => 0),
          embeddings: repo,
          projectId: 'p1',
          topN: 100,
        );
        final List<RetrievedPassage> got = await retriever.retrieve('q');
        expect(got, hasLength(10));
      } finally {
        await db.close();
      }
    });
  });

  group('SemanticContextRetriever.hasProjectMaterial — task 7.5 (Req 2.5, 5.5)',
      () {
    test('is false for an empty / unindexed project', () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, 'p1');

        final SemanticContextRetriever retriever = SemanticContextRetriever(
          embeddingModel: _FakeEmbeddingModel((_) => 0),
          embeddings: repo,
          projectId: 'p1',
        );

        expect(await retriever.hasProjectMaterial(), isFalse);
      } finally {
        await db.close();
      }
    });

    test('is true once the project has any stored chunk vector', () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, 'p1');
        await seedChunks(repo, 'p1', <_ChunkSpec>[
          const _ChunkSpec(
              sourceId: 'doc-a', chunkIndex: 0, axis: 0, text: 'body'),
        ]);

        final SemanticContextRetriever retriever = SemanticContextRetriever(
          embeddingModel: _FakeEmbeddingModel((_) => 0),
          embeddings: repo,
          projectId: 'p1',
        );

        expect(await retriever.hasProjectMaterial(), isTrue);
      } finally {
        await db.close();
      }
    });

    test('is scoped to the project — a sibling project\'s rows do not count',
        () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, 'p1');
        await seedProject(db, 'p2');
        // Only p2 has material.
        await seedChunks(repo, 'p2', <_ChunkSpec>[
          const _ChunkSpec(
              sourceId: 'doc-a', chunkIndex: 0, axis: 0, text: 'body'),
        ]);

        final SemanticContextRetriever p1 = SemanticContextRetriever(
          embeddingModel: _FakeEmbeddingModel((_) => 0),
          embeddings: repo,
          projectId: 'p1',
        );
        expect(await p1.hasProjectMaterial(), isFalse);
      } finally {
        await db.close();
      }
    });
  });

  group('SemanticContextRetriever — stale index & failure (task 7.5, Req 7.4)',
      () {
    test(
        'stale rows (different model_id) fire onStaleIndexDetected once and '
        'yield no semantic grounding, without throwing', () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, 'p1');

        // Rows tagged with a *different* model id than the current model — the
        // vectors live in another embedding space and must be skipped.
        await seedChunks(
          repo,
          'p1',
          <_ChunkSpec>[
            const _ChunkSpec(
                sourceId: 'doc-a', chunkIndex: 0, axis: 0, text: 'a'),
            const _ChunkSpec(
                sourceId: 'doc-a', chunkIndex: 1, axis: 0, text: 'b'),
          ],
          modelId: 'some-old-model-v1',
        );

        final List<String> staleSignals = <String>[];
        final SemanticContextRetriever retriever = SemanticContextRetriever(
          embeddingModel: _FakeEmbeddingModel((_) => 0),
          embeddings: repo,
          projectId: 'p1',
          onStaleIndexDetected: staleSignals.add,
        );

        final List<RetrievedPassage> got = await retriever.retrieve('q');

        expect(got, isEmpty,
            reason: 'stale rows are skipped, so no grounding survives');
        expect(staleSignals, <String>['p1'],
            reason: 'the callback fires exactly once with the project id');
      } finally {
        await db.close();
      }
    });

    test('stale rows (different dim) also fire onStaleIndexDetected', () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, 'p1');

        // Correct model id but a different declared dim: still a different
        // space, so the row is stale.
        await seedChunks(
          repo,
          'p1',
          <_ChunkSpec>[
            const _ChunkSpec(
                sourceId: 'doc-a', chunkIndex: 0, axis: 0, text: 'a'),
          ],
          dim: _dim + 1,
        );

        final List<String> staleSignals = <String>[];
        final SemanticContextRetriever retriever = SemanticContextRetriever(
          embeddingModel: _FakeEmbeddingModel((_) => 0),
          embeddings: repo,
          projectId: 'p1',
          onStaleIndexDetected: staleSignals.add,
        );

        final List<RetrievedPassage> got = await retriever.retrieve('q');

        expect(got, isEmpty);
        expect(staleSignals, <String>['p1']);
      } finally {
        await db.close();
      }
    });

    test('a query-time embedding failure propagates (throws) (Req 7.4)',
        () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, 'p1');
        await seedChunks(repo, 'p1', <_ChunkSpec>[
          const _ChunkSpec(
              sourceId: 'doc-a', chunkIndex: 0, axis: 0, text: 'body'),
        ]);

        final SemanticContextRetriever retriever = SemanticContextRetriever(
          embeddingModel: _FakeEmbeddingModel(
            (_) => 0,
            failOnEmbed: StateError('embedding backend unavailable'),
          ),
          embeddings: repo,
          projectId: 'p1',
        );

        await expectLater(
          retriever.retrieve('q'),
          throwsA(isA<StateError>()),
        );
      } finally {
        await db.close();
      }
    });
  });
}
