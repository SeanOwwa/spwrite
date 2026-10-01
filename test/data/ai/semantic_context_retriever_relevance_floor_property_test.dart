// Property test for the relevance floor of [SemanticContextRetriever]
// (ai_feature_3.6 task 7.4).
//
// Feature: ai_feature_3.6 — on-device semantic retrieval (RAG).
//
// Property 6: Relevance floor holds. A chunk whose cosine similarity to the
// query is below `minSimilarity` contributes no grounding, and when no chunk
// clears the floor `retrieve` returns empty — the retriever never pads the
// grounding with weak matches (design §"Property 6: Relevance floor holds").
//
// **Validates: Requirements 5.5**
//
// This file exercises [SemanticContextRetriever]
// (`lib/data/ai/semantic_context_retriever.dart`) end to end against a real
// [ChunkEmbeddingRepository] over an in-memory SQLite database (the FFI
// factory, matching the sibling `semantic_*_property_test.dart` files) and a
// deterministic fake [EmbeddingModel], so results are exact and reproducible
// with no real model and no network (design §Testing Strategy — "Component
// tests with a fake EmbeddingModel").
//
// Strategy: make every chunk's cosine score *exactly known and controllable* so
// the floor's effect is decidable, not approximate. Each chunk is assigned an
// angle θ in the x–y plane and stored as the 2-D unit vector `(cos θ, sin θ)`
// (padded to `_dim` with zeros). The query embeds onto the x-axis `(1, 0, …)`,
// so the cosine similarity of a chunk is exactly `cos θ` — a value we choose per
// chunk from a small pool spanning the full range (1.0 down to −1.0). Because
// the retriever normalizes both sides and the scores are exact, the set of
// chunks that *should* survive an arbitrary floor `f` is precisely
// `{ chunks : cos θ >= f }`, letting the test assert the property exactly.
//
// For each generated case a FRESH in-memory database is opened via
// `DatabaseProvider.openAppDatabase(overridePath: inMemoryDatabasePath)` so
// cases never leak into each other, and it is closed in a `finally` block. The
// `forAll` block is async; kiri_check 1.3.1 awaits the block internally (see the
// sibling data-layer property tests), so repository/retriever calls are awaited
// directly.
//
// Three facets of Property 6 are asserted per case:
//   1. every returned passage has `score >= minSimilarity` (nothing below the
//      floor is ever returned);
//   2. no chunk scoring below the floor appears in the results, and every chunk
//      at/above the floor that is not trimmed by `topN` is present (the floor
//      admits exactly the eligible chunks);
//   3. when NO chunk clears the floor, `retrieve` returns an empty list.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kiri_check/kiri_check.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spwrite/data/ai/chunk_embedding_repository.dart';
import 'package:spwrite/data/ai/chunker.dart';
import 'package:spwrite/data/ai/semantic_context_retriever.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/domain/ai/context_retriever.dart';
import 'package:spwrite/domain/ai/embedding_model.dart';
import 'package:spwrite/domain/project.dart';

/// The embedding dimension used throughout. Only the first two axes carry the
/// `(cos θ, sin θ)` signal; the rest are zero padding so the stored/query
/// vectors share the retriever's expected `dimension`.
const int _dim = 8;

/// The catalog-style id stored rows and the fake model share, so no row is ever
/// skipped as a model/dimension mismatch — the floor is the only filter under
/// test.
const String _modelId = 'bge-small-en-v1.5';

/// A pool of angles (radians) whose cosines span the whole `[-1, 1]` range with
/// exact, distinct values. The query sits on the x-axis (angle 0), so a chunk at
/// angle θ scores exactly `cos θ`:
///   0       → cos 0    = 1.0
///   π/3     → cos π/3  = 0.5
///   π/2     → cos π/2  = 0.0
///   2π/3    → cos 2π/3 = -0.5
///   π       → cos π    = -1.0
///   π/6     → cos π/6  ≈ 0.866
///   π/4     → cos π/4  ≈ 0.707
/// Values above and below any tested floor both appear, so a generated case can
/// have all/some/none of its chunks clear the floor.
const List<double> _anglePool = <double>[
  0.0,
  math.pi / 6,
  math.pi / 4,
  math.pi / 3,
  math.pi / 2,
  2 * math.pi / 3,
  math.pi,
];

/// The floors to test against, chosen so each falls strictly between adjacent
/// pool cosines (never exactly equal to a chunk score, avoiding a Float32
/// round-trip tie right at the boundary): the `>=` comparison stays unambiguous.
const List<double> _floorPool = <double>[
  0.99, // only the exact x-axis chunk (cos 0 = 1.0) clears it
  0.75, // cos 0 and cos π/6 clear it
  0.25, // all positive-cosine chunks clear it
  -0.25, // adds cos π/2 (0.0)
  -0.75, // adds cos 2π/3 (-0.5)
];

/// A deterministic, offline [EmbeddingModel] that maps a text to a 2-D unit
/// vector `(cos θ, sin θ)` (zero-padded to [_dim]) for a caller-supplied angle,
/// and maps the *query* to the x-axis unit vector. The cosine similarity of a
/// chunk at angle θ to the query is therefore exactly `cos θ`, so scores are
/// known in closed form and the floor's effect is decidable.
class _AngleEmbeddingModel implements EmbeddingModel {
  _AngleEmbeddingModel(this._angleOf);

  /// Maps a raw text to the angle (radians) its stored vector points at. The
  /// query text maps to `0.0` (the x-axis), so its similarity to a chunk at
  /// angle θ is `cos θ`.
  final double Function(String text) _angleOf;

  @override
  int get dimension => _dim;

  @override
  String get modelId => _modelId;

  @override
  Future<void> load() async {}

  @override
  Future<List<double>> embed(String text) async {
    final double theta = _angleOf(text);
    final List<double> v = List<double>.filled(_dim, 0.0);
    v[0] = math.cos(theta);
    v[1] = math.sin(theta);
    return v;
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async =>
      <List<double>>[for (final String t in texts) await embed(t)];

  @override
  Future<void> dispose() async {}
}

/// One generated chunk: its position within a source and the index into
/// [_anglePool] that fixes its exact cosine score against the query.
class _ChunkSpec {
  const _ChunkSpec({required this.chunkIndex, required this.angleIdx});

  final int chunkIndex;
  final int angleIdx;

  double get angle => _anglePool[angleIdx];

  /// The exact cosine similarity this chunk will score against the x-axis query
  /// (before the lossy Float32 store round-trip, which the tolerant assertions
  /// below account for).
  double get score => math.cos(angle);
}

/// A per-chunk unique text marker so a retrieved passage maps back to its spec.
String _labelFor(_ChunkSpec s) => 'chunk#${s.chunkIndex}@a${s.angleIdx}';

void main() {
  setUpAll(() {
    // In-memory FFI factory: the retriever + repository run over a genuine
    // SQLite store without touching disk or a platform DB (matches the other
    // sqlite repository/retriever tests).
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const String projectId = 'p1';
  const String sourceId = 'doc-a';

  /// Seeds the parent project row so the `ai_chunk_embeddings` FK is satisfied
  /// (the FFI factory enables `PRAGMA foreign_keys = ON`).
  Future<void> seedProject(Database db, String id) async {
    await db.insert(
      DatabaseProvider.projectsTable,
      Project.create(id: id, name: 'Project $id', now: DateTime.utc(2024))
          .toRow(),
    );
  }

  /// Writes [specs] into the repository. Each chunk's stored vector is the
  /// `(cos θ, sin θ)` unit vector for its angle; its text is a unique marker so
  /// a returned passage can be traced back to its spec.
  Future<void> seedChunks(
    ChunkEmbeddingRepository repo,
    List<_ChunkSpec> specs,
  ) async {
    final List<EmbeddedChunk> embedded = <EmbeddedChunk>[
      for (final _ChunkSpec s in specs)
        EmbeddedChunk(
          chunk: SourceChunk(
            id: DocumentChunker.chunkId(sourceId, s.chunkIndex),
            sourceId: sourceId,
            sourceType: ChunkSourceType.document,
            sourceTitle: 'Title $sourceId',
            chunkIndex: s.chunkIndex,
            text: _labelFor(s),
            contentHash: DocumentChunker.contentHashOf(_labelFor(s)),
          ),
          // The stored vector points at the chunk's own angle, so its cosine
          // against the x-axis query is exactly cos(angle) = the chunk's score.
          vector: <double>[
            math.cos(s.angle),
            math.sin(s.angle),
            for (int i = 2; i < _dim; i++) 0.0,
          ],
        ),
    ];
    await repo.upsertChunks(projectId, embedded, modelId: _modelId, dim: _dim);
  }

  // --- Generators ---------------------------------------------------------

  // A single chunk spec: a chunk index in a small range and an angle-pool index
  // fixing its exact score. Small ranges guarantee that a case mixes chunks
  // above and below a given floor.
  Arbitrary<_ChunkSpec> chunkSpec() => combine2(
        integer(min: 0, max: 5),
        integer(min: 0, max: _anglePool.length - 1),
      ).map((r) => _ChunkSpec(chunkIndex: r.$1, angleIdx: r.$2));

  // A project's chunks, deduplicated by chunk index (the repository keys rows by
  // the stable id derived from (sourceId, chunkIndex), so two specs sharing an
  // index would upsert in place, not create two rows). Keep the last spec per
  // index to mirror that replace-by-id semantics.
  Arbitrary<List<_ChunkSpec>> chunks() =>
      list(chunkSpec(), minLength: 1, maxLength: 10)
          .map((List<_ChunkSpec> raw) {
        final Map<int, _ChunkSpec> byIndex = <int, _ChunkSpec>{};
        for (final _ChunkSpec s in raw) {
          byIndex[s.chunkIndex] = s;
        }
        return byIndex.values.toList();
      });

  group('SemanticContextRetriever relevance floor — Property 6 (Req 5.5)', () {
    property(
        'every returned passage scores >= minSimilarity; below-floor chunks '
        'never appear; empty when nothing clears the floor', () {
      forAll(
        combine3(
          chunks(),
          integer(min: 0, max: _floorPool.length - 1),
          // A topN large enough that most cases are decided by the floor, not
          // the cap; a few cases will still exceed it, exercising the cap too.
          integer(min: 1, max: 12),
        ),
        ((List<_ChunkSpec>, int, int) r) async {
          final List<_ChunkSpec> specs = r.$1;
          final double floor = _floorPool[r.$2];
          final int topN = r.$3;

          final Database db = await DatabaseProvider.openAppDatabase(
            overridePath: inMemoryDatabasePath,
          );
          try {
            final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
            await seedProject(db, projectId);
            await seedChunks(repo, specs);

            final SemanticContextRetriever retriever =
                SemanticContextRetriever(
              embeddingModel: _AngleEmbeddingModel((_) => 0.0),
              embeddings: repo,
              projectId: projectId,
              topN: topN,
              minSimilarity: floor,
            );

            final List<RetrievedPassage> got = await retriever.retrieve('query');

            // Facet 1: every returned passage clears the floor. Allow a tiny
            // tolerance for the Float32 store round-trip so a score that equals
            // the floor exactly is not rejected by sub-ULP drift; the floor pool
            // is chosen to never coincide with a chunk score, so this only
            // absorbs rounding, not a real boundary case.
            const double eps = 1e-6;
            for (final RetrievedPassage p in got) {
              expect(
                p.score,
                greaterThanOrEqualTo(floor - eps),
                reason: 'returned passage "${p.text}" scored ${p.score} < '
                    'floor $floor',
              );
            }

            // Ground truth: the chunks that should be eligible are exactly those
            // whose exact cosine is at/above the floor.
            final List<_ChunkSpec> eligible = specs
                .where((_ChunkSpec s) => s.score >= floor)
                .toList()
              ..sort((_ChunkSpec a, _ChunkSpec b) {
                // Retriever order: descending score, then (sourceId, chunkIndex)
                // — sourceId is constant here, so chunkIndex ascending.
                final int byScore = b.score.compareTo(a.score);
                if (byScore != 0) return byScore;
                return a.chunkIndex.compareTo(b.chunkIndex);
              });

            final Set<String> returnedTexts =
                got.map((RetrievedPassage p) => p.text).toSet();
            final Set<String> belowFloorTexts = specs
                .where((_ChunkSpec s) => s.score < floor)
                .map(_labelFor)
                .toSet();

            // Facet 2a: no below-floor chunk ever appears.
            for (final String t in belowFloorTexts) {
              expect(
                returnedTexts.contains(t),
                isFalse,
                reason: 'below-floor chunk "$t" (score < $floor) leaked into '
                    'the results',
              );
            }

            // Facet 2b: the results are exactly the top-`topN` eligible chunks,
            // in order — the floor admits every eligible chunk not trimmed by
            // the cap, and nothing else.
            final List<String> expectedTexts = <String>[
              for (final _ChunkSpec s in eligible.take(topN)) _labelFor(s),
            ];
            expect(
              got.map((RetrievedPassage p) => p.text).toList(),
              expectedTexts,
              reason: 'floor $floor / topN $topN should admit exactly the '
                  'top-$topN eligible chunks in descending-score order',
            );

            // Facet 3: when nothing clears the floor, retrieve is empty.
            if (eligible.isEmpty) {
              expect(
                got,
                isEmpty,
                reason: 'no chunk clears floor $floor, so retrieve must be '
                    'empty (never padded with weak matches)',
              );
            }
          } finally {
            await db.close();
          }
        },
        maxExamples: 100,
      );
    });
  });

  group('SemanticContextRetriever relevance floor — concrete cases (Req 5.5)',
      () {
    test('a chunk exactly at the floor is admitted; one just below is dropped',
        () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, projectId);

        // One chunk on the x-axis (score 1.0), one orthogonal (score 0.0).
        await seedChunks(repo, <_ChunkSpec>[
          const _ChunkSpec(chunkIndex: 0, angleIdx: 0), // cos 0   = 1.0
          const _ChunkSpec(chunkIndex: 1, angleIdx: 4), // cos π/2 = 0.0
        ]);

        // Floor at 0.5: only the 1.0 chunk clears it.
        final SemanticContextRetriever retriever = SemanticContextRetriever(
          embeddingModel: _AngleEmbeddingModel((_) => 0.0),
          embeddings: repo,
          projectId: projectId,
          topN: 10,
          minSimilarity: 0.5,
        );

        final List<RetrievedPassage> got = await retriever.retrieve('query');
        expect(got, hasLength(1));
        expect(got.single.text, 'chunk#0@a0');
        expect(got.single.score, greaterThanOrEqualTo(0.5));
      } finally {
        await db.close();
      }
    });

    test('retrieve is empty when every chunk scores below the floor', () async {
      final Database db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      try {
        final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
        await seedProject(db, projectId);

        // All chunks orthogonal or opposite to the query (scores 0.0 and -0.5).
        await seedChunks(repo, <_ChunkSpec>[
          const _ChunkSpec(chunkIndex: 0, angleIdx: 4), // cos π/2  = 0.0
          const _ChunkSpec(chunkIndex: 1, angleIdx: 5), // cos 2π/3 = -0.5
        ]);

        // A floor above every chunk's score: nothing survives.
        final SemanticContextRetriever retriever = SemanticContextRetriever(
          embeddingModel: _AngleEmbeddingModel((_) => 0.0),
          embeddings: repo,
          projectId: projectId,
          topN: 10,
          minSimilarity: 0.25,
        );

        final List<RetrievedPassage> got = await retriever.retrieve('query');
        expect(got, isEmpty);
      } finally {
        await db.close();
      }
    });
  });
}
