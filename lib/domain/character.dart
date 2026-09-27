/// Domain layer: the [Character] immutable value object and the shared ordering
/// rule for a project's Character_List.
///
/// A character belongs to exactly one project ([Character.projectId]) — the
/// author's cast of fictional people for that book/project. Each character has
/// a name, an optional role/title, a short one-line summary, a longer free-form
/// notes/description body, an optional portrait image (stored as raw bytes so
/// it is fully portable across web, desktop, and mobile), and creation /
/// last-modified timestamps.
///
/// Timestamps are persisted as integer milliseconds since the Unix epoch in UTC
/// for stable, timezone-independent ordering and round-tripping, matching the
/// convention used by [Document], [Folder], and [Project].
library;

import 'dart:typed_data';

/// SQLite column names for the `characters` table. Centralized so the entity's
/// [Character.toRow]/[Character.fromRow] and the repository's SQL agree on the
/// exact column identifiers.
class CharacterColumns {
  const CharacterColumns._();

  static const String id = 'id';
  static const String projectId = 'project_id';
  static const String name = 'name';
  static const String role = 'role';
  static const String summary = 'summary';
  static const String notes = 'notes';

  /// The portrait image bytes (a BLOB), or NULL when the character has no
  /// image.
  static const String image = 'image';

  static const String createdAt = 'created_at';
  static const String modifiedAt = 'modified_at';
}

/// An immutable fictional character belonging to a project: a name, optional
/// role, short summary, longer notes, an optional portrait image, a unique
/// identifier, and creation / last-modified timestamps.
class Character {
  /// The maximum length, in characters, of the [name].
  static const int maxNameLength = 255;

  /// The maximum length, in characters, of the [role].
  static const int maxRoleLength = 255;

  /// The maximum length, in characters, of the one-line [summary].
  static const int maxSummaryLength = 500;

  /// The maximum length, in characters, of the free-form [notes] body.
  static const int maxNotesLength = 100000;

  /// Unique identifier (a UUID v4 string).
  final String id;

  /// Identifier of the owning project. Every character belongs to exactly one
  /// project.
  final String projectId;

  /// The character's name. May be empty (the UI substitutes an "Unnamed"
  /// placeholder); stored as 0..[maxNameLength] characters.
  final String name;

  /// The character's role or title (e.g. "Protagonist", "Antagonist",
  /// "Mentor"). May be empty. 0..[maxRoleLength] characters.
  final String role;

  /// A short, one-line summary shown collapsed in the sidebar list. May be
  /// empty. 0..[maxSummaryLength] characters.
  final String summary;

  /// Free-form notes / description (backstory, appearance, arc, relationships).
  /// May be empty. Revealed when the sidebar entry is expanded ("see more").
  /// 0..[maxNotesLength] characters.
  final String notes;

  /// The character's portrait image bytes, or `null` when none is set. Stored
  /// as a BLOB so the image travels with the project on every platform.
  final Uint8List? image;

  /// Creation timestamp.
  final DateTime createdAt;

  /// Last-modified timestamp.
  final DateTime modifiedAt;

  const Character({
    required this.id,
    required this.projectId,
    required this.name,
    required this.role,
    required this.summary,
    required this.notes,
    required this.image,
    required this.createdAt,
    required this.modifiedAt,
  });

  /// Creates a brand-new, empty character in [projectId] with the given [id]
  /// and a last-modified timestamp equal to its creation timestamp.
  factory Character.newCharacter({
    required String id,
    required String projectId,
    required DateTime now,
  }) {
    return Character(
      id: id,
      projectId: projectId,
      name: '',
      role: '',
      summary: '',
      notes: '',
      image: null,
      createdAt: now,
      modifiedAt: now,
    );
  }

  /// Returns a copy with the given fields replaced. [id], [projectId], and
  /// [createdAt] are immutable for the life of the character.
  ///
  /// Because [image] is nullable and clearing it is a valid edit, an explicit
  /// [clearImage] flag distinguishes "leave the image unchanged" (default)
  /// from "remove the image".
  Character copyWith({
    String? name,
    String? role,
    String? summary,
    String? notes,
    Uint8List? image,
    bool clearImage = false,
    DateTime? modifiedAt,
  }) {
    return Character(
      id: id,
      projectId: projectId,
      name: name ?? this.name,
      role: role ?? this.role,
      summary: summary ?? this.summary,
      notes: notes ?? this.notes,
      image: clearImage ? null : (image ?? this.image),
      createdAt: createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
    );
  }

  /// Serializes this entity to a SQLite row. Timestamps are written as integer
  /// milliseconds since the Unix epoch in UTC. A null [image] is stored as SQL
  /// NULL.
  Map<String, Object?> toRow() {
    return <String, Object?>{
      CharacterColumns.id: id,
      CharacterColumns.projectId: projectId,
      CharacterColumns.name: name,
      CharacterColumns.role: role,
      CharacterColumns.summary: summary,
      CharacterColumns.notes: notes,
      CharacterColumns.image: image,
      CharacterColumns.createdAt: createdAt.toUtc().millisecondsSinceEpoch,
      CharacterColumns.modifiedAt: modifiedAt.toUtc().millisecondsSinceEpoch,
    };
  }

  /// Deserializes a [Character] from a SQLite row. The image column may come
  /// back as a [Uint8List] or a plain [List<int>] depending on the platform
  /// factory, so it is normalized to [Uint8List]; NULL yields a null [image].
  factory Character.fromRow(Map<String, Object?> row) {
    final Object? rawImage = row[CharacterColumns.image];
    final Uint8List? image = rawImage == null
        ? null
        : (rawImage is Uint8List
            ? rawImage
            : Uint8List.fromList((rawImage as List).cast<int>()));

    return Character(
      id: row[CharacterColumns.id]! as String,
      projectId: row[CharacterColumns.projectId]! as String,
      name: (row[CharacterColumns.name] as String?) ?? '',
      role: (row[CharacterColumns.role] as String?) ?? '',
      summary: (row[CharacterColumns.summary] as String?) ?? '',
      notes: (row[CharacterColumns.notes] as String?) ?? '',
      image: image,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row[CharacterColumns.createdAt]! as num).toInt(),
        isUtc: true,
      ),
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(
        (row[CharacterColumns.modifiedAt]! as num).toInt(),
        isUtc: true,
      ),
    );
  }

  /// The display name, substituting a placeholder when the name is blank.
  String get displayName => name.trim().isEmpty ? 'Unnamed character' : name;

  @override
  String toString() {
    return 'Character(id: $id, projectId: $projectId, name: $name, '
        'role: $role, hasImage: ${image != null})';
  }
}

/// The canonical order for a project's Character_List: name ascending
/// (case-insensitive), then most-recently-modified first as a tie-breaker for
/// same-named (e.g. blank) characters, then id for a fully stable order.
///
/// Unlike documents (which order by recency), characters are a reference list
/// the author scans by name, so name-ascending is the primary key. This is the
/// single shared implementation, mirrored by the repository's SQL `ORDER BY`
/// and reused by the state layer's in-memory re-sorts.
int compareCharacters(Character a, Character b) {
  final int byName =
      a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  if (byName != 0) return byName;

  final int aMillis = a.modifiedAt.toUtc().millisecondsSinceEpoch;
  final int bMillis = b.modifiedAt.toUtc().millisecondsSinceEpoch;
  final int byModified = bMillis.compareTo(aMillis);
  if (byModified != 0) return byModified;

  return a.id.compareTo(b.id);
}

/// A [Comparator] view of [compareCharacters] for APIs that expect a comparator
/// object (e.g. `List.sort`).
const Comparator<Character> characterOrdering = compareCharacters;
