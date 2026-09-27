// Feature: writing-app-v2, Property 11: For any hierarchy of Projects, Folders, and Documents, deleting a Project removes that Project together with exactly its Folders and its Documents and nothing else; and deleting a Folder removes that Folder together with exactly the Documents it contains and nothing else. Every entity outside the deleted subtree — including every other Project and its contents — remains present and unchanged.
//
// Validates: Requirements 4.2, 9.2
//
// This test drives the real transactional cascade in the repositories
// (SqliteProjectRepository.deleteCascade / SqliteFolderRepository.deleteCascade)
// against an in-memory SQLite database created with the sqflite_common_ffi
// factory (the same setup used by the hierarchy round-trip test). It does NOT
// rely on the ON DELETE CASCADE foreign keys — those are skipped on web — but
// on the explicit, all-or-nothing deletes the repositories perform inside a
// transaction.
//
// For each generated case it:
//   1. Builds a fresh in-memory database and persists a multi-project hierarchy
//      (>= 2 projects, each with folders plus documents at the root and inside
//      folders, all with distinct ids).
//   2. Snapshots the full set of persisted entities.
//   3. Randomly picks a delete target that is EITHER a whole project OR a single
//      folder, and calls the matching deleteCascade.
//   4. Computes the expected surviving set (everything outside the deleted
//      subtree) and asserts the live database matches it exactly — the target
//      subtree is gone, and every other entity remains present and unchanged.
//
// Async is handled by passing an `async` block to `forAll`: kiri_check 1.3.1
// declares the block as `FutureOr<void> Function(T)` and awaits it internally
// (see StatelessProperty in property_base.dart: `await block(example)`), so the
// database work per case is awaited before the next example runs. A fresh
// in-memory database is opened per case and closed in a `finally` block.

import 'package:kiri_check/kiri_check.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/data/sqlite_document_repository.dart';
import 'package:spwrite/data/sqlite_folder_repository.dart';
import 'package:spwrite/data/sqlite_project_repository.dart';
import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/folder.dart';
import 'package:spwrite/domain/project.dart';

// ---------------------------------------------------------------------------
// Generation specs
//
// A spec describes the SHAPE of a hierarchy with small integer counts. The
// concrete entities (with distinct, deterministic ids) are materialized from
// the spec when the case runs, so ids never collide across projects/folders.
// ---------------------------------------------------------------------------

/// Shape of one project: how many folders it has, how many root-level documents
/// it holds, and how many documents live in each of its folders (one entry per
/// folder).
typedef _ProjectSpec = ({
  int folderCount,
  int rootDocCount,
  List<int> docsPerFolder,
});

/// A whole hierarchy: the list of project specs and the choice of delete
/// target. `deleteProject` picks whether the target is a project (true) or a
/// folder (false); the two selector ints choose which project / which folder
/// (taken modulo the available count so any value is valid).
typedef _HierarchySpec = ({
  List<_ProjectSpec> projects,
  bool deleteProject,
  int projectSelector,
  int folderSelector,
});

/// Small counts keep each case fast while still producing multi-project,
/// multi-folder, multi-document hierarchies with documents at the root and in
/// folders.
Arbitrary<_ProjectSpec> _projectSpecArbitrary() {
  return combine3(
    integer(min: 0, max: 3), // folderCount
    integer(min: 0, max: 3), // rootDocCount
    list(integer(min: 0, max: 3), maxLength: 3), // docsPerFolder (per folder)
  ).map(
    (t) => (
      folderCount: t.$1,
      rootDocCount: t.$2,
      docsPerFolder: t.$3,
    ),
  );
}

Arbitrary<_HierarchySpec> _hierarchyArbitrary() {
  return combine4(
    // At least two projects so "every OTHER project is untouched" is always
    // exercised.
    list(_projectSpecArbitrary(), minLength: 2, maxLength: 4),
    boolean(),
    integer(min: 0, max: 1000000),
    integer(min: 0, max: 1000000),
  ).map(
    (t) => (
      projects: t.$1,
      deleteProject: t.$2,
      projectSelector: t.$3,
      folderSelector: t.$4,
    ),
  );
}

// ---------------------------------------------------------------------------
// Materialized hierarchy
// ---------------------------------------------------------------------------

/// The concrete entities built from a [_HierarchySpec], with distinct ids.
class _Hierarchy {
  _Hierarchy(this.projects, this.folders, this.documents);

  final List<Project> projects;
  final List<Folder> folders;
  final List<Document> documents;
}

/// Materializes distinct, deterministic entities from [spec]. Ids embed the
/// project / folder / document indices so every id across the whole hierarchy
/// is unique. Timestamps vary per entity so surviving entities can be compared
/// field-for-field (not just by id).
_Hierarchy _materialize(_HierarchySpec spec) {
  final projects = <Project>[];
  final folders = <Folder>[];
  final documents = <Document>[];

  var clock = 1000; // ms since epoch, incremented so entities differ.
  DateTime nextTs() => DateTime.fromMillisecondsSinceEpoch(clock += 1000, isUtc: true);

  for (var p = 0; p < spec.projects.length; p++) {
    final ps = spec.projects[p];
    final projectId = 'project-$p';
    projects.add(
      Project(
        id: projectId,
        name: 'Project $p',
        createdAt: nextTs(),
        modifiedAt: nextTs(),
      ),
    );

    // Root-level documents (folderId == null).
    for (var d = 0; d < ps.rootDocCount; d++) {
      documents.add(
        Document(
          id: 'doc-$p-root-$d',
          title: 'Root Doc $p-$d',
          content: 'content $p-root-$d',
          projectId: projectId,
          folderId: null,
          createdAt: nextTs(),
          modifiedAt: nextTs(),
        ),
      );
    }

    // Folders and their documents.
    for (var f = 0; f < ps.folderCount; f++) {
      final folderId = 'folder-$p-$f';
      folders.add(
        Folder(
          id: folderId,
          name: 'Folder $p-$f',
          projectId: projectId,
          createdAt: nextTs(),
          modifiedAt: nextTs(),
        ),
      );

      // docsPerFolder may be shorter/longer than folderCount; default to 0.
      final inFolderCount =
          f < ps.docsPerFolder.length ? ps.docsPerFolder[f] : 0;
      for (var d = 0; d < inFolderCount; d++) {
        documents.add(
          Document(
            id: 'doc-$p-$f-$d',
            title: 'Folder Doc $p-$f-$d',
            content: 'content $p-$f-$d',
            projectId: projectId,
            folderId: folderId,
            createdAt: nextTs(),
            modifiedAt: nextTs(),
          ),
        );
      }
    }
  }

  return _Hierarchy(projects, folders, documents);
}

// ---------------------------------------------------------------------------
// Live-database readers
// ---------------------------------------------------------------------------

/// Reads every project, folder, and document currently in the database, keyed
/// by id, so the live state can be compared against the expected surviving set.
Future<
    ({
      Map<String, Project> projects,
      Map<String, Folder> folders,
      Map<String, Document> documents,
    })> _readAll(
  Database db,
  SqliteProjectRepository projectRepo,
  SqliteFolderRepository folderRepo,
  SqliteDocumentRepository docRepo,
  List<Project> allProjects,
) async {
  final projects = <String, Project>{};
  final folders = <String, Folder>{};
  final documents = <String, Document>{};

  for (final p in allProjects) {
    final live = await projectRepo.getById(p.id);
    if (live != null) {
      projects[live.id] = live;
      for (final f in await folderRepo.getByProject(p.id)) {
        folders[f.id] = f;
      }
      for (final d in await docRepo.getByProject(p.id)) {
        documents[d.id] = d;
      }
    }
  }

  return (projects: projects, folders: folders, documents: documents);
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  property('Property 11: cascade delete removes exactly the target subtree', () {
    forAll(
      _hierarchyArbitrary(),
      (_HierarchySpec spec) async {
        final hierarchy = _materialize(spec);

        // Fresh in-memory database per case.
        final db = await DatabaseProvider.openAppDatabase(
          overridePath: inMemoryDatabasePath,
        );
        try {
          final projectRepo = SqliteProjectRepository(db);
          final folderRepo = SqliteFolderRepository(db);
          final docRepo = SqliteDocumentRepository(db);

          // Persist the whole hierarchy.
          for (final p in hierarchy.projects) {
            await projectRepo.create(p);
          }
          for (final f in hierarchy.folders) {
            await folderRepo.create(f);
          }
          for (final d in hierarchy.documents) {
            await docRepo.create(d);
          }

          // Snapshot the full set before deletion.
          final projectsById = <String, Project>{
            for (final p in hierarchy.projects) p.id: p,
          };
          final foldersById = <String, Folder>{
            for (final f in hierarchy.folders) f.id: f,
          };
          final documentsById = <String, Document>{
            for (final d in hierarchy.documents) d.id: d,
          };

          // Choose the delete target and compute the expected surviving set.
          final Set<String> expectedGoneProjects = <String>{};
          final Set<String> expectedGoneFolders = <String>{};
          final Set<String> expectedGoneDocuments = <String>{};

          if (spec.deleteProject) {
            // Target a whole project.
            final target = hierarchy
                .projects[spec.projectSelector % hierarchy.projects.length];
            expectedGoneProjects.add(target.id);
            for (final f in hierarchy.folders) {
              if (f.projectId == target.id) expectedGoneFolders.add(f.id);
            }
            for (final d in hierarchy.documents) {
              if (d.projectId == target.id) expectedGoneDocuments.add(d.id);
            }

            await projectRepo.deleteCascade(target.id);
          } else {
            // Target a single folder. If no folders exist anywhere, fall back
            // to deleting a project so the case still exercises a cascade.
            if (hierarchy.folders.isEmpty) {
              final target = hierarchy
                  .projects[spec.projectSelector % hierarchy.projects.length];
              expectedGoneProjects.add(target.id);
              for (final f in hierarchy.folders) {
                if (f.projectId == target.id) expectedGoneFolders.add(f.id);
              }
              for (final d in hierarchy.documents) {
                if (d.projectId == target.id) expectedGoneDocuments.add(d.id);
              }
              await projectRepo.deleteCascade(target.id);
            } else {
              final target = hierarchy
                  .folders[spec.folderSelector % hierarchy.folders.length];
              expectedGoneFolders.add(target.id);
              for (final d in hierarchy.documents) {
                if (d.folderId == target.id) expectedGoneDocuments.add(d.id);
              }
              await folderRepo.deleteCascade(target.id);
            }
          }

          // Compute the expected survivors from the snapshot.
          final expectedProjects = <String, Project>{
            for (final e in projectsById.entries)
              if (!expectedGoneProjects.contains(e.key)) e.key: e.value,
          };
          final expectedFolders = <String, Folder>{
            for (final e in foldersById.entries)
              if (!expectedGoneFolders.contains(e.key)) e.key: e.value,
          };
          final expectedDocuments = <String, Document>{
            for (final e in documentsById.entries)
              if (!expectedGoneDocuments.contains(e.key)) e.key: e.value,
          };

          // Read the live database.
          final live = await _readAll(
            db,
            projectRepo,
            folderRepo,
            docRepo,
            hierarchy.projects,
          );

          // 1) The target subtree is gone: none of the deleted ids remain.
          for (final id in expectedGoneProjects) {
            expect(
              await projectRepo.getById(id),
              isNull,
              reason: 'deleted project $id should be gone',
            );
          }
          for (final id in expectedGoneFolders) {
            expect(
              await folderRepo.getById(id),
              isNull,
              reason: 'deleted folder $id should be gone',
            );
          }
          for (final id in expectedGoneDocuments) {
            expect(
              await docRepo.getById(id),
              isNull,
              reason: 'deleted document $id should be gone',
            );
          }

          // When a project was deleted, its folders and documents are wiped:
          // getByProject returns empty for that project.
          for (final id in expectedGoneProjects) {
            expect(
              await folderRepo.getByProject(id),
              isEmpty,
              reason: 'folders of deleted project $id should be empty',
            );
            expect(
              await docRepo.getByProject(id),
              isEmpty,
              reason: 'documents of deleted project $id should be empty',
            );
          }

          // 2) Exactly the survivors remain — same id sets, nothing extra,
          //    nothing missing.
          expect(
            live.projects.keys.toSet(),
            expectedProjects.keys.toSet(),
            reason: 'surviving project ids must match exactly',
          );
          expect(
            live.folders.keys.toSet(),
            expectedFolders.keys.toSet(),
            reason: 'surviving folder ids must match exactly',
          );
          expect(
            live.documents.keys.toSet(),
            expectedDocuments.keys.toSet(),
            reason: 'surviving document ids must match exactly',
          );

          // 3) Every survivor is unchanged, field-for-field (equality covers
          //    id, name/title, content, timestamps, and relationships).
          for (final e in expectedProjects.entries) {
            expect(
              live.projects[e.key],
              e.value,
              reason: 'surviving project ${e.key} must be unchanged',
            );
          }
          for (final e in expectedFolders.entries) {
            expect(
              live.folders[e.key],
              e.value,
              reason: 'surviving folder ${e.key} must be unchanged',
            );
          }
          for (final e in expectedDocuments.entries) {
            expect(
              live.documents[e.key],
              e.value,
              reason: 'surviving document ${e.key} must be unchanged',
            );
          }
        } finally {
          await db.close();
        }
      },
      maxExamples: 100,
    );
  });
}
