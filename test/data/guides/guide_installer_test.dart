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
import 'package:spwrite/domain/folder.dart';
import 'package:spwrite/domain/guides/built_in_guide.dart';
import 'package:spwrite/domain/guides/developer_guide.dart';
import 'package:spwrite/domain/guides/user_guide.dart';
import 'package:spwrite/domain/markdown_document_codec.dart';
import 'package:spwrite/domain/project.dart';

/// A tiny guide whose content can be changed between installs.
class _TestGuide extends BuiltInGuide {
  const _TestGuide(this.body, {this.title = 'Test guide'});
  final String body;
  final String title;

  @override
  String get projectId => 'builtin.test';
  @override
  String get name => title;
  @override
  List<GuideDocument> get rootDocuments =>
      <GuideDocument>[GuideDocument(title: 'Intro', markdown: body)];
  @override
  List<GuideFolder> get folders => const <GuideFolder>[
        GuideFolder(name: 'Part', documents: <GuideDocument>[
          GuideDocument(title: 'One', markdown: 'First.'),
          GuideDocument(title: 'Two', markdown: 'Second.'),
        ]),
      ];
}

void main() {
  late Database db;
  late SqliteProjectRepository projects;
  late SqliteFolderRepository folders;
  late SqliteDocumentRepository documents;
  late SqliteAppSettingsRepository settings;
  late GuideInstaller installer;

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
    settings = SqliteAppSettingsRepository(db);
    installer = GuideInstaller(
      projects: projects,
      folders: folders,
      documents: documents,
      settings: settings,
    );
  });

  tearDown(() => db.close());

  test('installs a missing guide with its folders and documents in order',
      () async {
    expect(await installer.install(const _TestGuide('Hello.')), isTrue);

    final Project? project = await projects.getById('builtin.test');
    expect(project?.name, 'Test guide');

    final List<Document> root =
        await documents.getByContainer('builtin.test', null);
    expect(root.map((Document d) => d.title), <String>['Intro']);
    expect(root.single.content, 'Hello.');

    final List<Folder> part = await folders.getByProject('builtin.test');
    expect(part.map((Folder f) => f.name), <String>['Part']);
    final List<Document> inPart =
        await documents.getByContainer('builtin.test', part.single.id);
    expect(inPart.map((Document d) => d.title), <String>['One', 'Two']);
  });

  test('a second launch with unchanged content writes nothing', () async {
    await installer.install(const _TestGuide('Hello.'));
    expect(await installer.install(const _TestGuide('Hello.')), isFalse);
    expect(await documents.getByProject('builtin.test'), hasLength(3));
  });

  test('changed content replaces the old guide without duplicates', () async {
    await installer.install(const _TestGuide('Old.'));
    expect(
      await installer.install(const _TestGuide('New.', title: 'Renamed')),
      isTrue,
    );

    expect((await projects.getById('builtin.test'))?.name, 'Renamed');
    final List<Document> all = await documents.getByProject('builtin.test');
    expect(all, hasLength(3));
    expect(all.where((Document d) => d.title == 'Intro').single.content,
        'New.');
    expect(await folders.getByProject('builtin.test'), hasLength(1));
  });

  test('a guide deleted behind the app is reinstalled', () async {
    await installer.install(const _TestGuide('Hello.'));
    await projects.deleteCascade('builtin.test');
    expect(await installer.install(const _TestGuide('Hello.')), isTrue);
    expect(await documents.getByProject('builtin.test'), hasLength(3));
  });

  test('installAll keeps going when one guide fails', () async {
    final List<String> failed = <String>[];
    await db.close();
    // A closed database makes every write fail.
    await installer.installAll(
      const BuiltInGuideCatalog(<BuiltInGuide>[UserGuide(), DeveloperGuide()]),
      onError: (BuiltInGuide g, Object _) => failed.add(g.name),
    );
    expect(failed, <String>['User Guide', 'Developer Guide']);
    db = await DatabaseProvider.openAppDatabase(
      overridePath: inMemoryDatabasePath,
    );
  });

  test('the visibility preference defaults to shown and is remembered',
      () async {
    final SettingsGuideVisibilityPreference pref =
        SettingsGuideVisibilityPreference(settings);
    expect(await pref.load(), isTrue);
    await pref.save(false);
    expect(await pref.load(), isFalse);
  });

  group('shipped guides', () {
    const List<BuiltInGuide> shipped = <BuiltInGuide>[
      UserGuide(),
      DeveloperGuide(),
    ];
    final MarkdownDocumentCodec codec = MarkdownDocumentCodec();

    test('have unique, non-UUID project ids', () {
      final Set<String> ids =
          shipped.map((BuiltInGuide g) => g.projectId).toSet();
      expect(ids, hasLength(shipped.length));
      expect(ids.every((String id) => id.startsWith('builtin.')), isTrue);
    });

    for (final BuiltInGuide guide in shipped) {
      test('${guide.name} renders without stray Markdown markers', () {
        final List<GuideDocument> docs = <GuideDocument>[
          ...guide.rootDocuments,
          for (final GuideFolder f in guide.folders) ...f.documents,
        ];
        expect(docs, isNotEmpty);
        for (final GuideDocument doc in docs) {
          final Delta delta = codec.markdownToDelta(doc.markdown);
          final String text = delta
              .toList()
              .map((Operation o) => o.data is String ? o.data! as String : '')
              .join();
          expect(text.trim(), isNotEmpty, reason: doc.title);
          // Leftover markers mean the Markdown did not parse as intended.
          expect(text.contains('*'), isFalse, reason: doc.title);
          expect(text.contains(r'\'), isFalse, reason: doc.title);
          expect(RegExp(r'^#', multiLine: true).hasMatch(text), isFalse,
              reason: doc.title);
        }
      });

      test('${guide.name} installs into a real database', () async {
        expect(await installer.install(guide), isTrue);
        expect(await documents.getByProject(guide.projectId), isNotEmpty);
      });
    }
  });
}
