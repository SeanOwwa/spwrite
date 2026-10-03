import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spwrite/domain/markdown_document_codec.dart';
import 'package:spwrite/presentation/editor_shortcuts.dart';

/// A controller holding [text] with the caret at [caret] (end by default).
QuillController controllerWith(String text, {int? caret}) => QuillController(
      document: Document.fromDelta(Delta()..insert('$text\n')),
      selection: TextSelection.collapsed(offset: caret ?? text.length),
    );

void main() {
  test('third hyphen turns "--" into an em dash', () {
    final QuillController c = controllerWith('Wait--');
    expect(applyEmDash(c), isTrue);
    expect(c.document.toPlainText(), 'Wait\u2014\n');
    expect(c.selection, const TextSelection.collapsed(offset: 5));
  });

  test('works mid-sentence and keeps the text after the caret', () {
    final QuillController c = controllerWith('a--b', caret: 3);
    expect(applyEmDash(c), isTrue);
    expect(c.document.toPlainText(), 'a\u2014b\n');
  });

  test('one or two hyphens stay as typed', () {
    expect(applyEmDash(controllerWith('a-')), isFalse);
    expect(applyEmDash(controllerWith('a')), isFalse);
    expect(applyEmDash(controllerWith('')), isFalse);
  });

  test('ignored while text is selected', () {
    final QuillController c = QuillController(
      document: Document.fromDelta(Delta()..insert('ab--\n')),
      selection: const TextSelection(baseOffset: 0, extentOffset: 4),
    );
    expect(applyEmDash(c), isFalse);
  });

  test('em dash survives save and reload', () {
    final MarkdownDocumentCodec codec = MarkdownDocumentCodec();
    final Delta d = Delta()..insert('One\u2014two\n');
    final Delta back = codec.markdownToDelta(codec.deltaToMarkdown(d));
    expect(back.toList().map((Operation o) => o.data).join(), 'One\u2014two\n');
  });
}
