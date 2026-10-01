import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/data/sqlite_ai_conversation_repository.dart';
import 'package:spwrite/domain/ai/chat_message.dart';
import 'package:spwrite/domain/project.dart';

/// Unit tests for [SqliteAiConversationRepository] (Task 10.3, Req 9.3).
///
/// Verifies the round-trip of [ChatMessage]s through the project-scoped
/// `ai_conversations` table: role, text, timestamp, and grounding sources are
/// faithfully persisted and read back in chronological order; reads/clears are
/// scoped to a single project; and empty projects behave gracefully.
void main() {
  setUpAll(() {
    // Use the in-memory FFI factory so the tests run on the dev machine
    // without touching disk or a real platform database.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late SqliteAiConversationRepository repo;

  setUp(() async {
    db = await DatabaseProvider.openAppDatabase(
      overridePath: inMemoryDatabasePath,
    );
    repo = SqliteAiConversationRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  /// Seeds a parent project row so the `ai_conversations` FK to `projects` is
  /// satisfied (the FFI factory enables `PRAGMA foreign_keys = ON`).
  Future<void> seedProject(String id) async {
    final DateTime now = DateTime.utc(2024, 1, 1);
    await db.insert(
      DatabaseProvider.projectsTable,
      Project.create(id: id, name: 'Project $id', now: now).toRow(),
    );
  }

  /// A UTC timestamp truncated to whole milliseconds, matching how the
  /// repository stores timestamps (integer millis since the epoch).
  DateTime utcMillis(int millisSinceEpoch) =>
      DateTime.fromMillisecondsSinceEpoch(millisSinceEpoch, isUtc: true);

  group('append + getAllForProject round-trip', () {
    test('returns messages in chronological order with all fields intact',
        () async {
      await seedProject('p1');

      // A user turn (no sources) authored first.
      final ChatMessage userTurn = ChatMessage.user(
        text: 'Who is the villain in my story?',
        timestamp: utcMillis(1000),
      );
      // An assistant turn WITH grounding sources, authored second.
      final ChatMessage assistantTurn = ChatMessage.assistant(
        text: 'The villain is Morden, per your character notes.',
        timestamp: utcMillis(2000),
        sources: const <ChatMessageSource>[
          ChatMessageSource(id: 'char-1', title: 'Morden'),
          ChatMessageSource(id: 'doc-9', title: 'Chapter 3'),
        ],
      );

      // Append out of chronological order to prove ordering comes from the
      // stored timestamp, not insertion order.
      await repo.append('p1', assistantTurn);
      await repo.append('p1', userTurn);

      final List<ChatMessage> loaded = await repo.getAllForProject('p1');

      expect(loaded, hasLength(2));

      // Chronological order (oldest first): user turn, then assistant turn.
      expect(loaded[0].role, ChatRole.user);
      expect(loaded[0].text, 'Who is the villain in my story?');
      expect(loaded[0].timestamp.toUtc().millisecondsSinceEpoch, 1000);
      expect(loaded[0].sources, isEmpty);

      expect(loaded[1].role, ChatRole.assistant);
      expect(loaded[1].text, 'The villain is Morden, per your character notes.');
      expect(loaded[1].timestamp.toUtc().millisecondsSinceEpoch, 2000);

      // Sources (id + title) survive the JSON round-trip in order.
      expect(loaded[1].sources, hasLength(2));
      expect(loaded[1].sources[0].id, 'char-1');
      expect(loaded[1].sources[0].title, 'Morden');
      expect(loaded[1].sources[1].id, 'doc-9');
      expect(loaded[1].sources[1].title, 'Chapter 3');

      // Full value equality (ChatMessage compares role/text/UTC-millis/sources).
      expect(loaded[0], equals(userTurn));
      expect(loaded[1], equals(assistantTurn));
    });

    test('a system turn round-trips its role', () async {
      await seedProject('p1');

      final ChatMessage systemTurn = ChatMessage.system(
        text: 'You are a helpful writing assistant.',
        timestamp: utcMillis(500),
      );
      await repo.append('p1', systemTurn);

      final List<ChatMessage> loaded = await repo.getAllForProject('p1');
      expect(loaded, hasLength(1));
      expect(loaded.single.role, ChatRole.system);
      expect(loaded.single, equals(systemTurn));
    });

    test('a message with an explicit empty sources list round-trips to empty',
        () async {
      await seedProject('p1');

      final ChatMessage turn = ChatMessage.assistant(
        text: 'No project material found; here is a general answer.',
        timestamp: utcMillis(3000),
        sources: const <ChatMessageSource>[],
      );
      await repo.append('p1', turn);

      final List<ChatMessage> loaded = await repo.getAllForProject('p1');
      expect(loaded, hasLength(1));
      expect(loaded.single.sources, isEmpty);
      expect(loaded.single, equals(turn));
    });
  });

  group('project scoping', () {
    test('getAllForProject only returns the queried project\'s messages',
        () async {
      await seedProject('p1');
      await seedProject('p2');

      await repo.append(
        'p1',
        ChatMessage.user(text: 'p1 message', timestamp: utcMillis(1000)),
      );
      await repo.append(
        'p2',
        ChatMessage.user(text: 'p2 message', timestamp: utcMillis(1000)),
      );
      await repo.append(
        'p2',
        ChatMessage.assistant(
          text: 'p2 reply',
          timestamp: utcMillis(2000),
        ),
      );

      final List<ChatMessage> p1 = await repo.getAllForProject('p1');
      expect(p1, hasLength(1));
      expect(p1.single.text, 'p1 message');

      final List<ChatMessage> p2 = await repo.getAllForProject('p2');
      expect(p2, hasLength(2));
      expect(p2.map((ChatMessage m) => m.text), <String>['p2 message', 'p2 reply']);
    });

    test('clearForProject removes only the target project\'s messages',
        () async {
      await seedProject('p1');
      await seedProject('p2');

      await repo.append(
        'p1',
        ChatMessage.user(text: 'p1 message', timestamp: utcMillis(1000)),
      );
      await repo.append(
        'p2',
        ChatMessage.user(text: 'p2 message', timestamp: utcMillis(1000)),
      );

      await repo.clearForProject('p1');

      expect(await repo.getAllForProject('p1'), isEmpty);

      final List<ChatMessage> p2 = await repo.getAllForProject('p2');
      expect(p2, hasLength(1));
      expect(p2.single.text, 'p2 message');
    });
  });

  group('empty project', () {
    test('getAllForProject returns an empty list for a project with no messages',
        () async {
      await seedProject('p1');
      expect(await repo.getAllForProject('p1'), isEmpty);
    });

    test('getAllForProject returns empty for an unknown project id', () async {
      expect(await repo.getAllForProject('does-not-exist'), isEmpty);
    });

    test('clearForProject on an empty project is a no-op', () async {
      await seedProject('p1');
      await repo.clearForProject('p1');
      expect(await repo.getAllForProject('p1'), isEmpty);
    });
  });

  group('hostile / malformed stored data', () {
    // Inserts a raw row with an arbitrary `sources` column value, bypassing the
    // repository's encoder, to simulate a tampered/corrupt database file.
    Future<void> insertRaw(String projectId, String sourcesColumn) async {
      await db.insert(DatabaseProvider.aiConversationsTable, <String, Object?>{
        AiConversationColumns.id: '\$projectId:1:assistant',
        AiConversationColumns.projectId: projectId,
        AiConversationColumns.role: 'assistant',
        AiConversationColumns.text: 'a reply',
        AiConversationColumns.timestamp: 1000,
        AiConversationColumns.sources: sourcesColumn,
      });
    }

    test('syntactically invalid JSON in sources decodes to empty (no throw)',
        () async {
      await seedProject('p1');
      await insertRaw('p1', '{not valid json');

      final List<ChatMessage> loaded = await repo.getAllForProject('p1');
      expect(loaded, hasLength(1));
      expect(loaded.single.text, 'a reply');
      expect(loaded.single.sources, isEmpty);
    });

    test('structurally wrong JSON (not a list) decodes to empty', () async {
      await seedProject('p2');
      await insertRaw('p2', '{"id":"x","title":"y"}');

      final List<ChatMessage> loaded = await repo.getAllForProject('p2');
      expect(loaded, hasLength(1));
      expect(loaded.single.sources, isEmpty);
    });

    test('list with malformed entries keeps only well-formed sources',
        () async {
      await seedProject('p3');
      // Mix of valid, missing-title, wrong-type, and non-object entries.
      await insertRaw(
        'p3',
        '[{"id":"ok","title":"Good"},{"id":"nope"},42,{"id":1,"title":2}]',
      );

      final List<ChatMessage> loaded = await repo.getAllForProject('p3');
      expect(loaded, hasLength(1));
      expect(loaded.single.sources, hasLength(1));
      expect(loaded.single.sources.single.id, 'ok');
      expect(loaded.single.sources.single.title, 'Good');
    });
  });
}
