/// Widget tests for drag & drop in the Project_Sidebar: rows are dragged from
/// anywhere on the row (there is no drag handle), documents move into and out
/// of folders, and folders and documents reorder at the top level.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/folder.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/presentation/project_sidebar_view.dart';
import 'package:spwrite/state/project_workspace_state.dart';
import 'package:spwrite/theme/app_theme.dart';

import '../support/fake_workspace_repositories.dart';

const String _projectId = 'p';
final DateTime _now = DateTime.utc(2026, 1, 1);

Folder _folder(String id, String name, int position) => Folder.create(
      id: id,
      projectId: _projectId,
      name: name,
      now: _now,
      position: position,
    );

Document _doc(String id, String title, int position, {String? folderId}) =>
    Document(
      id: id,
      projectId: _projectId,
      folderId: folderId,
      title: title,
      content: '',
      createdAt: _now,
      modifiedAt: _now,
      position: position,
    );

/// Top level: [Chapters folder (Scene 1, Scene 2)], Notes, Ideas.
Future<ProjectWorkspaceState> _pumpSidebar(
  WidgetTester tester, {
  bool expandFolder = true,
}) async {
  final Map<String, Document> docs = <String, Document>{
    for (final Document d in <Document>[
      _doc('s1', 'Scene 1', 0, folderId: 'f'),
      _doc('s2', 'Scene 2', 1, folderId: 'f'),
      _doc('notes', 'Notes', 1),
      _doc('ideas', 'Ideas', 2),
    ])
      d.id: d,
  };
  final Map<String, Folder> folders = <String, Folder>{
    'f': _folder('f', 'Chapters', 0),
  };
  final ProjectWorkspaceState state = ProjectWorkspaceState(
    Project.create(id: _projectId, name: 'Novel', now: _now),
    FakeFolderRepository(folders, docs),
    FakeDocumentRepository(docs),
  );
  await state.loadContents();
  if (expandFolder) state.toggleFolder('f');

  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<ProjectWorkspaceState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: ProjectSidebarView()),
      ),
    ),
  );
  await tester.pump();
  return state;
}

/// Presses at [from], drags past the touch slop, moves to [to], and drops.
Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final TestGesture gesture = await tester.startGesture(from);
  await gesture.moveBy(const Offset(0, 20));
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.moveBy(const Offset(0, 1));
  await tester.pump();
  await gesture.up();
  await tester.pump();
  await tester.pump();
}

Rect _row(WidgetTester tester, String key) =>
    tester.getRect(find.byKey(ValueKey<String>(key)));

Offset _upper(Rect r) => Offset(r.center.dx, r.top + r.height * 0.15);
Offset _lower(Rect r) => Offset(r.center.dx, r.bottom - r.height * 0.15);

List<String> _rootOrder(ProjectWorkspaceState s) =>
    s.rootItems().map((RootItem it) => it.id).toList();

List<String> _folderOrder(ProjectWorkspaceState s, String folderId) =>
    s.documentsIn(folderId).map((Document d) => d.id).toList();

void main() {
  testWidgets('rows have no separate drag handle', (WidgetTester tester) async {
    await _pumpSidebar(tester);
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
    expect(find.byType(ReorderableListView), findsNothing);
  });

  testWidgets('a top-level document dropped on a folder row moves into it',
      (WidgetTester tester) async {
    final ProjectWorkspaceState s = await _pumpSidebar(tester);
    await _drag(
      tester,
      tester.getCenter(find.text('Notes')),
      tester.getCenter(find.text('Chapters')),
    );
    expect(_folderOrder(s, 'f'), <String>['s1', 's2', 'notes']);
    expect(_rootOrder(s), <String>['f', 'ideas']);
  });

  testWidgets('a folder document dropped below the list moves to the top level',
      (WidgetTester tester) async {
    final ProjectWorkspaceState s = await _pumpSidebar(tester);
    await _drag(
      tester,
      tester.getCenter(find.text('Scene 1')),
      tester.getCenter(find.byKey(const ValueKey<String>('sidebar-end-drop-area'))),
    );
    expect(_folderOrder(s, 'f'), <String>['s2']);
    expect(_rootOrder(s), <String>['f', 'notes', 'ideas', 's1']);
    expect(s.rootDocuments().map((Document d) => d.id), contains('s1'));
  });

  testWidgets('a folder document dropped between top-level rows moves out there',
      (WidgetTester tester) async {
    final ProjectWorkspaceState s = await _pumpSidebar(tester);
    await _drag(
      tester,
      tester.getCenter(find.text('Scene 2')),
      _upper(_row(tester, 'root-doc-ideas')),
    );
    expect(_folderOrder(s, 'f'), <String>['s1']);
    expect(_rootOrder(s), <String>['f', 'notes', 's2', 'ideas']);
  });

  testWidgets('documents reorder inside a folder', (WidgetTester tester) async {
    final ProjectWorkspaceState s = await _pumpSidebar(tester);
    await _drag(
      tester,
      tester.getCenter(find.text('Scene 2')),
      _upper(_row(tester, 'folder-doc-s1')),
    );
    expect(_folderOrder(s, 'f'), <String>['s2', 's1']);
  });

  testWidgets('a folder is dragged by its row to a new top-level position',
      (WidgetTester tester) async {
    final ProjectWorkspaceState s =
        await _pumpSidebar(tester, expandFolder: false);
    await _drag(
      tester,
      tester.getCenter(find.text('Chapters')),
      _lower(_row(tester, 'root-doc-ideas')),
    );
    expect(_rootOrder(s), <String>['notes', 'ideas', 'f']);
    // The folder keeps its documents.
    expect(_folderOrder(s, 'f'), <String>['s1', 's2']);
  });

  testWidgets('top-level documents reorder by dragging the row',
      (WidgetTester tester) async {
    final ProjectWorkspaceState s = await _pumpSidebar(tester);
    await _drag(
      tester,
      tester.getCenter(find.text('Ideas')),
      _upper(_row(tester, 'root-doc-notes')),
    );
    expect(_rootOrder(s), <String>['f', 'ideas', 'notes']);
  });

  testWidgets('dropping a row back on itself changes nothing',
      (WidgetTester tester) async {
    final ProjectWorkspaceState s = await _pumpSidebar(tester);
    await _drag(
      tester,
      tester.getCenter(find.text('Notes')),
      tester.getCenter(find.text('Notes')),
    );
    expect(_rootOrder(s), <String>['f', 'notes', 'ideas']);
  });

  testWidgets('a tap on a draggable row still opens the document',
      (WidgetTester tester) async {
    final ProjectWorkspaceState s = await _pumpSidebar(tester);
    await tester.tap(find.text('Ideas'));
    await tester.pump();
    expect(s.activeDocument?.id, 'ideas');
  });

  testWidgets('a long-press on a draggable row still reveals its controls',
      (WidgetTester tester) async {
    await _pumpSidebar(tester);
    expect(find.byTooltip('Rename document'), findsNothing);
    await tester.longPress(find.text('Ideas'));
    await tester.pump();
    expect(find.byTooltip('Rename document'), findsOneWidget);
  });
}
