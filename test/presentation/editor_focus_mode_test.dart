/// Widget tests for focus mode in the editor: the shortcut turns it on, and
/// Esc turns it off while typing in the page (flutter_quill's own Esc binding
/// used to swallow the key).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/data/sqlite_document_repository.dart';
import 'package:spwrite/data/sqlite_folder_repository.dart';
import 'package:spwrite/data/sqlite_project_repository.dart';
import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/presentation/editor_view.dart';
import 'package:spwrite/state/project_workspace_state.dart';
import 'package:spwrite/theme/app_theme.dart';

void main() {
  late Database db;
  late ProjectWorkspaceState ws;

  Future<void> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      db = await DatabaseProvider.openAppDatabase(
        overridePath: inMemoryDatabasePath,
      );
      final DateTime now = DateTime.utc(2026);
      final Project p = await SqliteProjectRepository(db)
          .create(Project.create(id: 'p', name: 'P', now: now));
      final SqliteDocumentRepository docs = SqliteDocumentRepository(db);
      await docs.create(
        Document.newDocument(id: 'd', projectId: 'p', now: now)
            .copyWith(content: 'Some words.'),
      );
      ws = ProjectWorkspaceState(p, SqliteFolderRepository(db), docs);
      await ws.loadContents();
      await ws.selectDocument('d');
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<ProjectWorkspaceState>.value(
        value: ws,
        child: MaterialApp(
          theme: AppTheme.dark,
          localizationsDelegates:
              FlutterQuillLocalizations.localizationsDelegates,
          supportedLocales: FlutterQuillLocalizations.supportedLocales,
          home: const Scaffold(body: EditorView()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  tearDown(() async => db.close());

  testWidgets('Esc in the page leaves focus mode', (WidgetTester tester) async {
    await pumpEditor(tester);

    // Put the caret in the page, as when the writer is typing.
    await tester.tap(find.text('Some words.', findRichText: true));
    await tester.pump();

    // Ctrl+Shift+F (tests run as a non-Apple platform) turns focus mode on.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(ws.focusMode, isTrue);
    expect(find.textContaining('Esc to leave focus mode'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(ws.focusMode, isFalse);
    expect(find.textContaining('Esc to leave focus mode'), findsNothing);
  });

  testWidgets('Esc outside focus mode does nothing special',
      (WidgetTester tester) async {
    await pumpEditor(tester);
    await tester.tap(find.text('Some words.', findRichText: true));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(ws.focusMode, isFalse);
  });
}
