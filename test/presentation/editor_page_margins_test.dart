/// Widget tests for the editor page's margins: one inch at the top and bottom
/// (in normal and focus mode), and no scrolling beyond what the text needs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations, QuillEditor;
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

  Future<void> pumpEditor(WidgetTester tester, String content) async {
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
            .copyWith(content: content),
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

  EdgeInsetsGeometry? padding(WidgetTester tester) =>
      tester.widget<QuillEditor>(find.byType(QuillEditor)).config.padding;

  ScrollPosition editorScroll(WidgetTester tester) => tester
      .state<ScrollableState>(find
          .descendant(
            of: find.byType(QuillEditor),
            matching: find.byType(Scrollable),
          )
          .first)
      .position;

  testWidgets('the page has a 1-inch top and bottom margin',
      (WidgetTester tester) async {
    await pumpEditor(tester, 'Some words.');
    final EdgeInsets p = padding(tester)! as EdgeInsets;
    expect(EditorView.pageMarginVertical, 96);
    expect(p.top, EditorView.pageMarginVertical);
    expect(p.bottom, EditorView.pageMarginVertical);

    ws.toggleFocusMode();
    await tester.pump();
    final EdgeInsets focus = padding(tester)! as EdgeInsets;
    expect(focus.top, EditorView.pageMarginVertical);
    expect(focus.bottom, EditorView.pageMarginVertical);
  });

  testWidgets('a short document does not scroll', (WidgetTester tester) async {
    await pumpEditor(tester, 'Some words.');
    expect(editorScroll(tester).maxScrollExtent, 0);
  });

  testWidgets('a long document scrolls only to its last line plus the margin',
      (WidgetTester tester) async {
    await pumpEditor(
      tester,
      List<String>.generate(60, (int i) => 'Paragraph $i.').join('\n\n'),
    );
    final ScrollPosition position = editorScroll(tester);
    expect(position.maxScrollExtent, greaterThan(0));
    // Scrolled to the end, the space below the text is the bottom margin, not
    // a share of the window height.
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    final Rect editor = tester.getRect(find.byType(QuillEditor));
    final Rect lastLine = tester.getRect(
      find.textContaining('Paragraph 59.', findRichText: true),
    );
    expect(
      editor.bottom - lastLine.bottom,
      closeTo(EditorView.pageMarginVertical, 2),
    );
  });
}
