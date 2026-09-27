/// Widget tests for [FolderTile], one Folder row in the Project_Sidebar tree
/// together with its revealed-when-expanded Documents.
///
/// These cover the tile's observable behaviour over a real
/// [ProjectWorkspaceState] (backed by Map fake repositories): the Name and
/// trailing controls render (Req 8.1, 9.1, 10.2); the chevron toggles
/// expand/collapse and reveals/hides the contained documents (Req 6.4, 6.5); an
/// expanded folder with zero documents shows the empty indicator (Req 6.10);
/// contained documents are rendered via the supplied row builder; the rename
/// field is shown in place while renaming (Req 8.1); and the create-document,
/// rename, and delete controls dispatch as expected.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:writing_app/domain/document.dart';
import 'package:writing_app/domain/document_repository.dart';
import 'package:writing_app/domain/folder.dart';
import 'package:writing_app/domain/folder_repository.dart';
import 'package:writing_app/domain/project.dart';
import 'package:writing_app/presentation/document_list_item.dart';
import 'package:writing_app/presentation/folder_tile.dart';
import 'package:writing_app/state/project_workspace_state.dart';

// ---------------------------------------------------------------------------
// Map-backed fake repositories (only the methods the workspace uses here are
// meaningfully implemented; the rest throw so accidental use surfaces loudly).
// ---------------------------------------------------------------------------

class _FakeFolderRepository implements FolderRepository {
  _FakeFolderRepository(this._folders, this._documents);

  final Map<String, Folder> _folders;
  final Map<String, Document> _documents;

  @override
  Future<List<Folder>> getByProject(String projectId) async => _folders.values
      .where((Folder f) => f.projectId == projectId)
      .toList(growable: false);

  @override
  Future<Folder?> getById(String id) async => _folders[id];

  @override
  Future<Folder> create(Folder folder) async {
    _folders[folder.id] = folder;
    return folder;
  }

  @override
  Future<void> update(Folder folder) async {
    _folders[folder.id] = folder;
  }

  @override
  Future<void> deleteCascade(String id) async {
    _folders.remove(id);
    _documents.removeWhere((_, Document d) => d.folderId == id);
  }
}

class _FakeDocumentRepository implements DocumentRepository {
  _FakeDocumentRepository(this._documents);

  final Map<String, Document> _documents;

  @override
  Future<List<Document>> getByProject(String projectId) async =>
      _documents.values
          .where((Document d) => d.projectId == projectId)
          .toList(growable: false);

  @override
  Future<List<Document>> getByContainer(
    String projectId,
    String? folderId,
  ) async =>
      _documents.values
          .where((Document d) =>
              d.projectId == projectId && d.folderId == folderId)
          .toList(growable: false);

  @override
  Future<Document?> getById(String id) async => _documents[id];

  @override
  Future<Document> create(Document doc) async {
    _documents[doc.id] = doc;
    return doc;
  }

  @override
  Future<void> update(Document doc) async {
    _documents[doc.id] = doc;
  }

  @override
  Future<void> delete(String id) async {
    _documents.remove(id);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const String _projectId = 'project-1';
const String _folderId = 'folder-1';

Project _project() => Project.create(
      id: _projectId,
      name: 'Project',
      now: DateTime.utc(2024, 1, 1),
    );

Folder _folder({String name = 'Chapters'}) => Folder.create(
      id: _folderId,
      projectId: _projectId,
      name: name,
      now: DateTime.utc(2024, 1, 1),
    );

Document _doc({
  required String id,
  required String title,
  String? folderId = _folderId,
}) =>
    Document(
      id: id,
      projectId: _projectId,
      folderId: folderId,
      title: title,
      content: '',
      createdAt: DateTime.utc(2024, 1, 1),
      modifiedAt: DateTime.utc(2024, 1, 1),
    );

/// Builds a [ProjectWorkspaceState] over the given folders/documents, loads its
/// contents, and returns it ready to observe.
Future<ProjectWorkspaceState> _buildLoadedState({
  List<Folder> folders = const <Folder>[],
  List<Document> documents = const <Document>[],
}) async {
  final Map<String, Folder> folderStore = <String, Folder>{
    for (final Folder f in folders) f.id: f,
  };
  final Map<String, Document> docStore = <String, Document>{
    for (final Document d in documents) d.id: d,
  };
  final ProjectWorkspaceState state = ProjectWorkspaceState(
    _project(),
    _FakeFolderRepository(folderStore, docStore),
    _FakeDocumentRepository(docStore),
  );
  await state.loadContents();
  return state;
}

/// Pumps a [FolderTile] for [folder] inside a provider hosting [state].
Future<void> _pumpTile(
  WidgetTester tester, {
  required ProjectWorkspaceState state,
  required Folder folder,
  bool isRenaming = false,
  Widget? renameField,
  VoidCallback? onRename,
  VoidCallback? onDelete,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChangeNotifierProvider<ProjectWorkspaceState>.value(
          value: state,
          child: SingleChildScrollView(
            child: FolderTile(
              folder: folder,
              isRenaming: isRenaming,
              renameField: renameField,
              onRename: onRename ?? () {},
              onDelete: onDelete ?? () {},
              documentRowBuilder: (BuildContext context, Document doc) =>
                  DocumentListItem(document: doc),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('FolderTile', () {
    testWidgets('renders the folder name and the three trailing controls', (
      WidgetTester tester,
    ) async {
      final ProjectWorkspaceState state =
          await _buildLoadedState(folders: <Folder>[_folder()]);
      await _pumpTile(tester, state: state, folder: _folder());

      expect(find.text('Chapters'), findsOneWidget);
      expect(find.byIcon(Icons.note_add_outlined), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('collapsed folder hides its documents; chevron expands to '
        'reveal them', (WidgetTester tester) async {
      final ProjectWorkspaceState state = await _buildLoadedState(
        folders: <Folder>[_folder()],
        documents: <Document>[_doc(id: 'd1', title: 'Alpha')],
      );
      await _pumpTile(tester, state: state, folder: _folder());

      // Collapsed by default: the document is not shown (Req 6.5).
      expect(find.text('Alpha'), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      // Expand via the chevron (Req 6.4).
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pump();

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
    });

    testWidgets('tapping the row toggles expand/collapse', (
      WidgetTester tester,
    ) async {
      final ProjectWorkspaceState state = await _buildLoadedState(
        folders: <Folder>[_folder()],
        documents: <Document>[_doc(id: 'd1', title: 'Alpha')],
      );
      await _pumpTile(tester, state: state, folder: _folder());

      await tester.tap(find.text('Chapters'));
      await tester.pump();
      expect(find.text('Alpha'), findsOneWidget);

      await tester.tap(find.text('Chapters'));
      await tester.pump();
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets('expanded empty folder shows the empty indicator (Req 6.10)', (
      WidgetTester tester,
    ) async {
      final ProjectWorkspaceState state =
          await _buildLoadedState(folders: <Folder>[_folder()]);
      state.toggleFolder(_folderId);
      await _pumpTile(tester, state: state, folder: _folder());

      expect(find.text('This folder is empty.'), findsOneWidget);
    });

    testWidgets('contained documents render in the ordered position when '
        'expanded', (WidgetTester tester) async {
      final ProjectWorkspaceState state = await _buildLoadedState(
        folders: <Folder>[_folder()],
        documents: <Document>[
          _doc(id: 'd1', title: 'Alpha'),
          _doc(id: 'd2', title: 'Beta'),
        ],
      );
      state.toggleFolder(_folderId);
      await _pumpTile(tester, state: state, folder: _folder());

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('This folder is empty.'), findsNothing);
    });

    testWidgets('create-document control creates a document in this folder and '
        'auto-expands it (Req 10.2, 10.6)', (WidgetTester tester) async {
      final ProjectWorkspaceState state =
          await _buildLoadedState(folders: <Folder>[_folder()]);
      await _pumpTile(tester, state: state, folder: _folder());

      await tester.tap(find.byIcon(Icons.note_add_outlined));
      await tester.pumpAndSettle();

      expect(state.documentsIn(_folderId).length, 1);
      expect(state.isExpanded(_folderId), isTrue);
      expect(state.activeDocument, isNotNull);
      expect(state.activeDocument!.folderId, _folderId);
    });

    testWidgets('rename control invokes onRename', (WidgetTester tester) async {
      bool renameCalled = false;
      final ProjectWorkspaceState state =
          await _buildLoadedState(folders: <Folder>[_folder()]);
      await _pumpTile(
        tester,
        state: state,
        folder: _folder(),
        onRename: () => renameCalled = true,
      );

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump();

      expect(renameCalled, isTrue);
    });

    testWidgets('delete control invokes onDelete', (WidgetTester tester) async {
      bool deleteCalled = false;
      final ProjectWorkspaceState state =
          await _buildLoadedState(folders: <Folder>[_folder()]);
      await _pumpTile(
        tester,
        state: state,
        folder: _folder(),
        onDelete: () => deleteCalled = true,
      );

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump();

      expect(deleteCalled, isTrue);
    });

    testWidgets('while renaming, the rename field replaces the name and row '
        'controls (Req 8.1)', (WidgetTester tester) async {
      final ProjectWorkspaceState state =
          await _buildLoadedState(folders: <Folder>[_folder()]);
      await _pumpTile(
        tester,
        state: state,
        folder: _folder(),
        isRenaming: true,
        renameField: const TextField(
          key: Key('rename-field'),
        ),
      );

      expect(find.byKey(const Key('rename-field')), findsOneWidget);
      // The Name text and the trailing controls are not shown while renaming.
      expect(find.text('Chapters'), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });
  });
}
