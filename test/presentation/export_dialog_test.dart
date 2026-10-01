import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spwrite/domain/app_settings_repository.dart';
import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';
import 'package:spwrite/domain/folder.dart';
import 'package:spwrite/domain/folder_repository.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/presentation/export/export_dialog.dart';
import 'package:spwrite/presentation/export/export_location_service.dart';
import 'package:spwrite/state/project_workspace_state.dart';

class _MemorySettings implements AppSettingsRepository {
  final Map<String, String> values = <String, String>{};
  @override
  Future<String?> getString(String key) async => values[key];
  @override
  Future<void> setString(String key, String value) async => values[key] = value;
  @override
  Future<void> remove(String key) async => values.remove(key);
}

class _Folders implements FolderRepository {
  @override
  Future<List<Folder>> getByProject(String projectId) async => <Folder>[];
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Documents implements DocumentRepository {
  _Documents(this.docs);
  final List<Document> docs;
  @override
  Future<List<Document>> getByProject(String projectId) async => docs;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  final DateTime now = DateTime.utc(2026, 1, 1);
  final Project project = Project.create(id: 'p1', name: 'My Book', now: now);

  late ProjectWorkspaceState state;
  late _MemorySettings settings;
  late List<String> written;
  late List<String> revealed;
  String? saveAnswer;

  setUp(() async {
    state = ProjectWorkspaceState(
      project,
      _Folders(),
      _Documents(<Document>[
        Document(
          id: 'd1',
          title: 'Chapter One',
          content: 'Hello.',
          projectId: 'p1',
          createdAt: now,
          modifiedAt: now,
        ),
      ]),
    );
    await state.loadContents();
    settings = _MemorySettings();
    written = <String>[];
    revealed = <String>[];
    saveAnswer = null;
  });

  Future<void> openDialog(WidgetTester tester) async {
    final ExportLocationService service = ExportLocationService(
      settings: settings,
      directoryExists: (String path) async => path == '/fallback',
      writeBytes: (String path, List<int> bytes) async => written.add(path),
      fallbackDirectory: () async => '/fallback',
      pickSaveLocation: (
              {required String suggestedName,
              String? initialDirectory}) async =>
          saveAnswer,
      pickDirectory: ({String? initialDirectory}) async => null,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ExportDialog(
                state: state,
                locationService: service,
                revealInFolder: (String p) async => revealed.add(p),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chapter One'));
    await tester.pump();
  }

  testWidgets('shows the destination and cancel keeps the dialog open',
      (WidgetTester tester) async {
    await openDialog(tester);
    expect(find.text('Save to: /fallback'), findsOneWidget);

    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    expect(written, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Export documents'), findsOneWidget);
    // Still usable: the Export button is enabled again.
    expect(find.text('Export'), findsOneWidget);
  });

  testWidgets('saves to the chosen path and offers Show in folder',
      (WidgetTester tester) async {
    saveAnswer = '/out/Book';
    await openDialog(tester);

    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    expect(written, <String>['/out/Book.docx']);
    expect(find.text('Export documents'), findsNothing);
    expect(
        find.text('Exported 1 document(s) to /out/Book.docx'), findsOneWidget);
    expect(settings.values[ExportLocationService.lastFolderKey], '/out');

    await tester.tap(find.text('Show in folder'));
    await tester.pump();
    expect(revealed, <String>['/out/Book.docx']);
  });
}
