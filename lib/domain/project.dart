/// Domain layer: the [Project] immutable value object and the single shared
/// ordering rule for the Dashboard's project list.
///
/// A Project is the top level of the v2 three-level model
/// (Project → Folder → Document).
///
/// Timestamps ([Project.createdAt], [Project.modifiedAt]) are persisted as
/// integer milliseconds since the Unix epoch in UTC for stable,
/// timezone-independent ordering and round-tripping (Req 17.1).
///
/// A project may carry an optional cover photo ([Project.coverImage]): JPEG
/// bytes already normalized to 1600 × 2560 px, stored as a BLOB exactly like a
/// character portrait so it travels with the project on every platform
/// (schema v7).
library;

import 'dart:typed_data';

/// SQLite column names for the `projects` table. Centralized so the entity's
/// [Project.toRow]/[Project.fromRow] and the repository's SQL agree on the
/// exact column identifiers.
class ProjectColumns {
  const ProjectColumns._();

  static const String id = 'id';
  static const String name = 'name';
  static const String createdAt = 'created_at';
  static const String modifiedAt = 'modified_at';

  /// The cover photo bytes (a BLOB), or NULL when the project has no cover
  /// (schema v7).
  static const String coverImage = 'cover_image';
}

/// An immutable project: a name, a unique identifier, and creation /
/// last-modified timestamps (Req 2.2, 17.1).
class Project {
  /// Unique identifier (a UUID v4 string) (Req 2.2, 17.1).
  final String id;

  /// Human-readable name. May be empty (the UI substitutes an "untitled"
  /// placeholder); stored as 0..255 characters (Req 2.2, 17.1).
  final String name;

  /// Creation timestamp (Req 2.2, 17.1).
  final DateTime createdAt;

  /// Last-modified timestamp (Req 2.2, 17.1).
  final DateTime modifiedAt;

  /// The normalized cover photo (JPEG, 1600 × 2560 px), or `null` when the
  /// project has no cover.
  final Uint8List? coverImage;

  const Project({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.modifiedAt,
    this.coverImage,
  });

  /// Creates a brand-new project with a last-modified timestamp equal to its
  /// creation timestamp (Req 2.2).
  factory Project.create({
    required String id,
    required String name,
    required DateTime now,
    Uint8List? coverImage,
  }) {
    return Project(
      id: id,
      name: name,
      createdAt: now,
      modifiedAt: now, // Req 2.2: modified == created on creation
      coverImage: coverImage,
    );
  }

  /// Returns a copy of this project with the given fields replaced. Only the
  /// fields that change over a project's lifetime (name, cover, and the
  /// last-modified timestamp) may be overridden; [id] and [createdAt] are
  /// immutable for the life of the project.
  ///
  /// Because [coverImage] is nullable and removing it is a valid edit, an
  /// explicit [clearCoverImage] flag distinguishes "leave the cover unchanged"
  /// (default) from "remove the cover" (mirroring `Character.copyWith`).
  Project copyWith({
    String? name,
    DateTime? modifiedAt,
    Uint8List? coverImage,
    bool clearCoverImage = false,
  }) {
    return Project(
      id: id,
      name: name ?? this.name,
      createdAt: createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      coverImage: clearCoverImage ? null : (coverImage ?? this.coverImage),
    );
  }

  /// Serializes this entity to a SQLite row. Timestamps are written as integer
  /// milliseconds since the Unix epoch in UTC (Req 17.1). A null [coverImage]
  /// is stored as SQL NULL.
  Map<String, Object?> toRow() {
    return <String, Object?>{
      ProjectColumns.id: id,
      ProjectColumns.name: name,
      ProjectColumns.createdAt: createdAt.toUtc().millisecondsSinceEpoch,
      ProjectColumns.modifiedAt: modifiedAt.toUtc().millisecondsSinceEpoch,
      ProjectColumns.coverImage: coverImage,
    };
  }

  /// Deserializes a [Project] from a SQLite row. Timestamps are read from
  /// integer milliseconds since the Unix epoch and reconstructed as UTC
  /// [DateTime]s (Req 17.1). The cover column may come back as a [Uint8List]
  /// or a plain [List<int>] depending on the platform factory (or be absent on
  /// a row read before the v7 migration), so it is normalized to [Uint8List];
  /// NULL / absent yields a null [coverImage].
  factory Project.fromRow(Map<String, Object?> row) {
    final Object? rawCover = row[ProjectColumns.coverImage];
    final Uint8List? cover = rawCover == null
        ? null
        : (rawCover is Uint8List
            ? rawCover
            : Uint8List.fromList((rawCover as List).cast<int>()));
    return Project(
      id: row[ProjectColumns.id]! as String,
      name: row[ProjectColumns.name]! as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row[ProjectColumns.createdAt]! as num).toInt(),
        isUtc: true,
      ),
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(
        (row[ProjectColumns.modifiedAt]! as num).toInt(),
        isUtc: true,
      ),
      coverImage: cover,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Project &&
        other.id == id &&
        other.name == name &&
        other.createdAt.toUtc().millisecondsSinceEpoch ==
            createdAt.toUtc().millisecondsSinceEpoch &&
        other.modifiedAt.toUtc().millisecondsSinceEpoch ==
            modifiedAt.toUtc().millisecondsSinceEpoch &&
        _bytesEqual(other.coverImage, coverImage);
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      name,
      createdAt.toUtc().millisecondsSinceEpoch,
      modifiedAt.toUtc().millisecondsSinceEpoch,
      coverImage?.length,
    );
  }

  @override
  String toString() {
    return 'Project(id: $id, name: $name, '
        'createdAt: ${createdAt.toUtc().toIso8601String()}, '
        'modifiedAt: ${modifiedAt.toUtc().toIso8601String()}, '
        'hasCover: ${coverImage != null})';
  }
}

/// Byte-wise equality for two optional byte buffers.
bool _bytesEqual(Uint8List? a, Uint8List? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The canonical order for the Dashboard's project list: last-modified
/// timestamp descending, then name ascending (case-insensitive) as a
/// tie-breaker (Req 1.2).
///
/// This is the single shared implementation of the ordering rule. It is reused
/// by the repository (mirrored in the SQL `ORDER BY modified_at DESC,
/// name ASC` clause) and by the state layer's in-memory re-sorts after a
/// mutation, guaranteeing the query and the in-memory list agree.
///
/// Returns a negative value if [a] should sort before [b], a positive value if
/// [a] should sort after [b], and zero when they are equivalent under the rule.
int compareProjects(Project a, Project b) {
  // Primary key: last-modified timestamp, descending (most recent first).
  final int aMillis = a.modifiedAt.toUtc().millisecondsSinceEpoch;
  final int bMillis = b.modifiedAt.toUtc().millisecondsSinceEpoch;
  final int byModified = bMillis.compareTo(aMillis);
  if (byModified != 0) return byModified;

  // Tie-breaker: name ascending, case-insensitive.
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// A [Comparator] view of [compareProjects] for APIs that expect a comparator
/// object (e.g. `List.sort`).
const Comparator<Project> projectOrdering = compareProjects;
