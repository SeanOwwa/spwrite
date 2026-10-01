/// Domain layer: the [AiConversationRepository] abstraction over persistence
/// of the AI Panel conversation.
///
/// Persisting the conversation across app launches is OPTIONAL for this release
/// (Req 9.3); when implemented, storage SHALL be local (SQLite) and scoped to
/// the project. The state layer (`AiAssistantState`) depends only on this
/// interface, never on SQLite directly, keeping it decoupled from the
/// persistence implementation. The data layer's `SqliteAiConversationRepository`
/// implements each method against the open database.
library;

import 'chat_message.dart';

/// Abstracts persistence of the AI Panel conversation ([ChatMessage]s) so the
/// state layer never touches the SQLite database directly.
///
/// The conversation is **scoped to a project**: every message belongs to a
/// single project, and reads/writes/clears are addressed by `projectId`.
///
/// Implementations must use **parameterized SQL only** — values are bound as
/// `?` placeholders and never interpolated into the SQL string; only trusted
/// table/column name constants may be interpolated. Failures are surfaced by
/// throwing, so the state layer can retain in-memory truth and present
/// recoverable error messages.
abstract class AiConversationRepository {
  /// Returns every persisted [ChatMessage] for [projectId] in chronological
  /// order (oldest first), so the panel can replay the conversation. Returns an
  /// empty list when the project has no stored conversation.
  Future<List<ChatMessage>> getAllForProject(String projectId);

  /// Appends [message] to [projectId]'s stored conversation. Called once per
  /// turn as the conversation grows.
  Future<void> append(String projectId, ChatMessage message);

  /// Removes every stored message for [projectId] (e.g. when the writer clears
  /// the conversation). Throws on failure.
  Future<void> clearForProject(String projectId);
}
