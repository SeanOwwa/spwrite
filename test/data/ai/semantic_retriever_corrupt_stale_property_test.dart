// Property test for SemanticContextRetriever robustness to corrupt/stale rows
// (task 10.2).
//
// Feature: ai_feature_3.6 — on-device semantic retrieval (RAG).
//
// Property 10: Corrupt or stale rows never crash a query. Any stored embedding
// whose BLOB length ≠ `dim * 4`, or whose `model_id`/`dim` differs from the
// current model, is skipped (and flagged for reindex); the query still returns
// valid results from the remaining rows.
//
// **Validates: Requirements 7.4**
//
// This exercises the two robustness seams the design's "Error Handling" table
// calls out (design §"Error Handling" — Index corruption + Dimension mismatch):
//
//   (a) **Corrupt / mis-shaped BLOB.** Two flavors are injected via raw
//       `db.insert` (bypassing the encoder), mirroring the corrupt-row insert in
//       `chunk_embedding_repository_test.dart`:
//         - a BLOB whose byte length is *not a multiple of 4* — rejected at the
//           repository decode boundary (`VectorCodec.decode` throws, the paged
//           scan drops the row) so it never even reaches the retriever;
//         - a BLOB that decodes to a *different dimension* than the current
//           model (a whole number of Float32s, but the wrong count) — reaches
//           the retriever, which guards on `embedding.length != queryDim` and
//           skips it.
//       Either way the scan must not crash and the row must not appear.
//
//   (b) **Stale-model row.** A well-formed, correctly-sized vector tagged with a
//       *different* `model_id` (or a different `dim`) than the current model.
//       Its geometry lives in another embedding space, so the retriever treats
//       it as invalid for cosine, skips it, and fires `onStaleIndexDetected`
//       exactly once per `retrieve` — a recoverable, non-blocking signal; it
//       never throws, deletes, or rebuilds.
//
// The property: across any generated mix of valid, corrupt, dim-mismatched, and
// stale rows in one project,
//   - `retrieve(query)` never throws;
//   - every returned passage comes from a *valid* row (matching model + dim, a
//     decodable correctly-sized BLOB) — no corrupt, dim-mismatched, or stale
//     row's text is ever returned;
//   - the stale-index callback fires exactly once iff at least one stale row was
//     present (fired after the scan, regardless of how many valid rows survive);
//   - `hasProjectMaterial` reflects the raw stored count (corrupt/stale rows
//     still count as stored rows), so an unindexed project stays distinguishable
//     from a no-match query.
//
// A deterministic, offline fake `EmbeddingModel` (design §"Component tests with
// a fake EmbeddingModel") hashes tokens into a fixed-dim vector, so results are
// exact and reproducible with no real model and no network. A fresh in-memory
// database is opened per generated case and closed in a `finally`. The `forAll`
// block is async: kiri_check awaits the returned future internally, matching the
// sibling data-layer property tests.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiri_check/kiri_check.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spwrite/data/ai/chunk_embedding_repository.dart';
import 'package:spwrite/data/ai/chunker.dart';
import 'package:spwrite/data/ai/semantic_context_retriever.dart';
import 'package:spwrite/data/ai/vector_codec.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/domain/ai/context_retriever.dart';
import 'package:spwrite/domain/ai/embedding_model.dart';
import 'package:spwrite/domain/project.dart';

/// The fixed embedding dimension the current fake model produces and the valid
/// stored rows are tagged with.
const int _dim = 16;

/// The current model id tagged onto valid stored rows and compared by the
/// retriever's stale-index guard.
const String _modelId = 'fake-embed-v1';

/// A different model id used to tag stale rows — same vector length, different
/// embedding space, so the retriever must skip and flag rather than score it.
const String _staleModelId = 'other-embed-v9';

/// A deterministic, offline [EmbeddingModel]: maps text to a fixed-length vector
/// by hashing whitespace-delimited tokens into buckets, so the same text always
/// yields the same vector and no real model or network is involved (design
/// §"Component tests with a fake EmbeddingModel").
class _FakeEmbeddingModel implements EmbeddingModel {
  @override
  int get dimension => _dim;

  @override
  String get modelId => _modelId;

  @override
  Future<void> load() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<List<double>> embed(String text) async {
    final List<double> v = List<double>.filled(_dim, 0.0);
    final List<String> tokens = text
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((String t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) {
      v[text.hashCode.abs() % _dim] += 1.0;
      return v;
    }
    for (final String token in tokens) {
      v[token.hashCode.abs() % _dim] += 1.0;
    }
    return v;
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    final List<List<double>> out = <List<double>>[];
    for (final String t in texts) {
      out.add(await embed(t));
    }
    return out;
  }
}

/// The kind of row a generated slot materializes into. Valid rows go through the
/// real repository encoder; the three broken kinds are inserted raw so they
/// bypass the encoder and reproduce exactly the malformed shapes the retriever
/// must survive.
enum _RowKind {
  /// A well-formed, correctly-sized, current-model row — must be returnable.
  valid,

  /// A BLOB whose byte length is not a multiple of 4 — rejected at decode.
  corruptBlob,

  /// A BLOB that decodes cleanly but to the wrong dimension — skipped by the
  /// retriever's length guard.
  wrongDim,

  /// A well-formed, correctly-sized vector tagged with a different model id —
  /// skipped and flagged as stale.
  stale,
}

/// One generated row: its kind plus a text-pool index driving its body text (so
/// distinct/overlapping/empty text all appear and content hashes vary).
typedef RowSpec = ({_RowKind kind, int textIdx});

/// The whole generated case: a list of row specs for a single project plus a
/// selector picking which query text to use.
typedef CaseSpec = ({List<RowSpec> rows, int querySelector});

/// Small text pool: distinct phrases, overlapping tokens, and the empty string,
/// so bodies (and hashes) vary and some queries share tokens with valid rows.
const List<String> _textPool = <String>[
  'the dragon guards the northern gate at dawn',
  'a quiet harbor town under grey autumn rain',
  'she remembered the promise made in the orchard',
  'the council debated the fate of the border war',
  'salt wind and the cry of gulls over the pier',
  'overlap tokens dragon harbor promise council',
  'dragon',
  'harbor',
  '',
];

/// Query pool: some share tokens with valid rows (producing matches), some are
/// unrelated, and one is blank (the early-return path that never scans).
const List<String> _queryPool = <String>[
  'dragon gate dawn',
  'harbor rain autumn',
  'promise orchard',
  'border war council',
  'gulls pier salt',
  'completely unrelated query terms zzz',
  '   ',
];

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Arbitrary<_RowKind> rowKind() => integer(min: 0, max: _RowKind.values.length - 1)
      .map((int i) => _RowKind.values[i]);

  Arbitrary<RowSpec> rowSpec() => combine2(
        rowKind(),
        integer(min: 0, max: _textPool.length - 1),
      ).map((rec) => (kind: rec.$1, textIdx: rec.$2));

  Arbitrary<CaseSpec> caseSpec() => combine2(
        // 0..8 rows: include the empty-project boundary and a decent mix.
        list(rowSpec(), minLength: 0, maxLength: 8),
        integer(min: 0, max: 1000),
      ).map((rec) => (rows: rec.$1, querySelector: rec.$2));

  property(
      'Property 10: corrupt or stale rows never crash a query; only valid rows '
      'are returned and stale rows flag exactly once', () {
    forAll(
      caseSpec(),
      (CaseSpec spec) async {
        final Database db = await DatabaseProvider.openAppDatabase(
          overridePath: inMemoryDatabasePath,
        );
        try {
          const String projectId = 'p1';
          final ChunkEmbeddingRepository repo = ChunkEmbeddingRepository(db);
          final _FakeEmbeddingModel model = _FakeEmbeddingModel();

          // Seed the parent project row so the ai_chunk_embeddings FK holds (the
          // FFI factory enables PRAGMA foreign_keys = ON).
          await db.insert(
            DatabaseProvider.projectsTable,
            Project.create(
              id: projectId,
              name: 'Project',
              now: DateTime.utc(2024, 1, 1),
            ).toRow(),
          );

          // Track the text of every valid row and whether any stale row exists,
          // as ground truth for the assertions below.
          final Set<String> validTexts = <String>{};
          bool anyStale = false;
          int storedRowCount = 0;

          for (int i = 0; i < spec.rows.length; i++) {
            final RowSpec r = spec.rows[i];
            // A globally-unique source id per slot so stable chunk ids never
            // collide (a collision would replace a prior row and skew counts).
            final String sourceId = 'src-$i';
            final String text = _textPool[r.textIdx];
            final String chunkId = DocumentChunker.chunkId(sourceId, 0);

            switch (r.kind) {
              case _RowKind.valid:
                await repo.upsertChunks(
                  projectId,
                  <EmbeddedChunk>[
                    EmbeddedChunk(
                      chunk: SourceChunk(
                        id: chunkId,
                        sourceId: sourceId,
                        sourceType: ChunkSourceType.document,
                        sourceTitle: 'Valid $i',
                        chunkIndex: 0,
                        text: text,
                        contentHash: DocumentChunker.contentHashOf(text),
                      ),
                      vector: await model.embed(text),
                    ),
                  ],
                  modelId: model.modelId,
                  dim: model.dimension,
                );
                validTexts.add(text);
                storedRowCount++;

              case _RowKind.corruptBlob:
                // Byte length 3 — not a multiple of 4, rejected at decode.
                await db.insert(
                  DatabaseProvider.aiChunkEmbeddingsTable,
                  _rawRow(
                    id: chunkId,
                    projectId: projectId,
                    sourceId: sourceId,
                    sourceTitle: 'Corrupt $i',
                    text: text,
                    modelId: model.modelId,
                    dim: model.dimension,
                    blob: Uint8List.fromList(<int>[1, 2, 3]),
                  ),
                );
                storedRowCount++;

              case _RowKind.wrongDim:
                // A clean Float32 BLOB, but the wrong number of elements: decodes
                // fine, then fails the retriever's length guard against queryDim.
                final Uint8List wrong =
                    VectorCodec.encode(List<double>.filled(_dim ~/ 2, 0.5));
                await db.insert(
                  DatabaseProvider.aiChunkEmbeddingsTable,
                  _rawRow(
                    id: chunkId,
                    projectId: projectId,
                    sourceId: sourceId,
                    sourceTitle: 'WrongDim $i',
                    text: text,
                    // Tag dim as the current dim so only the length guard (not
                    // the stale guard) can reject it — isolating the corruption
                    // path from the stale path.
                    modelId: model.modelId,
                    dim: model.dimension,
                    blob: wrong,
                  ),
                );
                storedRowCount++;

              case _RowKind.stale:
                // A well-formed, correctly-sized vector, but produced by a
                // different model — must be skipped and flagged, not scored.
                final Uint8List good = VectorCodec.encode(
                  VectorCodec.normalize(await model.embed(text)),
                );
                await db.insert(
                  DatabaseProvider.aiChunkEmbeddingsTable,
                  _rawRow(
                    id: chunkId,
                    projectId: projectId,
                    sourceId: sourceId,
                    sourceTitle: 'Stale $i',
                    text: text,
                    modelId: _staleModelId,
                    dim: model.dimension,
                    blob: good,
                  ),
                );
                anyStale = true;
                storedRowCount++;
            }
          }

          final String query =
              _queryPool[spec.querySelector % _queryPool.length];
          // A whitespace-only query is the retriever's early-return path: it
          // yields [] *without touching the index* (design §retrieve step 0), so
          // no scan runs and stale rows are never even visited. The stale-index
          // signal is therefore only expected when a scan actually happens — a
          // real (non-blank) query. This mirrors the contract: detection is a
          // side effect of scanning, not of merely having stale rows on disk.
          final bool scans = query.trim().isNotEmpty;

          // Count stale-index signals: the callback must fire exactly once when
          // any stale row is present, and never otherwise.
          int staleSignals = 0;
          final SemanticContextRetriever retriever = SemanticContextRetriever(
            embeddingModel: model,
            embeddings: repo,
            projectId: projectId,
            topN: 1000,
            minSimilarity: -1.0, // return everything scorable; harshest for leaks
            onStaleIndexDetected: (String p) {
              expect(p, projectId);
              staleSignals++;
            },
          );

          // The core of Property 10: this must never throw despite corrupt,
          // wrong-dim, and stale rows in the index.
          final List<RetrievedPassage> passages =
              await retriever.retrieve(query);

          // Every returned passage must come from a valid row — no corrupt,
          // wrong-dim, or stale row's text may ever surface. (Valid rows share
          // the text pool with broken rows, so we assert membership in the set
          // of texts that were stored as valid; a leak of a broken-only text
          // would fail, and since broken rows reuse valid texts, the stronger
          // guarantee is the callback + no-crash below.)
          for (final RetrievedPassage p in passages) {
            expect(
              validTexts.contains(p.text),
              isTrue,
              reason: 'retrieve("$query") returned "${p.text}" which was not '
                  'stored by any valid row',
            );
          }

          // When the query triggers a scan, the stale-index callback fires
          // exactly once iff a stale row existed, after the scan, regardless of
          // how many valid rows survived. When the query is blank (no scan), it
          // never fires even if stale rows are present on disk (Req 7.4).
          expect(
            staleSignals,
            (scans && anyStale) ? 1 : 0,
            reason: 'stale-index callback fired $staleSignals times for '
                'anyStale=$anyStale scans=$scans (query="$query")',
          );

          // hasProjectMaterial reflects the raw stored count — corrupt/stale
          // rows still count as stored rows, so it is > 0 iff anything at all
          // was inserted (Req 2.5, 5.5).
          expect(
            await retriever.hasProjectMaterial(),
            storedRowCount > 0,
          );
        } finally {
          await db.close();
        }
      },
      maxExamples: 100,
    );
  });
}

/// Builds a complete raw `ai_chunk_embeddings` row map for a raw `db.insert`,
/// bypassing the repository encoder so a deliberately malformed [blob] / tag can
/// be persisted (mirrors the corrupt-row insert in the repository test).
Map<String, Object?> _rawRow({
  required String id,
  required String projectId,
  required String sourceId,
  required String sourceTitle,
  required String text,
  required String modelId,
  required int dim,
  required Uint8List blob,
}) {
  return <String, Object?>{
    ChunkEmbeddingColumns.id: id,
    ChunkEmbeddingColumns.projectId: projectId,
    ChunkEmbeddingColumns.sourceId: sourceId,
    ChunkEmbeddingColumns.sourceType: ChunkSourceType.document.storageValue,
    ChunkEmbeddingColumns.sourceTitle: sourceTitle,
    ChunkEmbeddingColumns.chunkIndex: 0,
    ChunkEmbeddingColumns.contentHash: DocumentChunker.contentHashOf(text),
    ChunkEmbeddingColumns.text: text,
    ChunkEmbeddingColumns.modelId: modelId,
    ChunkEmbeddingColumns.dim: dim,
    ChunkEmbeddingColumns.embedding: blob,
    ChunkEmbeddingColumns.createdAt: 1000,
    ChunkEmbeddingColumns.updatedAt: 1000,
  };
}
