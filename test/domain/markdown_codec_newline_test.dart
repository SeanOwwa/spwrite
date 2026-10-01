// Regression: pressing Enter for blank lines (and the Tab indent) was lost
// after save + reload, because Markdown collapses blank lines and reads a 4+
// space indent as a code block.
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spwrite/domain/markdown_document_codec.dart';

void main() {
  final MarkdownDocumentCodec codec = MarkdownDocumentCodec();

  String roundTrip(Delta d) {
    final Delta back = codec.markdownToDelta(codec.deltaToMarkdown(d));
    return back
        .toList()
        .map((Operation o) => o.data is String ? o.data! as String : '')
        .join();
  }

  test('a single Enter keeps two lines', () {
    expect(roundTrip(Delta()..insert('One\nTwo\n')), 'One\nTwo\n');
  });

  test('blank lines from repeated Enter survive', () {
    expect(roundTrip(Delta()..insert('One\n\nTwo\n')), 'One\n\nTwo\n');
    expect(roundTrip(Delta()..insert('A\n\n\n\nB\n')), 'A\n\n\n\nB\n');
  });

  test('a trailing blank line survives', () {
    expect(roundTrip(Delta()..insert('Text\n\n')), 'Text\n\n');
  });

  test('a Tab indent stays text, not a code block', () {
    final Delta d = Delta()..insert('          Indented\nNext\n');
    final Delta back = codec.markdownToDelta(codec.deltaToMarkdown(d));
    expect(roundTrip(d), '          Indented\nNext\n');
    expect(
      back.toList().any((Operation o) =>
          o.attributes?.containsKey('code-block') ?? false),
      isFalse,
    );
  });

  test('formatting and blank lines together', () {
    final Delta d = Delta()
      ..insert('Title')
      ..insert('\n', <String, dynamic>{'header': 1})
      ..insert('\n')
      ..insert('bold', <String, dynamic>{'bold': true})
      ..insert(' text\n');
    final Delta back = codec.markdownToDelta(codec.deltaToMarkdown(d));
    expect(back.toList().first.data, 'Title');
    expect(back.toList()[1].attributes, <String, dynamic>{'header': 1});
    expect(roundTrip(d), 'Title\n\nbold text\n');
  });
}
