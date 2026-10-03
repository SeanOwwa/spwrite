import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spwrite/domain/markdown_document_codec.dart';

/// Regression tests: italic/bold text must survive save + reload even when the
/// selection included surrounding spaces or covered part of a word.
void main() {
  final MarkdownDocumentCodec codec = MarkdownDocumentCodec();

  /// Saves [delta] to Markdown and reloads it.
  Delta roundTrip(Delta delta) =>
      codec.markdownToDelta(codec.deltaToMarkdown(delta));

  /// The italic text segments of [delta], in order.
  List<String> italicRuns(Delta delta) => <String>[
        for (final Operation op in delta.toList())
          if (op.attributes?['italic'] == true) op.data! as String,
      ];

  String plainText(Delta delta) => delta
      .toList()
      .map((Operation op) => op.data is String ? op.data! as String : '')
      .join();

  test('italic sentence selected with its trailing space', () {
    final Delta d = Delta()
      ..insert('Hello ')
      ..insert('a sentence. ', <String, dynamic>{'italic': true})
      ..insert('end\n');
    final Delta back = roundTrip(d);
    expect(italicRuns(back), <String>['a sentence.']);
    expect(plainText(back), 'Hello a sentence. end\n');
  });

  test('italic run with a leading space', () {
    final Delta d = Delta()
      ..insert('Hello')
      ..insert(' a sentence.', <String, dynamic>{'italic': true})
      ..insert(' end\n');
    final Delta back = roundTrip(d);
    expect(italicRuns(back), <String>['a sentence.']);
    expect(plainText(back), 'Hello a sentence. end\n');
  });

  test('italic inside a word', () {
    final Delta d = Delta()
      ..insert('un')
      ..insert('believ', <String, dynamic>{'italic': true})
      ..insert('able\n');
    expect(italicRuns(roundTrip(d)), <String>['believ']);
  });

  test('bold with trailing space', () {
    final Delta d = Delta()
      ..insert('Bold ', <String, dynamic>{'bold': true})
      ..insert('x\n');
    final Delta back = roundTrip(d);
    expect(back.toList().first.attributes, <String, dynamic>{'bold': true});
    expect(plainText(back), 'Bold x\n');
  });

  test('literal underscores the writer typed stay literal', () {
    final Delta d = Delta()..insert('snake_case and _this_\n');
    final Delta back = roundTrip(d);
    expect(plainText(back), 'snake_case and _this_\n');
    expect(italicRuns(back), isEmpty);
  });

  group('documents saved by the old codec are repaired on load', () {
    test('trailing-space italic', () {
      final Delta back = codec.markdownToDelta(r'Hello _a sentence\. _end');
      expect(italicRuns(back), <String>['a sentence.']);
      expect(plainText(back), 'Hello a sentence. end\n');
    });

    test('intraword italic', () {
      expect(italicRuns(codec.markdownToDelta('un_believ_able')),
          <String>['believ']);
    });

    test('underscores in link destinations are untouched', () {
      expect(
        MarkdownDocumentCodec.repairLegacyEmphasis(
            '[l](https://a.com/x_y) text'),
        '[l](https://a.com/x_y) text',
      );
    });
  });
}
