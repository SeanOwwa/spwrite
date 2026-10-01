import 'package:flutter_test/flutter_test.dart';
import 'package:spwrite/domain/ai/chat_message.dart';

void main() {
  group('ChatMessageSource', () {
    test('construction stores id and title', () {
      const source = ChatMessageSource(id: 'doc-1', title: 'Chapter One');

      expect(source.id, 'doc-1');
      expect(source.title, 'Chapter One');
    });

    test('value equality: same fields are equal and share a hashCode', () {
      const a = ChatMessageSource(id: 'doc-1', title: 'Chapter One');
      const b = ChatMessageSource(id: 'doc-1', title: 'Chapter One');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differing id or title are not equal', () {
      const base = ChatMessageSource(id: 'doc-1', title: 'Chapter One');
      const diffId = ChatMessageSource(id: 'doc-2', title: 'Chapter One');
      const diffTitle = ChatMessageSource(id: 'doc-1', title: 'Chapter Two');

      expect(base == diffId, isFalse);
      expect(base == diffTitle, isFalse);
    });

    test('copyWith replaces only the given fields', () {
      const base = ChatMessageSource(id: 'doc-1', title: 'Chapter One');

      expect(base.copyWith(), base);
      expect(
        base.copyWith(id: 'doc-9'),
        const ChatMessageSource(id: 'doc-9', title: 'Chapter One'),
      );
      expect(
        base.copyWith(title: 'Renamed'),
        const ChatMessageSource(id: 'doc-1', title: 'Renamed'),
      );
    });
  });

  group('ChatMessage construction', () {
    test('default constructor sets fields and a non-null unmodifiable sources', () {
      final ts = DateTime.utc(2024, 1, 2, 3, 4, 5);
      final msg = ChatMessage(
        role: ChatRole.assistant,
        text: 'hello',
        timestamp: ts,
      );

      expect(msg.role, ChatRole.assistant);
      expect(msg.text, 'hello');
      expect(msg.timestamp, ts);
      expect(msg.sources, isEmpty);
      expect(
        () => msg.sources.add(const ChatMessageSource(id: 'x', title: 'y')),
        throwsUnsupportedError,
      );
    });

    test('sources passed in are preserved in order and unmodifiable', () {
      final ts = DateTime.utc(2024, 1, 1);
      const s1 = ChatMessageSource(id: 'a', title: 'A');
      const s2 = ChatMessageSource(id: 'b', title: 'B');
      final msg = ChatMessage(
        role: ChatRole.assistant,
        text: 'grounded',
        timestamp: ts,
        sources: const [s1, s2],
      );

      expect(msg.sources, [s1, s2]);
      expect(() => msg.sources.clear(), throwsUnsupportedError);
    });

    test('user factory builds a user turn with no sources', () {
      final ts = DateTime.utc(2024, 2, 2, 2);
      final msg = ChatMessage.user(text: 'a question', timestamp: ts);

      expect(msg.role, ChatRole.user);
      expect(msg.text, 'a question');
      expect(msg.timestamp, ts);
      expect(msg.sources, isEmpty);
    });

    test('assistant factory carries grounding sources', () {
      final ts = DateTime.utc(2024, 3, 3, 3);
      const source = ChatMessageSource(id: 'doc-1', title: 'Notes');
      final msg = ChatMessage.assistant(
        text: 'an answer',
        timestamp: ts,
        sources: const [source],
      );

      expect(msg.role, ChatRole.assistant);
      expect(msg.text, 'an answer');
      expect(msg.sources, [source]);
    });

    test('assistant factory without sources yields an empty list', () {
      final ts = DateTime.utc(2024, 3, 4);
      final msg = ChatMessage.assistant(text: 'no grounding', timestamp: ts);

      expect(msg.role, ChatRole.assistant);
      expect(msg.sources, isEmpty);
    });

    test('system factory builds a system turn with no sources', () {
      final ts = DateTime.utc(2024, 4, 4, 4);
      final msg = ChatMessage.system(text: 'prime', timestamp: ts);

      expect(msg.role, ChatRole.system);
      expect(msg.text, 'prime');
      expect(msg.timestamp, ts);
      expect(msg.sources, isEmpty);
    });
  });

  group('ChatMessage equality and hashCode', () {
    ChatMessage base({
      ChatRole role = ChatRole.assistant,
      String text = 'hi',
      DateTime? timestamp,
      List<ChatMessageSource>? sources,
    }) {
      return ChatMessage(
        role: role,
        text: text,
        timestamp: timestamp ?? DateTime.utc(2024, 6, 6, 6, 6, 6),
        sources: sources,
      );
    }

    test('identical field values are equal and share a hashCode', () {
      final a = base(sources: const [ChatMessageSource(id: 'a', title: 'A')]);
      final b = base(sources: const [ChatMessageSource(id: 'a', title: 'A')]);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differing role are not equal', () {
      expect(base(role: ChatRole.user) == base(role: ChatRole.assistant),
          isFalse);
    });

    test('differing text are not equal', () {
      expect(base(text: 'one') == base(text: 'two'), isFalse);
    });

    test('timestamps equal at UTC-millisecond granularity are equal', () {
      // Same instant expressed in different timezones compares equal.
      final utc = DateTime.utc(2024, 6, 6, 12, 0, 0);
      final a = base(timestamp: utc);
      final b = base(timestamp: utc.toLocal());

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('timestamps differing by a whole millisecond are not equal', () {
      final a = base(timestamp: DateTime.utc(2024, 6, 6, 12, 0, 0, 0));
      final b = base(timestamp: DateTime.utc(2024, 6, 6, 12, 0, 0, 1));

      expect(a == b, isFalse);
    });

    test('sources equality is order-sensitive', () {
      const s1 = ChatMessageSource(id: 'a', title: 'A');
      const s2 = ChatMessageSource(id: 'b', title: 'B');
      final ordered = base(sources: const [s1, s2]);
      final reordered = base(sources: const [s2, s1]);

      expect(ordered == reordered, isFalse);
    });

    test('differing source count are not equal', () {
      const s1 = ChatMessageSource(id: 'a', title: 'A');
      final one = base(sources: const [s1]);
      final none = base();

      expect(one == none, isFalse);
    });
  });

  group('ChatMessage copyWith', () {
    final ts = DateTime.utc(2024, 7, 7, 7, 7, 7);
    ChatMessage base() => ChatMessage(
          role: ChatRole.user,
          text: 'original',
          timestamp: ts,
          sources: const [ChatMessageSource(id: 'a', title: 'A')],
        );

    test('no arguments returns an equal copy', () {
      expect(base().copyWith(), base());
    });

    test('replaces role only', () {
      final copy = base().copyWith(role: ChatRole.assistant);

      expect(copy.role, ChatRole.assistant);
      expect(copy.text, 'original');
      expect(copy.timestamp, ts);
      expect(copy.sources, base().sources);
    });

    test('replaces text only', () {
      final copy = base().copyWith(text: 'edited');

      expect(copy.text, 'edited');
      expect(copy.role, ChatRole.user);
    });

    test('replaces timestamp only', () {
      final newTs = DateTime.utc(2025, 1, 1);
      final copy = base().copyWith(timestamp: newTs);

      expect(copy.timestamp, newTs);
    });

    test('replaces the whole sources list', () {
      const s2 = ChatMessageSource(id: 'b', title: 'B');
      final copy = base().copyWith(sources: const [s2]);

      expect(copy.sources, const [s2]);
      expect(copy.sources, isNot(base().sources));
    });

    test('omitting sources keeps the existing list', () {
      final copy = base().copyWith(text: 'edited');

      expect(copy.sources, base().sources);
    });
  });
}
