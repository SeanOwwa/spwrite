import 'package:flutter/foundation.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/data/guides/guide_installer.dart';
import 'package:spwrite/data/sqlite_app_settings_repository.dart';
import 'package:spwrite/data/sqlite_document_repository.dart';
import 'package:spwrite/data/sqlite_folder_repository.dart';
import 'package:spwrite/data/sqlite_project_repository.dart';
import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/guides/built_in_guide.dart';
import 'package:spwrite/domain/guides/developer_guide.dart';
import 'package:spwrite/domain/guides/user_guide.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/state/app_navigation_state.dart';
import 'package:spwrite/state/guide_visibility_state.dart';
import 'package:spwrite/state/project_workspace_state.dart';

/// An in-memory preference that can be told to fail.
class _MemoryPreference implements GuideVisibilityPreference {
  bool? stored;
  bool failSave = false;

  @override
  Future<bool> load() async => stored ?? true;

  @override
  Future<void> save(bool visible) async {
    if (failSave) throw StateError('disk full');
    stored = visible;
  }
}

void main() {
  const BuiltInGuideCatalog catalog =
      BuiltInGuideCatalog(<BuiltInGuide>[UserGuide(), DeveloperGuide()]);

  late Database db;
  late SqliteProjectRepository projects;
  late SqliteFolderRepository folders;
  late SqliteDocumentRepository documents;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await DatabaseProvider.openAppDatabase(
      overridePath: inMemoryDatabasePath,
    );
    projects = SqliteProjectRepository(db);
    folders = SqliteFolderRepository(db);
    documents = SqliteDocumentRepository(db);
    await GuideInstaller(
      projects: projects,
      folders: folders,
      documents: documents,
      settings: SqliteAppSettingsRepository(db),
    ).installAll(catalog);
  });

  tearDown(() => db.close());

  AppNavigationState navigation() => AppNavigationState(
        projects,
        (Project p) => ChangeNotifier(),
        builtInPolicy: catalog,
      );

  group('AppNavigationState', () {
    test('lists guides first in catalog order, apart from user projects',
        () async {
      final AppNavigationState nav = navigation();
      await nav.loadProjects();
      await nav.createProject('My novel');

      expect(nav.builtInProjects.map((Project p) => p.name),
          <String>['User Guide', 'Developer Guide']);
      expect(nav.userProjects.map((Project p) => p.name),
          <String>['My novel']);
    });

    test('guides cannot be deleted or renamed', () async {
      final AppNavigationState nav = navigation();
      await nav.loadProjects();

      await nav.deleteProject('builtin.user-guide');
      await nav.renameProject('builtin.developer-guide', 'Hacked');

      expect(await projects.getById('builtin.user-guide'), isNotNull);
      expect((await projects.getById('builtin.developer-guide'))?.name,
          'Developer Guide');
      expect(nav.builtInProjects, hasLength(2));
    });

    test('user projects can still be deleted', () async {
      final AppNavigationState nav = navigation();
      await nav.loadProjects();
      await nav.createProject('Scratch');
      final String id = nav.userProjects.single.id;
      await nav.deleteProject(id);
      expect(nav.userProjects, isEmpty);
    });
  });

  group('read-only workspace', () {
    test('every editing action is ignored for a guide', () async {
      final Project guide = (await projects.getById('builtin.user-guide'))!;
      final ProjectWorkspaceState ws = ProjectWorkspaceState(
        guide,
        folders,
        documents,
        isReadOnly: true,
      );
      await ws.loadContents();
      final List<Document> before = await documents.getByProject(guide.id);
      final int folderCount = (await folders.getByProject(guide.id)).length;
      final Document first = before.first;

      await ws.selectDocument(first.id);
      ws.onContentChanged(Delta()..insert('overwritten\n'));
      await ws.saveNow();
      await ws.createDocument();
      await ws.createFolder('New');
      await ws.renameDocument(first.id, 'Renamed');
      await ws.deleteDocument(first.id);
      await ws.deleteFolder((await folders.getByProject(guide.id)).first.id);

      final List<Document> after = await documents.getByProject(guide.id);
      expect(after.length, before.length);
      final Document reread = (await documents.getById(first.id))!;
      expect(reread.title, first.title);
      expect(reread.content, first.content);
      expect((await folders.getByProject(guide.id)).length, folderCount);
      ws.dispose();
    });
  });

  group('GuideVisibilityState', () {
    test('loads the saved choice and remembers changes', () async {
      final _MemoryPreference pref = _MemoryPreference()..stored = false;
      final GuideVisibilityState state = GuideVisibilityState(pref);
      expect(state.visible, isTrue);
      await state.load();
      expect(state.visible, isFalse);

      await state.setVisible(true);
      expect(state.visible, isTrue);
      expect(pref.stored, isTrue);
    });

    test('a failed save still changes the switch for this session', () async {
      final _MemoryPreference pref = _MemoryPreference()..failSave = true;
      final GuideVisibilityState state = GuideVisibilityState(pref);
      await state.setVisible(false);
      expect(state.visible, isFalse);
    });
  });
}
