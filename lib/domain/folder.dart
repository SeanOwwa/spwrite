/// Domain layer: the [Folder] immutable value object and the single shared
/// ordering rule for a Project's folders in the Project_Sidebar.
///
/// A [Folder] belongs to exactly one [Project] (via [Folder.projectId]) and
/// never contains another folder: the hierarchy is exactly one level deep
/// (Project → Folder → Document). A Folder therefore owns only Documents, not
/// nested folders.
///
/// Timestamps ([Folder.createdAt], [Folder.modifiedAt]) are persisted as
/// integer milliseconds since the Unix epoch in UTC for stable,
/// timezone-independent ordering and round-tripping (Req 7.2, 17.2).
library;

/// SQLite column names for the `folders` table. Centralized so the entity's
/// [Folder.toRow]/[Folder.fromRow] and the repository's SQL agree on the exact
/// column identifiers.
class FolderColumns {
  const FolderColumns._();

  static const String id = 'id';
  static const String name = 'name';
  static const String projectId = 'project_id';
  static const String createdAt = 'created_at';
  static const String modifiedAt = 'modified_at';

  /// Manual sort order of the folder within its project. Lower sorts first.
  /// Set by drag-and-drop reordering.
  static const String position = 'position';
}

/// An immutable container that groups Documents within a single Project. A
/// Folder has a name, a unique identifier, the identifier of the Project it
/// belongs to, and creation / last-modified timestamps (Req 7.2, 17.2).
///
/// A Folder belongs to exactly one Project ([projectId]) and never contains
/// another Folder — the hierarchy is one level deep.
class Folder {
  /// Unique identifier (a UUID v4 string) (Req 7.2, 17.2).
  final String id;

  /// Human-readable name; stored as 1..255 characters (Req 7.2, 17.2).
  final String name;

  /// Identifier of the Project this folder belongs to. A folder belongs to
  /// exactly one project and this reference is immutable for its lifetime
  /// (Req 7.2, 17.2).
  final String projectId;

  /// Creation timestamp (Req 7.2, 17.2).
  final DateTime createdAt;

  /// Last-modified timestamp (Req 7.2, 8.2, 17.2).
  final DateTime modifiedAt;

  /// Manual sort order of this folder within its project. Lower values sort
  /// first. Defaults to 0; assigned real values by creation and drag-and-drop
  /// reordering.
  final int position;

  const Folder({
    required this.id,
    required this.name,
    required this.projectId,
    required this.createdAt,
    required this.modifiedAt,
    this.position = 0,
  });

  /// Creates a brand-new folder whose last-modified timestamp equals its
  /// creation timestamp (Req 7.2).
  factory Folder.create({
    required String id,
    required String projectId,
    required String name,
    required DateTime now,
    int position = 0,
  }) {
    return Folder(
      id: id,
      name: name,
      projectId: projectId,
      createdAt: now,
      modifiedAt: now, // Req 7.2: modified == created on creation
      position: position,
    );
  }

  /// Returns a copy of this folder with the given fields replaced. Only the
  /// fields that change over a folder's lifetime (name and the last-modified
  /// timestamp) may be overridden; [id], [projectId], and [createdAt] are
  /// immutable for the life of the folder.
  Folder copyWith({
    String? name,
    DateTime? modifiedAt,
    int? position,
  }) {
    return Folder(
      id: id,
      name: name ?? this.name,
      projectId: projectId,
      createdAt: createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      position: position ?? this.position,
    );
  }

  /// Serializes this entity to a SQLite row. Timestamps are written as integer
  /// milliseconds since the Unix epoch in UTC (Req 7.2, 17.2).
  Map<String, Object?> toRow() {
    return <String, Object?>{
      FolderColumns.id: id,
      FolderColumns.name: name,
      FolderColumns.projectId: projectId,
      FolderColumns.createdAt: createdAt.toUtc().millisecondsSinceEpoch,
      FolderColumns.modifiedAt: modifiedAt.toUtc().millisecondsSinceEpoch,
      FolderColumns.position: position,
    };
  }

  /// Deserializes a [Folder] from a SQLite row. Timestamps are read from
  /// integer milliseconds since the Unix epoch and reconstructed as UTC
  /// [DateTime]s (Req 7.2, 17.2).
  factory Folder.fromRow(Map<String, Object?> row) {
    return Folder(
      id: row[FolderColumns.id]! as String,
      name: row[FolderColumns.name]! as String,
      projectId: row[FolderColumns.projectId]! as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row[FolderColumns.createdAt]! as num).toInt(),
        isUtc: true,
      ),
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(
        (row[FolderColumns.modifiedAt]! as num).toInt(),
        isUtc: true,
      ),
      position: (row[FolderColumns.position] as num?)?.toInt() ?? 0,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Folder &&
        other.id == id &&
        other.name == name &&
        other.projectId == projectId &&
        other.position == position &&
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
      projectId,
      position,
      createdAt.toUtc().millisecondsSinceEpoch,
      modifiedAt.toUtc().millisecondsSinceEpoch,
    );
  }

  @override
  String toString() {
    return 'Folder(id: $id, name: $name, projectId: $projectId, '
        'createdAt: ${createdAt.toUtc().toIso8601String()}, '
        'modifiedAt: ${modifiedAt.toUtc().toIso8601String()})';
  }
}

/// The canonical order for a Project's folders in the Project_Sidebar:
/// last-modified timestamp descending, then name ascending (case-insensitive)
/// as a tie-breaker (Req 6.2).
///
/// This is the single shared implementation of the folder ordering rule,
/// mirroring `compareDocuments`. It is reused by the repository (mirrored in the
/// SQL `ORDER BY modified_at DESC, name ASC` clause) and by the state layer's
/// in-memory re-sorts after a mutation, guaranteeing the query and the in-memory
/// list agree.
///
/// Returns a negative value if [a] should sort before [b], a positive value if
/// [a] should sort after [b], and zero when they are equivalent under the rule.
int compareFolders(Folder a, Folder b) {
  // Primary key: manual position, ascending (drag-and-drop order).
  final int byPosition = a.position.compareTo(b.position);
  if (byPosition != 0) return byPosition;

  // Tie-breaker 1 (e.g. legacy rows all at position 0): last-modified
  // timestamp, descending (most recent first).
  final int aMillis = a.modifiedAt.toUtc().millisecondsSinceEpoch;
  final int bMillis = b.modifiedAt.toUtc().millisecondsSinceEpoch;
  final int byModified = bMillis.compareTo(aMillis);
  if (byModified != 0) return byModified;

  // Tie-breaker 2: name ascending, case-insensitive.
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// A [Comparator] view of [compareFolders] for APIs that expect a comparator
/// object (e.g. `List.sort`).
const Comparator<Folder> folderOrdering = compareFolders;
