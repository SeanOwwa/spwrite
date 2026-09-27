/// Domain layer: the [Project] immutable value object and the single shared
/// ordering rule for the Dashboard's project list.
///
/// A Project is the top level of the v2 three-level model
/// (Project → Folder → Document).
///
/// Timestamps ([Project.createdAt], [Project.modifiedAt]) are persisted as
/// integer milliseconds since the Unix epoch in UTC for stable,
/// timezone-independent ordering and round-tripping (Req 17.1).
library;

/// SQLite column names for the `projects` table. Centralized so the entity's
/// [Project.toRow]/[Project.fromRow] and the repository's SQL agree on the
/// exact column identifiers.
class ProjectColumns {
  const ProjectColumns._();

  static const String id = 'id';
  static const String name = 'name';
  static const String createdAt = 'created_at';
  static const String modifiedAt = 'modified_at';
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

  const Project({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.modifiedAt,
  });

  /// Creates a brand-new project with a last-modified timestamp equal to its
  /// creation timestamp (Req 2.2).
  factory Project.create({
    required String id,
    required String name,
    required DateTime now,
  }) {
    return Project(
      id: id,
      name: name,
      createdAt: now,
      modifiedAt: now, // Req 2.2: modified == created on creation
    );
  }

  /// Returns a copy of this project with the given fields replaced. Only the
  /// fields that change over a project's lifetime (name and the last-modified
  /// timestamp) may be overridden; [id] and [createdAt] are immutable for the
  /// life of the project.
  Project copyWith({
    String? name,
    DateTime? modifiedAt,
  }) {
    return Project(
      id: id,
      name: name ?? this.name,
      createdAt: createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
    );
  }

  /// Serializes this entity to a SQLite row. Timestamps are written as integer
  /// milliseconds since the Unix epoch in UTC (Req 17.1).
  Map<String, Object?> toRow() {
    return <String, Object?>{
      ProjectColumns.id: id,
      ProjectColumns.name: name,
      ProjectColumns.createdAt: createdAt.toUtc().millisecondsSinceEpoch,
      ProjectColumns.modifiedAt: modifiedAt.toUtc().millisecondsSinceEpoch,
    };
  }

  /// Deserializes a [Project] from a SQLite row. Timestamps are read from
  /// integer milliseconds since the Unix epoch and reconstructed as UTC
  /// [DateTime]s (Req 17.1).
  factory Project.fromRow(Map<String, Object?> row) {
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
            modifiedAt.toUtc().millisecondsSinceEpoch;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      name,
      createdAt.toUtc().millisecondsSinceEpoch,
      modifiedAt.toUtc().millisecondsSinceEpoch,
    );
  }

  @override
  String toString() {
    return 'Project(id: $id, name: $name, '
        'createdAt: ${createdAt.toUtc().toIso8601String()}, '
        'modifiedAt: ${modifiedAt.toUtc().toIso8601String()})';
  }
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
