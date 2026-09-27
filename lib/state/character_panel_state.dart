/// State layer: [CharacterPanelState], the single source of truth for the
/// Character Panel of an open project.
///
/// It owns the open project's in-memory, name-ordered list of [Character]s, the
/// list load status, and a transient error message. The presentation layer (the
/// character sidebar and the character edit screen) observes it via `provider`;
/// like the other notifiers, it depends only on the [CharacterRepository]
/// abstraction, never on SQLite directly.
///
/// It is scoped to one project: constructed with the Active_Project's id when a
/// project is opened, and disposed when the project is closed. All mutations
/// (create / update / delete) go to the repository first, then update the
/// in-memory list and re-sort with the shared [compareCharacters] rule so the
/// list and the store agree.
library;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../domain/character.dart';
import '../domain/character_repository.dart';
import 'load_status.dart';

/// The single source of truth the Character Panel observes while a project is
/// open. Owns the project's ordered characters, the load status, and a
/// transient error.
class CharacterPanelState extends ChangeNotifier {
  /// The id of the project whose characters this panel manages.
  final String projectId;

  /// Character persistence abstraction. The state layer talks only to this
  /// interface, keeping it decoupled from SQLite.
  final CharacterRepository _repository;

  /// Generates unique ids for new characters.
  final Uuid _uuid;

  /// The project's characters, kept sorted by the shared [compareCharacters]
  /// rule.
  List<Character> _characters = <Character>[];

  /// Status of the character-list load.
  LoadStatus _status = LoadStatus.idle;

  /// A recoverable message surfaced to the user, or `null` when there is
  /// nothing to show.
  String? _transientError;

  /// Creates the panel state for [projectId] over the [repository]. A [Uuid]
  /// generator may be injected for tests; otherwise the default is used.
  CharacterPanelState(
    this.projectId,
    CharacterRepository repository, {
    Uuid? uuid,
  })  : _repository = repository,
        _uuid = uuid ?? const Uuid();

  /// The project's characters in the shared [compareCharacters] order, as an
  /// unmodifiable view.
  List<Character> get characters => List<Character>.unmodifiable(_characters);

  /// The current load status of the character list.
  LoadStatus get status => _status;

  /// The pending transient error message, or `null`.
  String? get transientError => _transientError;

  /// Whether the project currently has zero characters.
  bool get isEmpty => _characters.isEmpty;

  /// Clears the transient error so it is not shown again on the next rebuild.
  void clearTransientError() {
    if (_transientError == null) return;
    _transientError = null;
    notifyListeners();
  }

  /// Loads the project's characters from the store. On success the ordered list
  /// replaces the in-memory one; on failure the previously displayed list is
  /// retained and a transient error is surfaced.
  Future<void> load() async {
    _status = LoadStatus.loading;
    notifyListeners();
    try {
      final List<Character> loaded =
          await _repository.getAllForProject(projectId);
      _characters = List<Character>.of(loaded)..sort(compareCharacters);
      _status = LoadStatus.loaded;
      _transientError = null;
    } catch (_) {
      _status = LoadStatus.error;
      _transientError = 'Characters could not be loaded.';
    }
    notifyListeners();
  }

  /// Creates a new, empty character in this project, persists it, inserts it
  /// into the in-memory list, and returns it (so the caller can open it for
  /// editing). On failure a transient error is surfaced and `null` is returned.
  Future<Character?> createCharacter() async {
    final DateTime now = DateTime.now().toUtc();
    final Character character = Character.newCharacter(
      id: _uuid.v4(),
      projectId: projectId,
      now: now,
    );
    try {
      final Character created = await _repository.create(character);
      _characters = List<Character>.of(<Character>[..._characters, created])
        ..sort(compareCharacters);
      _transientError = null;
      notifyListeners();
      return created;
    } catch (_) {
      _transientError = 'The character could not be created.';
      notifyListeners();
      return null;
    }
  }

  /// Persists edited [character] fields (name, role, notes/details, image),
  /// advancing its last-modified timestamp, then updates and re-sorts the
  /// in-memory list. On failure a transient error is surfaced and the in-memory
  /// list is left unchanged.
  Future<void> saveCharacter(Character character) async {
    final Character updated =
        character.copyWith(modifiedAt: DateTime.now().toUtc());
    try {
      await _repository.update(updated);
      final int index =
          _characters.indexWhere((Character c) => c.id == updated.id);
      final List<Character> next = List<Character>.of(_characters);
      if (index >= 0) {
        next[index] = updated;
      } else {
        next.add(updated);
      }
      _characters = next..sort(compareCharacters);
      _transientError = null;
    } catch (_) {
      _transientError = 'The character could not be saved.';
    }
    notifyListeners();
  }

  /// Deletes the character identified by [id] from the store and the in-memory
  /// list. On failure a transient error is surfaced and the list is unchanged.
  Future<void> deleteCharacter(String id) async {
    try {
      await _repository.delete(id);
      _characters =
          _characters.where((Character c) => c.id != id).toList(growable: false);
      _transientError = null;
    } catch (_) {
      _transientError = 'The character could not be deleted.';
    }
    notifyListeners();
  }
}
