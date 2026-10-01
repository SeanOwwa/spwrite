/// Data layer: the SQLite-backed [AiConversationRepository] implementation.
///
/// [SqliteAiConversationRepository] fulfils the domain
/// [AiConversationRepository] contract over an already-open [Database]. Every
/// statement binds its values as `?` parameters (no interpolation of
/// user-supplied values), avoiding SQL injection and quoting errors. Only table
/// and column identifiers, which come from trusted constants, are interpolated
/// into the SQL text.
///
/// The grounding [ChatMessage.sources] list is serialized to a JSON string in
/// the `sources` TEXT column on write and parsed back on read, keeping the
/// domain [ChatMessage] free of persistence concerns (the row mapping lives
/// here rather than on the model).
library;

import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/ai/ai_conversation_repository.dart';
import '../domain/ai/chat_message.dart';
import 'database_provider.dart';

/// SQLite column names for the `ai_conversations` table. Centralized so the
/// repository's row mapping and SQL agree on the exact column identifiers,
/// mirroring the `CharacterColumns` / `DocumentColumns` convention.
class AiConversationColumns {
  const AiConversationColumns._();

  static const String id = 'id';
  static const String projectId = 'project_id';
  static const String role = 'role';
  static const String text = 'text';
  static const String timestamp = 'timestamp';

  /// The grounding sources, stored as a JSON array of `{"id","title"}` objects
  /// (an empty array when the turn is not grounded). Never NULL.
  static const String sources = 'sources';
}

/// An [AiConversationRepository] backed by a local SQLite [Database].
///
/// Like the other repositories, this one does not own the database lifecycle:
/// it operates on an open [Database] supplied by
/// [DatabaseProvider.openAppDatabase] and passed into the constructor.
class SqliteAiConversationRepository implements AiConversationRepository {
  /// The open database this repository reads from and writes to.
  final Database _db;

  /// The `ai_conversations` table name, sourced from the provider so the
  /// identifier used here matches the one the schema was created with.
  static const String _table = DatabaseProvider.aiConversationsTable;

  /// Creates a repository over the given open [database].
  const SqliteAiConversationRepository(Database database) : _db = database;

  /// Returns every stored message for [projectId] in chronological order
  /// (oldest first), ordered by timestamp then id for a fully stable order. The
  /// project id is bound as a parameter.
  @override
  Future<List<ChatMessage>> getAllForProject(String projectId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      _table,
      where: '${AiConversationColumns.projectId} = ?',
      whereArgs: <Object?>[projectId],
      orderBy: '${AiConversationColumns.timestamp} ASC, '
          '${AiConversationColumns.id} ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// Appends [message] to [projectId] as a new row. All values, including the
  /// serialized sources JSON, are bound as parameters.
  @override
  Future<void> append(String projectId, ChatMessage message) async {
    await _db.insert(
      _table,
      _toRow(projectId, message),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Removes every stored message for [projectId]. The identifier is bound as a
  /// parameter.
  @override
  Future<void> clearForProject(String projectId) async {
    await _db.delete(
      _table,
      where: '${AiConversationColumns.projectId} = ?',
      whereArgs: <Object?>[projectId],
    );
  }

  /// Serializes [message] (belonging to [projectId]) to a SQLite row. The role
  /// is stored as its enum name, the timestamp as integer milliseconds since
  /// the Unix epoch in UTC (matching the project's timestamp convention), and
  /// the sources as a JSON array. The row's id is derived from the project and
  /// timestamp so the same turn is idempotent across replayed appends.
  static Map<String, Object?> _toRow(String projectId, ChatMessage message) {
    final int millis = message.timestamp.toUtc().millisecondsSinceEpoch;
    return <String, Object?>{
      AiConversationColumns.id: '$projectId:$millis:${message.role.name}',
      AiConversationColumns.projectId: projectId,
      AiConversationColumns.role: message.role.name,
      AiConversationColumns.text: message.text,
      AiConversationColumns.timestamp: millis,
      AiConversationColumns.sources: _encodeSources(message.sources),
    };
  }

  /// Deserializes a [ChatMessage] from a SQLite row. An unknown role name falls
  /// back to [ChatRole.assistant]; a null/blank timestamp yields the epoch.
  static ChatMessage _fromRow(Map<String, Object?> row) {
    final String roleName = (row[AiConversationColumns.role] as String?) ?? '';
    final ChatRole role = ChatRole.values.firstWhere(
      (ChatRole r) => r.name == roleName,
      orElse: () => ChatRole.assistant,
    );
    return ChatMessage(
      role: role,
      text: (row[AiConversationColumns.text] as String?) ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (row[AiConversationColumns.timestamp] as num?)?.toInt() ?? 0,
        isUtc: true,
      ),
      sources: _decodeSources(row[AiConversationColumns.sources] as String?),
    );
  }

  /// Encodes [sources] to a JSON array of `{"id","title"}` objects.
  static String _encodeSources(List<ChatMessageSource> sources) {
    return jsonEncode(
      sources
          .map((ChatMessageSource s) => <String, String>{
                'id': s.id,
                'title': s.title,
              })
          .toList(growable: false),
    );
  }

  /// Decodes the JSON [raw] sources column back into [ChatMessageSource]s.
  /// Tolerates a null/empty column (no sources) and skips malformed entries.
  static List<ChatMessageSource> _decodeSources(String? raw) {
    if (raw == null || raw.isEmpty) return const <ChatMessageSource>[];
    // The column is only ever written by [_encodeSources], so invalid JSON here
    // implies external tampering with the database file. Tolerate it rather
    // than throwing, so hostile/corrupt stored data can never crash a load.
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const <ChatMessageSource>[];
    }
    if (decoded is! List) return const <ChatMessageSource>[];
    final List<ChatMessageSource> result = <ChatMessageSource>[];
    for (final Object? entry in decoded) {
      if (entry is Map) {
        final Object? id = entry['id'];
        final Object? title = entry['title'];
        if (id is String && title is String) {
          result.add(ChatMessageSource(id: id, title: title));
        }
      }
    }
    return result;
  }
}
