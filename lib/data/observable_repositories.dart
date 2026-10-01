/// Data layer: change-observable decorators over [DocumentRepository] and
/// [CharacterRepository] (feature 3.6, task 16.3; Req 4.6, 10.3).
///
/// The SQLite repositories emit no change notifications, and the editor /
/// character panel must stay unaware of the AI feature (Req 4.6). These
/// decorators resolve design open question 4 ("save-event hook mechanism"): the
/// composition root wraps the shared repositories once, hands the wrapped
/// instances to the workspace / character panel exactly as before, and the
/// per-project indexing binding subscribes to [changes]. Callers of the
/// repository interface see no behavioural difference.
///
/// A change is emitted only **after** the delegate call succeeds, so a failed
/// write never triggers reindexing of content that was not persisted. Pure
/// reordering ([DocumentRepository.updatePositions]) changes no indexed text
/// and is not reported.
library;

import 'dart:async';

import '../domain/character.dart';
import '../domain/character_repository.dart';
import '../domain/document.dart';
import '../domain/document_repository.dart';

/// What happened to a persisted source.
enum RepositoryChangeKind {
  /// A new source was inserted ([source] is the persisted entity).
  added,

  /// An existing source's content/metadata was persisted ([source] is the
  /// updated entity).
  updated,

  /// The source identified by [RepositoryChange.sourceId] was deleted
  /// ([RepositoryChange.source] is `null`).
  removed,
}

/// A single persisted change to a [Document] or [Character].
class RepositoryChange {
  /// What happened.
  final RepositoryChangeKind kind;

  /// The id of the affected source.
  final String sourceId;

  /// The persisted entity for [RepositoryChangeKind.added] /
  /// [RepositoryChangeKind.updated]; `null` for [RepositoryChangeKind.removed]
  /// (the row is already gone).
  final Object? source;

  const RepositoryChange._(this.kind, this.sourceId, this.source);

  /// A source was inserted.
  factory RepositoryChange.added(String id, Object source) =>
      RepositoryChange._(RepositoryChangeKind.added, id, source);

  /// A source was updated.
  factory RepositoryChange.updated(String id, Object source) =>
      RepositoryChange._(RepositoryChangeKind.updated, id, source);

  /// A source was deleted.
  factory RepositoryChange.removed(String id) =>
      RepositoryChange._(RepositoryChangeKind.removed, id, null);
}

/// A [DocumentRepository] that forwards every call to [_delegate] and reports
/// successful create / update / delete calls on [changes].
class ObservableDocumentRepository implements DocumentRepository {
  final DocumentRepository _delegate;
  final StreamController<RepositoryChange> _changes =
      StreamController<RepositoryChange>.broadcast(sync: false);

  ObservableDocumentRepository(this._delegate);

  /// Broadcast stream of persisted document changes, across all projects.
  /// Subscribers filter by project.
  Stream<RepositoryChange> get changes => _changes.stream;

  @override
  Future<List<Document>> getByProject(String projectId) =>
      _delegate.getByProject(projectId);

  @override
  Future<List<Document>> getByContainer(String projectId, String? folderId) =>
      _delegate.getByContainer(projectId, folderId);

  @override
  Future<Document?> getById(String id) => _delegate.getById(id);

  @override
  Future<Document> create(Document doc) async {
    final Document created = await _delegate.create(doc);
    _emit(RepositoryChange.added(created.id, created));
    return created;
  }

  @override
  Future<void> update(Document doc) async {
    await _delegate.update(doc);
    _emit(RepositoryChange.updated(doc.id, doc));
  }

  @override
  Future<void> updatePositions(List<Document> documents) =>
      _delegate.updatePositions(documents);

  @override
  Future<void> delete(String id) async {
    await _delegate.delete(id);
    _emit(RepositoryChange.removed(id));
  }

  void _emit(RepositoryChange change) {
    if (!_changes.isClosed) _changes.add(change);
  }

  /// Closes [changes]. Only the owner (the composition root) calls this.
  Future<void> close() => _changes.close();
}

/// A [CharacterRepository] that forwards every call to [_delegate] and reports
/// successful create / update / delete calls on [changes].
class ObservableCharacterRepository implements CharacterRepository {
  final CharacterRepository _delegate;
  final StreamController<RepositoryChange> _changes =
      StreamController<RepositoryChange>.broadcast(sync: false);

  ObservableCharacterRepository(this._delegate);

  /// Broadcast stream of persisted character changes, across all projects.
  /// Subscribers filter by project.
  Stream<RepositoryChange> get changes => _changes.stream;

  @override
  Future<List<Character>> getAllForProject(String projectId) =>
      _delegate.getAllForProject(projectId);

  @override
  Future<Character?> getById(String id) => _delegate.getById(id);

  @override
  Future<Character> create(Character character) async {
    final Character created = await _delegate.create(character);
    _emit(RepositoryChange.added(created.id, created));
    return created;
  }

  @override
  Future<void> update(Character character) async {
    await _delegate.update(character);
    _emit(RepositoryChange.updated(character.id, character));
  }

  @override
  Future<void> delete(String id) async {
    await _delegate.delete(id);
    _emit(RepositoryChange.removed(id));
  }

  void _emit(RepositoryChange change) {
    if (!_changes.isClosed) _changes.add(change);
  }

  /// Closes [changes]. Only the owner (the composition root) calls this.
  Future<void> close() => _changes.close();
}
