/// Domain layer: the [Document] immutable value object and the single shared
/// ordering rule for a container's Document_List.
///
/// A document belongs to exactly one project ([Document.projectId]) and lives
/// either inside a folder of that project ([Document.folderId] non-null) or at
/// the project root ([Document.folderId] == null, a Root-Level Document)
/// (Req 10.1, 10.2, 17.3).
///
/// Timestamps ([Document.createdAt], [Document.modifiedAt]) are persisted as
/// integer milliseconds since the Unix epoch in UTC for stable,
/// timezone-independent ordering and round-tripping (Req 17.3).

library;

/// SQLite column names for the `documents` table. Centralized so the entity's
/// [Document.toRow]/[Document.fromRow] and the repository's SQL agree on the
/// exact column identifiers.
class DocumentColumns {
  const DocumentColumns._();

  static const String id = 'id';
  static const String title = 'title';
  static const String content = 'content';
  static const String projectId = 'project_id';
  static const String folderId = 'folder_id';
  static const String createdAt = 'created_at';
  static const String modifiedAt = 'modified_at';
}

/// An immutable writing artifact: a title, Markdown content, a unique
/// identifier, its owning project and (optional) folder, and creation /
/// last-modified timestamps (Req 10.1, 10.2, 17.3).
class Document {
  /// Unique identifier (a UUID v4 string) (Req 17.3).
  final String id;

  /// Human-readable name. May be empty (the UI substitutes an "untitled"
  /// placeholder); stored as 0..255 characters (Req 6.6, 17.3).
  final String title;

  /// Markdown source body, 0..1,000,000 characters (Req 15.1, 15.3, 17.3).
  final String content;

  /// Identifier of the owning project. Every document belongs to exactly one
  /// project (Req 10.1, 17.3).
  final String projectId;

  /// Identifier of the containing folder, or `null` when this is a Root-Level
  /// Document (a document that lives directly under the project rather than in
  /// a folder) (Req 10.2, 6.3, 17.3).
  final String? folderId;

  /// Creation timestamp (Req 10.1, 17.3).
  final DateTime createdAt;

  /// Last-modified timestamp (Req 10.1, 12.2, 14.9, 17.3).
  final DateTime modifiedAt;

  const Document({
    required this.id,
    required this.title,
    required this.content,
    required this.projectId,
    this.folderId,
    required this.createdAt,
    required this.modifiedAt,
  });

  /// Creates a brand-new document with the default title "Untitled Document",
  /// empty (Markdown) content, and a last-modified timestamp equal to its
  /// creation timestamp. The document is placed in [folderId] when provided, or
  /// at the project root when [folderId] is null (Req 10.3).
  factory Document.newDocument({
    required String id,
    required String projectId,
    String? folderId,
    required DateTime now,
  }) {
    return Document(
      id: id,
      title: 'Untitled Document', // Req 10.3
      content: '', // Req 10.3
      projectId: projectId,
      folderId: folderId,
      createdAt: now,
      modifiedAt: now, // Req 10.3: modified == created on creation
    );
  }

  /// Returns a copy of this document with the given fields replaced. Only the
  /// fields that change over a document's lifetime (title, content, the
  /// containing folder, and the last-modified timestamp) may be overridden;
  /// [id], [projectId], and [createdAt] are immutable for the life of the
  /// document.
  Document copyWith({
    String? title,
    String? content,
    String? folderId,
    DateTime? modifiedAt,
  }) {
    return Document(
      id: id,
      title: title ?? this.title,
      content: content ?? this.content,
      projectId: projectId,
      folderId: folderId ?? this.folderId,
      createdAt: createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
    );
  }

  /// Serializes this entity to a SQLite row. Timestamps are written as integer
  /// milliseconds since the Unix epoch in UTC (Req 17.3). A null [folderId] is
  /// stored as SQL NULL, marking a Root-Level Document.
  Map<String, Object?> toRow() {
    return <String, Object?>{
      DocumentColumns.id: id,
      DocumentColumns.title: title,
      DocumentColumns.content: content,
      DocumentColumns.projectId: projectId,
      DocumentColumns.folderId: folderId,
      DocumentColumns.createdAt: createdAt.toUtc().millisecondsSinceEpoch,
      DocumentColumns.modifiedAt: modifiedAt.toUtc().millisecondsSinceEpoch,
    };
  }

  /// Deserializes a [Document] from a SQLite row. Timestamps are read from
  /// integer milliseconds since the Unix epoch and reconstructed as UTC
  /// [DateTime]s (Req 17.3). A NULL `folder_id` yields a null [folderId]
  /// (a Root-Level Document).
  factory Document.fromRow(Map<String, Object?> row) {
    return Document(
      id: row[DocumentColumns.id]! as String,
      title: row[DocumentColumns.title]! as String,
      content: row[DocumentColumns.content]! as String,
      projectId: row[DocumentColumns.projectId]! as String,
      folderId: row[DocumentColumns.folderId] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row[DocumentColumns.createdAt]! as num).toInt(),
        isUtc: true,
      ),
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(
        (row[DocumentColumns.modifiedAt]! as num).toInt(),
        isUtc: true,
      ),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Document &&
        other.id == id &&
        other.title == title &&
        other.content == content &&
        other.projectId == projectId &&
        other.folderId == folderId &&
        other.createdAt.toUtc().millisecondsSinceEpoch ==
            createdAt.toUtc().millisecondsSinceEpoch &&
        other.modifiedAt.toUtc().millisecondsSinceEpoch ==
            modifiedAt.toUtc().millisecondsSinceEpoch;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      title,
      content,
      projectId,
      folderId,
      createdAt.toUtc().millisecondsSinceEpoch,
      modifiedAt.toUtc().millisecondsSinceEpoch,
    );
  }

  @override
  String toString() {
    return 'Document(id: $id, title: $title, content.length: ${content.length}, '
        'projectId: $projectId, folderId: $folderId, '
        'createdAt: ${createdAt.toUtc().toIso8601String()}, '
        'modifiedAt: ${modifiedAt.toUtc().toIso8601String()})';
  }
}

/// The canonical order for a container's Document_List: last-modified timestamp
/// descending, then title ascending (case-insensitive) as a tie-breaker
/// (Req 1.4).
///
/// This is the single shared implementation of the ordering rule. It is reused
/// by the repository (mirrored in the SQL `ORDER BY modified_at DESC,
/// title ASC` clause) and by the state layer's in-memory re-sorts after a
/// mutation, guaranteeing the query and the in-memory list agree. It is applied
/// within a single container (a folder or the project root), so it does not
/// consider projectId or folderId.
///
/// Returns a negative value if [a] should sort before [b], a positive value if
/// [a] should sort after [b], and zero when they are equivalent under the rule.
int compareDocuments(Document a, Document b) {
  // Primary key: last-modified timestamp, descending (most recent first).
  final int aMillis = a.modifiedAt.toUtc().millisecondsSinceEpoch;
  final int bMillis = b.modifiedAt.toUtc().millisecondsSinceEpoch;
  final int byModified = bMillis.compareTo(aMillis);
  if (byModified != 0) return byModified;

  // Tie-breaker: title ascending, case-insensitive.
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// A [Comparator] view of [compareDocuments] for APIs that expect a comparator
/// object (e.g. `List.sort`).
const Comparator<Document> documentOrdering = compareDocuments;
