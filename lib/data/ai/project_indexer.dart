/// Data layer: the [ProjectIndexer] that keeps a project's on-device vector
/// index in sync with its documents and characters — the write side of the
/// semantic path that the [SemanticContextRetriever] later scans (design §5
/// "ProjectIndexer", Req 4, 9.4).
///
/// The indexer is the one place that turns Active_Project material into stored
/// embeddings. It reads sources through the existing [DocumentRepository] /
/// [CharacterRepository], slices them with the pure [DocumentChunker], embeds
/// the resulting chunk text with the injected [EmbeddingModel]
/// ([EmbeddingModel.embedBatch], so the runtime amortizes overhead across many
/// chunks, Req 4.6), and upserts the vectors through
/// [ChunkEmbeddingRepository]. It is deliberately decoupled from the editor: it
/// exposes plain `onDocumentSaved` / `onSourceAdded` / `onSourceRemoved` /
/// `onDocumentRenamed` signals that the composition root (which already owns the
/// repositories and their save events) drives, so nothing in the editor depends
/// on the AI feature (Req 4.6).
///
/// **Incremental by content hash (Req 4.2).** The expensive step is embedding,
/// so the indexer never re-embeds text that did not change. On a save it
/// re-chunks the source, reads the chunk `content_hash`es already stored for
/// that source via [ChunkEmbeddingRepository.readStoredHashesForSource], and
/// diffs by `chunkIndex`:
///
/// - a chunk whose hash matches the stored hash at the same index is
///   **unchanged** → left untouched (not re-embedded);
/// - a chunk that is new or whose hash changed is **embedded and upserted**;
/// - a stored chunk index that the fresh chunking no longer produces has
///   **vanished** → its row is deleted.
///
/// Because [DocumentChunker] assigns a stable `id` and `content_hash` per
/// `(sourceId, chunkIndex)`, a re-embed updates the existing row in place rather
/// than orphaning it, and repeatedly indexing unchanged content converges to the
/// same stored rows (idempotent). A full [reindexProject] applies the same diff
/// per source, so it is safe to re-run and reports progress as it goes (Req 9.1,
/// 9.6).
///
/// **Add / remove / rename (Req 4.3, 4.4, 4.5).** Adding a source runs the same
/// incremental path (every chunk is new, so all are embedded). Removing a source
/// deletes all of its rows. A rename is metadata-only: the body chunks are
/// unchanged, so their text — and therefore their `content_hash` — does not
/// move; only the `source_title` carried for citation changes. When the title is
/// *itself* embedded as a chunk (the small title chunk the document chunker
/// emits at index 0), that one chunk's text changed, so the incremental diff
/// naturally re-embeds just it while leaving the body untouched. Re-running the
/// incremental path on the renamed document therefore updates the stored
/// `source_title` on every row and re-embeds only the title chunk.
///
/// **Off the UI thread (Req 4.6, 9.4).** The heavy work is the embedding call,
/// which the [EmbeddingModel] runs on its own background isolate; the indexer's
/// own bookkeeping is lightweight async I/O, and per-source work is `await`ed one
/// source at a time so a large project never floods the runtime. Progress is
/// reported through the optional callback so the state layer can surface an
/// "X of Y" indicator without the indexer knowing about the UI (Req 9.1, 9.6).
///
/// **Large documents (Req 4.8).** A document near `maxContentLength` is handled
/// by the chunker, which hard-splits it into bounded windows; the indexer embeds
/// those windows in batches, so a huge document is indexed rather than failing.
///
/// **Resume (Req 9.3).** A first-time build interrupted by app close or a
/// project switch resumes rather than restarts. That is recorded per source in
/// the `ai_index_state` table via the [IndexStateStore] seam this indexer writes
/// through: after a source is fully indexed the indexer marks it `complete` at
/// the source's full content hash, and [reindexProject] consults
/// [IndexStateStore.isComplete] at the start of each source to skip any already
/// `complete` at exactly that hash. The concrete `SqliteIndexStateStore`
/// (`index_state_store.dart`) backs this over the `ai_index_state` table; when
/// the default no-op [IndexStateStore] is injected instead, `isComplete` is
/// always false so the indexer performs a correct full build with no resume.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/character.dart';
import '../../domain/character_repository.dart';
import '../../domain/document.dart';
import '../../domain/document_repository.dart';
import '../../domain/ai/embedding_model.dart';
import 'chunk_embedding_repository.dart';
import 'chunker.dart';

/// Reports incremental indexing progress as `(done, total)` sources while a
/// [ProjectIndexer.reindexProject] build runs, so the state layer can surface an
/// "X of Y" indicator without the indexer depending on the UI (Req 9.1, 9.6).
///
/// [done] is the number of sources fully processed so far and [total] the number
/// of sources in the build; both are non-negative and `done <= total`. It is
/// called once after each source completes (and once at the start with
/// `(0, total)` so a caller can render the total immediately).
typedef IndexProgress = void Function(int done, int total);

/// The lifecycle status of a source's stored index, recorded per source in the
/// `ai_index_state` table so a first-time build interrupted midway can resume
/// rather than restart (Req 9.3).
enum IndexSourceStatus {
  /// The source has been fully chunked, embedded, and upserted at the recorded
  /// `source_hash`; a resume can skip it while that hash is unchanged.
  complete,

  /// The source is mid-build (some chunks embedded, not all) or its recorded
  /// hash predates the current content; a resume must (re)process it.
  partial;

  /// The stored string form persisted in the `ai_index_state.status` column
  /// ('complete' | 'partial').
  String get storageValue => name;
}

/// The seam through which [ProjectIndexer] records and consults per-source
/// resume markers in the `ai_index_state` table (design §"Per-source index
/// state", Req 9.3, 4.2).
///
/// It is split out as its own abstraction so task 12.2 can drop in the concrete
/// SQLite-backed store without touching the indexer's chunk/embed/upsert logic,
/// and so this task's tests can inject a fake. The default [NoopIndexStateStore]
/// makes the indexer perform a correct full build (never skipping a source),
/// which is the safe behaviour until resume is wired in.
abstract class IndexStateStore {
  /// Records that [sourceId] in [projectId] has reached [status] at
  /// [sourceHash] (a hash of the source's full current content) with
  /// [chunkCount] chunks stored, so a later build can decide whether to skip it.
  Future<void> markSource(
    String projectId,
    String sourceId,
    ChunkSourceType sourceType, {
    required String sourceHash,
    required int chunkCount,
    required IndexSourceStatus status,
  });

  /// Removes any resume marker for [sourceId] in [projectId] (e.g. when the
  /// source was deleted), so a stale marker never masks a re-add.
  Future<void> clearSource(String projectId, String sourceId);

  /// Returns whether [sourceId] in [projectId] is already recorded as
  /// [IndexSourceStatus.complete] at exactly [sourceHash], meaning a resuming
  /// build may skip re-processing it. Returns `false` when unknown, partial, or
  /// recorded at a different hash.
  Future<bool> isComplete(String projectId, String sourceId, String sourceHash);
}

/// A no-op [IndexStateStore] that records nothing and reports every source as
/// not-complete, so [ProjectIndexer] performs a full, correct build without
/// resume. It is the default until task 12.2 supplies the SQLite-backed store.
class NoopIndexStateStore implements IndexStateStore {
  const NoopIndexStateStore();

  @override
  Future<void> markSource(
    String projectId,
    String sourceId,
    ChunkSourceType sourceType, {
    required String sourceHash,
    required int chunkCount,
    required IndexSourceStatus status,
  }) async {}

  @override
  Future<void> clearSource(String projectId, String sourceId) async {}

  @override
  Future<bool> isComplete(
    String projectId,
    String sourceId,
    String sourceHash,
  ) async =>
      false;
}

/// Keeps a project's on-device vector index in sync with its documents and
/// characters by chunking, embedding only what changed, and upserting through
/// [ChunkEmbeddingRepository] (Req 4, 9.4).
///
/// The indexer owns no database or embedding lifecycle: it operates on an
/// injected [EmbeddingModel] (which it [EmbeddingModel.load]s lazily before the
/// first embed) and the repositories/store handed to it, so the composition root
/// controls their lifetime. All methods are safe to `await` from a background
/// task; the heavy embedding work runs off the UI thread inside the model.
class ProjectIndexer {
  /// The embedding runtime used to turn chunk text into vectors (Req 4.6). Only
  /// changed/new chunks are embedded; unchanged chunks reuse their stored vector.
  final EmbeddingModel _embeddingModel;

  /// The project-scoped vector index this indexer writes to (Req 4.7).
  final ChunkEmbeddingRepository _embeddings;

  /// Reads the project's documents to (re)index them (Req 4.1).
  final DocumentRepository _documents;

  /// Reads the project's characters to (re)index them (Req 4.1).
  final CharacterRepository _characters;

  /// The pure chunker that slices sources into bounded, hashable chunks
  /// (Req 4.1, 4.8).
  final DocumentChunker _chunker;

  /// Records/consults per-source resume markers (Req 9.3). Defaults to a no-op
  /// store so the indexer performs a correct full build until task 12.2 wires in
  /// the SQLite-backed store.
  final IndexStateStore _indexState;

  /// How many chunk texts are embedded per [EmbeddingModel.embedBatch] call, so
  /// a very large source is embedded in bounded windows rather than one giant
  /// call (Req 4.8). Chosen small enough to bound peak memory yet large enough to
  /// amortize per-call overhead (Req 4.6).
  static const int embedBatchSize = 32;

  /// Whether [_embeddingModel] has been loaded during this indexer's lifetime,
  /// so [load] is called at most once lazily before the first embed.
  bool _modelLoaded = false;

  /// Creates an indexer over [embeddingModel], the project-scoped [embeddings]
  /// index, and the [documents] / [characters] repositories.
  ///
  /// [chunker] defaults to a plain [DocumentChunker] (it is pure and stateless);
  /// [indexState] defaults to a [NoopIndexStateStore] so the indexer performs a
  /// full build with no resume until task 12.2 provides the concrete store.
  ProjectIndexer({
    required EmbeddingModel embeddingModel,
    required ChunkEmbeddingRepository embeddings,
    required DocumentRepository documents,
    required CharacterRepository characters,
    DocumentChunker chunker = const DocumentChunker(),
    IndexStateStore indexState = const NoopIndexStateStore(),
  })  : _embeddingModel = embeddingModel,
        _embeddings = embeddings,
        _documents = documents,
        _characters = characters,
        _chunker = chunker,
        _indexState = indexState;

  /// Builds (or brings up to date) the whole index for [projectId], processing
  /// every document and character and reporting progress as it goes (Req 4.1,
  /// 9.1, 9.2, 9.6).
  ///
  /// Each source is run through the same incremental diff as an individual save,
  /// so a re-run only re-embeds content that actually changed and the build is
  /// idempotent: running it twice over unchanged content leaves the stored rows
  /// identical. Sources already recorded [IndexSourceStatus.complete] at their
  /// current content hash are skipped, so an interrupted first-time build
  /// resumes rather than restarts once task 12.2 supplies a real
  /// [IndexStateStore] (Req 9.3); with the default no-op store every source is
  /// processed.
  ///
  /// [onProgress] (when given) is called once at the start with `(0, total)` and
  /// once after each source completes, where `total` is the number of documents
  /// plus characters in the project. Work is `await`ed one source at a time so
  /// the embedding runtime is never flooded and the UI stays responsive
  /// (Req 4.6, 9.4).
  Future<void> reindexProject(
    String projectId, {
    IndexProgress? onProgress,
  }) async {
    final List<Document> docs = await _documents.getByProject(projectId);
    final List<Character> chars =
        await _characters.getAllForProject(projectId);

    final int total = docs.length + chars.length;
    int done = 0;
    onProgress?.call(done, total);

    for (final Document doc in docs) {
      final String sourceHash = _sourceHashForDocument(doc);
      // Resume: skip a source already fully indexed at exactly this content
      // hash so a first-time build interrupted by app close or a project switch
      // continues from where it stopped rather than re-embedding everything
      // (Req 9.3). With the default no-op store this is always false, so every
      // source is processed.
      if (await _indexState.isComplete(projectId, doc.id, sourceHash)) {
        done++;
        onProgress?.call(done, total);
        continue;
      }
      final List<SourceChunk> chunks = _chunker.chunkDocument(doc);
      await _syncSource(
        projectId: projectId,
        sourceId: doc.id,
        sourceType: ChunkSourceType.document,
        sourceHash: sourceHash,
        chunks: chunks,
      );
      done++;
      onProgress?.call(done, total);
    }

    for (final Character character in chars) {
      final String sourceHash = _sourceHashForCharacter(character);
      // Resume: skip a character already fully indexed at exactly this content
      // hash (Req 9.3).
      if (await _indexState.isComplete(projectId, character.id, sourceHash)) {
        done++;
        onProgress?.call(done, total);
        continue;
      }
      final List<SourceChunk> chunks = _chunker.chunkCharacter(character);
      await _syncSource(
        projectId: projectId,
        sourceId: character.id,
        sourceType: ChunkSourceType.character,
        sourceHash: sourceHash,
        chunks: chunks,
      );
      done++;
      onProgress?.call(done, total);
    }
  }

  /// Incrementally reindexes [doc] after a save: re-chunks it, embeds only the
  /// chunks whose `content_hash` changed (or that are new), deletes chunks that
  /// vanished, and leaves unchanged chunks untouched (Req 4.2).
  ///
  /// This is the hot path invoked on every document save. It never re-embeds
  /// unchanged passages, so saving a large document after a small edit costs a
  /// single embed of the affected chunk(s) rather than the whole file.
  Future<void> onDocumentSaved(Document doc) async {
    final List<SourceChunk> chunks = _chunker.chunkDocument(doc);
    await _syncSource(
      projectId: doc.projectId,
      sourceId: doc.id,
      sourceType: ChunkSourceType.document,
      sourceHash: _sourceHashForDocument(doc),
      chunks: chunks,
    );
  }

  /// Indexes a newly added [source] (a [Document] or [Character]) by embedding
  /// and upserting all of its chunks (Req 4.3).
  ///
  /// A new source has no stored chunks, so the incremental diff treats every
  /// chunk as new and embeds it. Throws [ArgumentError] if [source] is neither a
  /// [Document] nor a [Character].
  Future<void> onSourceAdded(Object source) async {
    if (source is Document) {
      await onDocumentSaved(source);
      return;
    }
    if (source is Character) {
      await onCharacterSaved(source);
      return;
    }
    throw ArgumentError.value(
      source,
      'source',
      'must be a Document or a Character',
    );
  }

  /// Incrementally reindexes [character] after a save/add: re-chunks it and
  /// embeds only what changed, exactly as [onDocumentSaved] does for documents
  /// (Req 4.2, 4.3).
  Future<void> onCharacterSaved(Character character) async {
    final List<SourceChunk> chunks = _chunker.chunkCharacter(character);
    await _syncSource(
      projectId: character.projectId,
      sourceId: character.id,
      sourceType: ChunkSourceType.character,
      sourceHash: _sourceHashForCharacter(character),
      chunks: chunks,
    );
  }

  /// Removes every stored chunk of [sourceId] within [projectId] from the index
  /// and clears its resume marker (Req 4.4).
  ///
  /// Used when a document or character is deleted. Scoped to the project so it
  /// can never remove another project's rows.
  Future<void> onSourceRemoved(String projectId, String sourceId) async {
    await _embeddings.deleteBySource(projectId, sourceId);
    await _indexState.clearSource(projectId, sourceId);
  }

  /// Applies a document rename to the index: updates the `source_title` carried
  /// on the document's stored rows for citation, re-embedding only the small
  /// title chunk (not the unchanged body) (Req 4.5).
  ///
  /// A rename does not change any body chunk's text, so those chunks keep their
  /// `content_hash` and are left untouched by the incremental diff; only the
  /// title chunk's text changed, so exactly that one chunk is re-embedded. The
  /// caller passes the already-renamed [document] (its [Document.title] is the
  /// new title); this first refreshes the stored `source_title` on every one of
  /// the document's rows (a metadata-only update that re-embeds nothing), then
  /// re-runs the incremental path, which re-embeds just the changed title chunk
  /// while leaving the unchanged body chunks untouched.
  Future<void> onDocumentRenamed(Document document) async {
    final String rawTitle = document.title.trim();
    final String sourceTitle =
        rawTitle.isEmpty ? 'Untitled document' : rawTitle;
    // Metadata-only refresh across all stored rows for citation (Req 4.5); the
    // body chunks' embeddings are not touched.
    await _embeddings.updateSourceTitle(
      document.projectId,
      document.id,
      sourceTitle,
    );
    // Re-embed only the title chunk (its text changed) via the incremental
    // diff; body chunks keep their content hash and are left untouched.
    await onDocumentSaved(document);
  }

  /// The core incremental sync for one source: diff the freshly produced
  /// [chunks] against the hashes already stored, embed only new/changed chunks,
  /// delete vanished ones, and leave unchanged chunks untouched (Req 4.2, 4.4).
  ///
  /// The diff keys on [SourceChunk.chunkIndex]: a fresh chunk whose
  /// `content_hash` equals the stored hash at the same index is unchanged; any
  /// other fresh chunk (new index, or changed hash) is embedded; a stored index
  /// with no corresponding fresh chunk has vanished and its row is deleted. When
  /// the source produced no chunks at all (e.g. an emptied document), every
  /// stored row is removed. Resume markers bracket the work: the source is marked
  /// [IndexSourceStatus.partial] before embedding begins and
  /// [IndexSourceStatus.complete] once every changed chunk is upserted, so an
  /// interruption leaves a resumable marker (Req 9.3).
  Future<void> _syncSource({
    required String projectId,
    required String sourceId,
    required ChunkSourceType sourceType,
    required String sourceHash,
    required List<SourceChunk> chunks,
  }) async {
    // A source that yields no chunks (blank document/character) should have no
    // stored rows: delete any that remain and clear its marker.
    if (chunks.isEmpty) {
      await _embeddings.deleteBySource(projectId, sourceId);
      await _indexState.clearSource(projectId, sourceId);
      return;
    }

    // Stored per-chunk hashes for this source, keyed by chunk index, so the diff
    // is O(chunks) rather than O(chunks^2) (Req 4.2).
    final List<StoredChunkHash> storedHashes =
        await _embeddings.readStoredHashesForSource(projectId, sourceId);
    final Map<int, String> hashByIndex = <int, String>{
      for (final StoredChunkHash h in storedHashes) h.chunkIndex: h.contentHash,
    };

    // Partition the fresh chunks: those whose text changed (or are new) must be
    // embedded; those whose hash matches the stored hash at the same index are
    // left untouched (never re-embedded).
    final List<SourceChunk> changed = <SourceChunk>[];
    for (final SourceChunk chunk in chunks) {
      final String? storedHash = hashByIndex[chunk.chunkIndex];
      if (storedHash != chunk.contentHash) {
        changed.add(chunk);
      }
    }

    // Any stored chunk index the fresh chunking no longer produces has vanished
    // (e.g. the source got shorter) — its row must be deleted so the index does
    // not retain stale passages (Req 4.4).
    final Set<int> freshIndices = <int>{
      for (final SourceChunk chunk in chunks) chunk.chunkIndex,
    };
    final List<String> vanishedIds = <String>[
      for (final StoredChunkHash h in storedHashes)
        if (!freshIndices.contains(h.chunkIndex)) h.id,
    ];

    // Nothing to embed and nothing to delete: the stored rows already match the
    // fresh chunking exactly, so this is a no-op re-index (idempotent, Req 4.2).
    // Still refresh the resume marker so its hash tracks the current content.
    if (changed.isEmpty && vanishedIds.isEmpty) {
      await _indexState.markSource(
        projectId,
        sourceId,
        sourceType,
        sourceHash: sourceHash,
        chunkCount: chunks.length,
        status: IndexSourceStatus.complete,
      );
      return;
    }

    // Mark the source partial before any embedding begins so an interruption
    // mid-embed leaves a resumable marker rather than a false "complete"
    // (Req 9.3). Recorded with the current chunk count for observability.
    await _indexState.markSource(
      projectId,
      sourceId,
      sourceType,
      sourceHash: sourceHash,
      chunkCount: chunks.length,
      status: IndexSourceStatus.partial,
    );

    // Delete vanished rows first so a source that shrank never leaves stale
    // high-index chunks behind, then embed and upsert the changed/new chunks.
    for (final String id in vanishedIds) {
      await _embeddings.deleteChunkById(projectId, id);
    }

    if (changed.isNotEmpty) {
      final List<EmbeddedChunk> embedded = await _embedChunks(changed);
      await _embeddings.upsertChunks(
        projectId,
        embedded,
        modelId: _embeddingModel.modelId,
        dim: _embeddingModel.dimension,
      );
    }

    // Every changed chunk is now stored and vanished rows are gone, so the
    // source is fully indexed at this content hash (Req 9.3, 9.6).
    await _indexState.markSource(
      projectId,
      sourceId,
      sourceType,
      sourceHash: sourceHash,
      chunkCount: chunks.length,
      status: IndexSourceStatus.complete,
    );
  }

  /// Embeds [chunks] in bounded batches via [EmbeddingModel.embedBatch],
  /// pairing each returned vector with its chunk in input order (Req 4.6, 4.8).
  ///
  /// The model is loaded lazily on first use. Batching in windows of
  /// [embedBatchSize] amortizes per-call overhead while bounding peak memory for
  /// a very large source. [EmbeddingModel.embedBatch] preserves order, so the
  /// i-th returned vector corresponds to the i-th input chunk.
  Future<List<EmbeddedChunk>> _embedChunks(List<SourceChunk> chunks) async {
    await _ensureModelLoaded();

    final List<EmbeddedChunk> result = <EmbeddedChunk>[];
    for (int start = 0; start < chunks.length; start += embedBatchSize) {
      final int end = (start + embedBatchSize) < chunks.length
          ? start + embedBatchSize
          : chunks.length;
      final List<SourceChunk> window = chunks.sublist(start, end);
      final List<List<double>> vectors = await _embeddingModel
          .embedBatch(<String>[for (final SourceChunk c in window) c.text]);
      for (int i = 0; i < window.length; i++) {
        result.add(EmbeddedChunk(chunk: window[i], vector: vectors[i]));
      }
    }
    return result;
  }

  /// Loads the embedding model once, lazily, before the first embed (Req 4.6).
  /// A load failure propagates so the caller (the state layer driving the
  /// indexer) can surface a recoverable, non-blocking status (Req 7.4).
  Future<void> _ensureModelLoaded() async {
    if (_modelLoaded) return;
    await _embeddingModel.load();
    _modelLoaded = true;
  }

  /// A hash of a document's full current content (title + body) used as the
  /// per-source resume marker (Req 9.3). Distinct from the per-chunk
  /// `content_hash`: this tracks whether the *source as a whole* changed since it
  /// was last fully indexed, so a resuming build can skip an unchanged source.
  static String _sourceHashForDocument(Document doc) {
    return sha256
        .convert(utf8.encode('${doc.title}\u0000${doc.content}'))
        .toString();
  }

  /// A hash of a character's full current content (name + role + notes) used as
  /// the per-source resume marker (Req 9.3).
  static String _sourceHashForCharacter(Character character) {
    return sha256
        .convert(utf8.encode('${character.name}\u0000${character.role}'
            '\u0000${character.notes}'))
        .toString();
  }
}
