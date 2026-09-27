// Property test for the hierarchy persistence round-trip (writing-app-v2 task 6.5).
//
// Feature: writing-app-v2, Property 1: For any hierarchy of valid Projects, Folders (each belonging to one Project), and Documents (each belonging to one Project and to at most one Folder within it) persisted to the Document_Store, loading them back returns entities equal — across id, name/title, content, timestamps, and relationships (project_id, folder_id) — to those persisted, with none added or lost. This holds for the empty store.
//
// **Validates: Requirements 17.1, 17.2, 17.3, 17.5, 17.6, 17.9, 19.3**
//
// Strategy: generate a compact "hierarchy spec" — a list of project specs,
// each with a list of folder specs and a list of document specs. Each document
// spec carries an index selecting where it lives: the project root (folder_id
// null) or one of that project's folders (folder_id set to the chosen folder's
// id). Timestamps, names, titles, and content are drawn from small varied
// pools that include ties, case variants, and the empty string.
//
// The store round-trip runs inside an async `forAll` block (kiri_check 1.3.1's
// `forAll` block is `FutureOr<void> Function(T)` and is awaited internally, so
// repo calls can be awaited directly). For each generated case a FRESH
// in-memory database is opened via
// `DatabaseProvider.openAppDatabase(overridePath: inMemoryDatabasePath)` so
// cases never leak into each other, and it is closed in `finally`.
//
// After persisting every project (ProjectRepository.create), folder
// (FolderRepository.create), and document (DocumentRepository.create), the test
// reloads each level and asserts:
//   - projects: getById returns each persisted project (field-for-field via
//     `==`, which compares timestamps by ms); getAll returns exactly the same
//     set (none added/lost);
//   - folders: getByProject returns exactly the project's folders, each equal
//     to the persisted folder including projectId;
//   - documents: getByProject returns exactly the project's documents; each
//     document loaded by getById equals the persisted one including projectId
//     and folderId (root == null vs. the folder id).
// The empty store (0 projects) is covered by list minLength 0 and asserts
// getAll() returns empty without error.

import 'package:kiri_check/kiri_check.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:writing_app/data/database_provider.dart';
import 'package:writing_app/data/sqlite_document_repository.dart';
import 'package:writing_app/data/sqlite_folder_repository.dart';
import 'package:writing_app/data/sqlite_project_repository.dart';
import 'package:writing_app/domain/document.dart';
import 'package:writing_app/domain/folder.dart';
import 'package:writing_app/domain/project.dart';

/// A single document's generated data: a name index (into the title pool), a
/// content index (into the content pool), a timestamp offset (ms), and a
/// container selector. [containerSelector] is interpreted at build time modulo
/// (folderCount + 1): 0 means the project root (folder_id null); 1..folderCount
/// selects folder (containerSelector - 1).
typedef DocSpec = ({int titleIdx, int contentIdx, int tsOffset, int containerSelector});

/// A single folder's generated data: a name index and a timestamp offset (ms).
typedef FolderSpec = ({int nameIdx, int tsOffset});

/// A single project's generated data: a name index, a timestamp offset (ms),
/// its folders, and its documents.
typedef ProjectSpec = ({int nameIdx, int tsOffset, List<FolderSpec> folders, List<DocSpec> docs});

void main() {
  // Initialize the FFI in-memory factory so `flutter test` on macOS can open
  // an in-memory SQLite database.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Varied name/title pools: mixed case, duplicates, and the empty string.
  const List<String> namePool = <String>[
    'Alpha',
    'alpha',
    'Beta',
    'gamma',
    'Delta Notes',
    '',
    'Zeta',
    'zeta',
  ];

  // Varied content pool for documents, including empty and multi-line/Markdown.
  const List<String> contentPool = <String>[
    '',
    'plain content',
    '# Heading\n\nSome **bold** text.',
    '- one\n- two\n- three',
    'line with unicode: café — naïve — 你好',
  ];

  // A small base timestamp; per-entity offsets are added so ties and distinct
  // values both occur across a generated hierarchy.
  const int baseMs = 1700000000000;

  Arbitrary<int> tsOffset() => integer(min: 0, max: 6);
  Arbitrary<int> nameIdx() => integer(min: 0, max: namePool.length - 1);
  Arbitrary<int> contentIdx() => integer(min: 0, max: contentPool.length - 1);

  Arbitrary<DocSpec> docSpec() => combine4(
        nameIdx(),
        contentIdx(),
        tsOffset(),
        // Selector 0..8 covers the project root plus up to several folders;
        // it is reduced modulo (folderCount + 1) at build time.
        integer(min: 0, max: 8),
      ).map(
        (r) => (
          titleIdx: r.$1,
          contentIdx: r.$2,
          tsOffset: r.$3,
          containerSelector: r.$4,
        ),
      );

  Arbitrary<FolderSpec> folderSpec() => combine2(
        nameIdx(),
        tsOffset(),
      ).map((r) => (nameIdx: r.$1, tsOffset: r.$2));

  Arbitrary<ProjectSpec> projectSpec() => combine4(
        nameIdx(),
        tsOffset(),
        list(folderSpec(), minLength: 0, maxLength: 3),
        list(docSpec(), minLength: 0, maxLength: 6),
      ).map(
        (r) => (
          nameIdx: r.$1,
          tsOffset: r.$2,
          folders: r.$3,
          docs: r.$4,
        ),
      );

  DateTime tsAt(int offset) =>
      DateTime.fromMillisecondsSinceEpoch(baseMs + offset, isUtc: true);

  property('Property 1: hierarchy persistence round-trip', () {
    forAll(
      // minLength 0 includes the empty-store case.
      list(projectSpec(), minLength: 0, maxLength: 4),
      (List<ProjectSpec> specs) async {
        // A monotonically increasing counter yields globally distinct ids for
        // every project, folder, and document within this case.
        var idCounter = 0;
        String nextId(String prefix) => '$prefix-${idCounter++}';

        // Build the expected in-memory hierarchy from the specs.
        final List<Project> projects = <Project>[];
        // Per project id: its folders and its documents.
        final Map<String, List<Folder>> foldersByProject = <String, List<Folder>>{};
        final Map<String, List<Document>> docsByProject = <String, List<Document>>{};

        for (final ProjectSpec ps in specs) {
          final String projectId = nextId('proj');
          final Project project = Project(
            id: projectId,
            name: namePool[ps.nameIdx],
            createdAt: tsAt(ps.tsOffset),
            modifiedAt: tsAt(ps.tsOffset),
          );
          projects.add(project);

          final List<Folder> folders = <Folder>[];
          for (final FolderSpec fs in ps.folders) {
            folders.add(
              Folder(
                id: nextId('fold'),
                name: namePool[fs.nameIdx],
                projectId: projectId,
                createdAt: tsAt(fs.tsOffset),
                modifiedAt: tsAt(fs.tsOffset),
              ),
            );
          }
          foldersByProject[projectId] = folders;

          final List<Document> docs = <Document>[];
          for (final DocSpec ds in ps.docs) {
            // Reduce the selector modulo (folderCount + 1): 0 -> root, else a
            // folder of this project.
            final int mod = folders.length + 1;
            final int sel = ds.containerSelector % mod;
            final String? folderId = sel == 0 ? null : folders[sel - 1].id;
            docs.add(
              Document(
                id: nextId('doc'),
                title: namePool[ds.titleIdx],
                content: contentPool[ds.contentIdx],
                projectId: projectId,
                folderId: folderId,
                createdAt: tsAt(ds.tsOffset),
                modifiedAt: tsAt(ds.tsOffset),
              ),
            );
          }
          docsByProject[projectId] = docs;
        }

        // Open a FRESH in-memory database for this case so cases never leak
        // into each other.
        final Database db = await DatabaseProvider.openAppDatabase(
          overridePath: inMemoryDatabasePath,
        );
        try {
          final SqliteProjectRepository projectRepo =
              SqliteProjectRepository(db);
          final SqliteFolderRepository folderRepo = SqliteFolderRepository(db);
          final SqliteDocumentRepository documentRepo =
              SqliteDocumentRepository(db);

          // Persist every entity: projects first (folders/documents reference
          // them), then folders, then documents.
          for (final Project p in projects) {
            await projectRepo.create(p);
          }
          for (final List<Folder> folders in foldersByProject.values) {
            for (final Folder f in folders) {
              await folderRepo.create(f);
            }
          }
          for (final List<Document> docs in docsByProject.values) {
            for (final Document d in docs) {
              await documentRepo.create(d);
            }
          }

          // Empty-store case: getAll returns empty without error.
          final List<Project> allProjects = await projectRepo.getAll();
          expect(
            allProjects.length,
            projects.length,
            reason: 'getAll must return exactly the persisted projects '
                '(none added or lost)',
          );
          // getAll returns the same set as persisted (order-independent set
          // equality by entity `==`).
          expect(
            allProjects.toSet(),
            projects.toSet(),
            reason: 'getAll must return the persisted projects field-for-field',
          );

          // Reload each level and assert field-for-field equality including
          // relationships, with none added or lost.
          for (final Project expected in projects) {
            final Project? loaded = await projectRepo.getById(expected.id);
            expect(
              loaded,
              equals(expected),
              reason: 'Project ${expected.id} must round-trip field-for-field',
            );

            final List<Folder> expectedFolders =
                foldersByProject[expected.id]!;
            final List<Folder> loadedFolders =
                await folderRepo.getByProject(expected.id);
            expect(
              loadedFolders.length,
              expectedFolders.length,
              reason: 'Folder count for project ${expected.id} must match '
                  '(none added or lost)',
            );
            expect(
              loadedFolders.toSet(),
              expectedFolders.toSet(),
              reason: 'Folders of project ${expected.id} must round-trip '
                  'field-for-field including projectId',
            );
            // Every loaded folder belongs to the expected project.
            for (final Folder f in loadedFolders) {
              expect(
                f.projectId,
                expected.id,
                reason: 'Loaded folder must retain its project_id relationship',
              );
            }

            final List<Document> expectedDocs = docsByProject[expected.id]!;
            final List<Document> loadedDocs =
                await documentRepo.getByProject(expected.id);
            expect(
              loadedDocs.length,
              expectedDocs.length,
              reason: 'Document count for project ${expected.id} must match '
                  '(none added or lost)',
            );
            expect(
              loadedDocs.toSet(),
              expectedDocs.toSet(),
              reason: 'Documents of project ${expected.id} must round-trip '
                  'field-for-field including project_id and folder_id',
            );
            // Reload each document by id and assert relationships preserved.
            for (final Document expectedDoc in expectedDocs) {
              final Document? loadedDoc =
                  await documentRepo.getById(expectedDoc.id);
              expect(
                loadedDoc,
                equals(expectedDoc),
                reason: 'Document ${expectedDoc.id} must round-trip '
                    'field-for-field',
              );
              expect(
                loadedDoc!.projectId,
                expected.id,
                reason: 'Loaded document must retain its project_id',
              );
              expect(
                loadedDoc.folderId,
                expectedDoc.folderId,
                reason: 'Loaded document must retain its folder_id '
                    '(root == null vs. folder id)',
              );
            }
          }
        } finally {
          await db.close();
        }
      },
      maxExamples: 100,
    );
  });
}
