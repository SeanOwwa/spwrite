/// Widget tests for [NameField], the reusable inline editable Name/Title field
/// (Req 2.1, 3.1, 7.1, 8.1, 12.1).
///
/// These cover the generalized behavior the Dashboard and Project_Sidebar rely
/// on: pre-fill + full text selection on open, confirm/cancel affordances,
/// label-aware validation messaging ("Name" vs "Title"), and trimming before
/// the confirm callback fires.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spwrite/presentation/name_field.dart';

/// Pumps a [NameField] wrapped in the minimal MaterialApp scaffolding it needs.
Future<void> _pumpField(
  WidgetTester tester, {
  required String initialValue,
  required NameFieldLabel label,
  required void Function(String) onConfirm,
  required VoidCallback onCancel,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: NameField(
          initialValue: initialValue,
          label: label,
          onConfirm: onConfirm,
          onCancel: onCancel,
        ),
      ),
    ),
  );
  // Let the post-frame focus request run.
  await tester.pump();
}

void main() {
  group('NameField', () {
    testWidgets('opens pre-filled with the value fully selected', (
      WidgetTester tester,
    ) async {
      await _pumpField(
        tester,
        initialValue: 'My Project',
        label: NameFieldLabel.name,
        onConfirm: (_) {},
        onCancel: () {},
      );

      final EditableText editable = tester.widget<EditableText>(
        find.byType(EditableText),
      );
      expect(editable.controller.text, 'My Project');
      expect(editable.controller.selection.baseOffset, 0);
      expect(
        editable.controller.selection.extentOffset,
        'My Project'.length,
      );
    });

    testWidgets('confirm forwards the trimmed value', (
      WidgetTester tester,
    ) async {
      String? confirmed;
      await _pumpField(
        tester,
        initialValue: '',
        label: NameFieldLabel.name,
        onConfirm: (String v) => confirmed = v,
        onCancel: () {},
      );

      await tester.enterText(find.byType(TextField), '  Draft Ideas  ');
      await tester.tap(find.byIcon(Icons.check));
      await tester.pump();

      expect(confirmed, 'Draft Ideas');
    });

    testWidgets('confirm on an empty value shows the required message and does '
        'not fire onConfirm', (WidgetTester tester) async {
      bool confirmedCalled = false;
      await _pumpField(
        tester,
        initialValue: '   ',
        label: NameFieldLabel.name,
        onConfirm: (_) => confirmedCalled = true,
        onCancel: () {},
      );

      await tester.tap(find.byIcon(Icons.check));
      await tester.pump();

      expect(confirmedCalled, isFalse);
      expect(find.text('A name is required.'), findsOneWidget);
    });

    testWidgets('confirm on an over-length value shows the maximum message', (
      WidgetTester tester,
    ) async {
      bool confirmedCalled = false;
      await _pumpField(
        tester,
        initialValue: '',
        label: NameFieldLabel.name,
        onConfirm: (_) => confirmedCalled = true,
        onCancel: () {},
      );

      await tester.enterText(find.byType(TextField), 'a' * 256);
      await tester.tap(find.byIcon(Icons.check));
      await tester.pump();

      expect(confirmedCalled, isFalse);
      expect(find.text('Name exceeds the 255 character maximum.'), findsOneWidget);
    });

    testWidgets('the Title label produces title-worded validation messages', (
      WidgetTester tester,
    ) async {
      await _pumpField(
        tester,
        initialValue: '',
        label: NameFieldLabel.title,
        onConfirm: (_) {},
        onCancel: () {},
      );

      await tester.tap(find.byIcon(Icons.check));
      await tester.pump();

      expect(find.text('A title is required.'), findsOneWidget);
    });

    testWidgets('cancel fires onCancel and not onConfirm', (
      WidgetTester tester,
    ) async {
      bool cancelled = false;
      bool confirmedCalled = false;
      await _pumpField(
        tester,
        initialValue: 'Keep Me',
        label: NameFieldLabel.name,
        onConfirm: (_) => confirmedCalled = true,
        onCancel: () => cancelled = true,
      );

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(cancelled, isTrue);
      expect(confirmedCalled, isFalse);
    });

    testWidgets('editing after an error clears the inline message', (
      WidgetTester tester,
    ) async {
      await _pumpField(
        tester,
        initialValue: '',
        label: NameFieldLabel.name,
        onConfirm: (_) {},
        onCancel: () {},
      );

      await tester.tap(find.byIcon(Icons.check));
      await tester.pump();
      expect(find.text('A name is required.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Now valid');
      await tester.pump();
      expect(find.text('A name is required.'), findsNothing);
    });
  });
}
