/// State layer: [IndexingBinding], the per-project glue that keeps an
/// [IndexingState] in step with persisted document / character changes
/// (feature 3.6, task 16.3; Req 4.2–4.6, 9.1, 9.2, 10.3).
///
/// The composition root builds one binding per open project, alongside that
/// project's [IndexingState], and disposes it when the project closes. The
/// binding:
///
/// 1. Probes the embedding model's presence on [start] (no network,
///    [IndexingState.prepareEmbeddingModel]) so the AI panel's status strip can
///    show the one-time download prompt or go straight to ready (Req 3.2, 3.7).
/// 2. Kicks off one background full build ([IndexingState.reindex]) as soon as
///    the embedding model is ready — immediately when it is already cached, or
///    right after the user completes the download (Req 9.1, 9.2). The build is
///    incremental and resumable, so reopening a project only re-embeds what
///    changed (Req 4.2, 9.3).
/// 3. Forwards save / add / remove / rename events from the observable
///    repositories to the indexing state as fire-and-forget incremental work,
///    filtered to this project, so the editor never depends on AI (Req 4.6).
///
/// Change events are only forwarded while semantic indexing is usable
/// ([IndexingState.isSemanticReady]): before the embedding model is ready the
/// initial full build will pick everything up anyway, and while the index is in
/// an error state forwarding would only repeat the same failure on every save.
library;

import 'dart:async';

import '../data/observable_repositories.dart';
import '../domain/character.dart';
import '../domain/document.dart';
import 'indexing_state.dart';

/// Connects a project's [IndexingState] to repository change streams and the
/// embedding-model readiness lifecycle. See the library docs.
class IndexingBinding {
  /// The project-scoped indexing state this binding drives. Not owned: the
  /// provider that created it disposes it.
  final IndexingState indexing;

  final Stream<RepositoryChange> _documentChanges;
  final Stream<RepositoryChange> _characterChanges;

  final List<StreamSubscription<RepositoryChange>> _subscriptions =
      <StreamSubscription<RepositoryChange>>[];

  /// Last title seen per document id, so an update whose title changed is
  /// routed through the rename path (which refreshes `source_title` on every
  /// stored row, Req 4.5) while a plain body save takes the cheaper
  /// incremental path. A document not seen yet this session is treated as a
  /// potential rename so its stored titles are refreshed once.
  final Map<String, String> _knownTitles = <String, String>{};

  bool _started = false;
  bool _initialBuildStarted = false;
  bool _disposed = false;

  IndexingBinding({
    required this.indexing,
    required Stream<RepositoryChange> documentChanges,
    required Stream<RepositoryChange> characterChanges,
  })  : _documentChanges = documentChanges,
        _characterChanges = characterChanges;

  /// Subscribes to the change streams and the indexing state, and probes the
  /// embedding model. Idempotent.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _subscriptions
      ..add(_documentChanges.listen(_onDocumentChange))
      ..add(_characterChanges.listen(_onCharacterChange));
    indexing.addListener(_onIndexingChanged);
    unawaited(indexing.prepareEmbeddingModel());
  }

  /// Starts the one-time initial full build once the embedding model becomes
  /// ready (cached on open, or just downloaded).
  void _onIndexingChanged() {
    if (_disposed || _initialBuildStarted) return;
    if (!indexing.embeddingModelReady) return;
    _initialBuildStarted = true;
    indexing.reindex();
  }

  bool get _shouldForward =>
      !_disposed && _initialBuildStarted && indexing.isSemanticReady();

  void _onDocumentChange(RepositoryChange change) {
    if (!_shouldForward) return;
    switch (change.kind) {
      case RepositoryChangeKind.added:
        final Object? source = change.source;
        if (source is! Document || source.projectId != indexing.projectId) {
          return;
        }
        _knownTitles[source.id] = source.title;
        indexing.onSourceAdded(source);
      case RepositoryChangeKind.updated:
        final Object? source = change.source;
        if (source is! Document || source.projectId != indexing.projectId) {
          return;
        }
        final String? previousTitle = _knownTitles[source.id];
        _knownTitles[source.id] = source.title;
        if (previousTitle == source.title) {
          indexing.onDocumentSaved(source);
        } else {
          indexing.onDocumentRenamed(source);
        }
      case RepositoryChangeKind.removed:
        // The row is gone, so its project is unknown; the removal is scoped to
        // this binding's project inside IndexingState, so an id from another
        // project deletes nothing.
        _knownTitles.remove(change.sourceId);
        indexing.onSourceRemoved(change.sourceId);
    }
  }

  void _onCharacterChange(RepositoryChange change) {
    if (!_shouldForward) return;
    switch (change.kind) {
      case RepositoryChangeKind.added:
      case RepositoryChangeKind.updated:
        final Object? source = change.source;
        if (source is! Character || source.projectId != indexing.projectId) {
          return;
        }
        indexing.onSourceAdded(source);
      case RepositoryChangeKind.removed:
        indexing.onSourceRemoved(change.sourceId);
    }
  }

  /// Cancels the stream subscriptions and the indexing listener. Must be
  /// called before [indexing] is disposed. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final StreamSubscription<RepositoryChange> s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
    if (_started) indexing.removeListener(_onIndexingChanged);
  }
}
