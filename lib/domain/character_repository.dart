/// Domain layer: the [CharacterRepository] abstraction over persistence.
///
/// The state layer (`CharacterPanelState`) depends only on this interface,
/// never on SQLite directly, keeping it decoupled from the persistence
/// implementation. The data layer's `SqliteCharacterRepository` implements each
/// method against the open database.
library;

import 'character.dart';

/// Abstracts persistence of [Character]s so the state layer never touches the
/// SQLite database directly.
///
/// Implementations must use **parameterized SQL only** — values (including the
/// image BLOB) are bound as `?` placeholders and never interpolated into the
/// SQL string; only trusted table/column name constants may be interpolated.
/// Failures are surfaced by throwing, so the state layer can retain in-memory
/// truth and present recoverable error messages.
abstract class CharacterRepository {
  /// Returns every character in [projectId] ordered by the shared
  /// [compareCharacters] rule (name ascending, case-insensitive). Returns an
  /// empty list when the project has no characters.
  Future<List<Character>> getAllForProject(String projectId);

  /// Returns the single character with the given [id], or `null` when no
  /// character with that identifier is present.
  Future<Character?> getById(String id);

  /// Inserts a new [character] into the store and returns the persisted entity.
  Future<Character> create(Character character);

  /// Persists field / image / last-modified changes for an existing character.
  Future<void> update(Character character);

  /// Removes the character identified by [id]. Throws on failure.
  Future<void> delete(String id);
}
