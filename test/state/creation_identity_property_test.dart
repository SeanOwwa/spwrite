// Property test for creation yielding a unique identifier with equal
// timestamps (writing-app-v2 task 8.2).
//
// Feature: writing-app-v2, Property 2: For any existing set of entities of a given kind (Project, Folder, or Document), creating a new entity produces an identifier that collides with no existing identifier and a last-modified timestamp equal to its creation timestamp.
//
// **Validates: Requirements 2.2, 7.2, 10.1, 10.2**
//
// Strategy: drive the real state-layer creation paths against hand-written
// in-memory fake repositories (Map-backed) that record each created entity.
//   - PROJECT: an `AppNavigationState` over a fake `ProjectRepository`. Create
//     N (1..20) projects via `createProject`. Assert all created project ids
//     are unique and each created Project has `modifiedAt == createdAt`.
//   - FOLDER + DOCUMENT: a `ProjectWorkspaceState` over fake `FolderRepository`
//     and `DocumentRepository`. Create N folders and M documents (both root and
//     in a folder). Assert folder ids unique among folders, document ids unique
//     among documents, and each has `modifiedAt == createdAt`.
//
// Since ids come from UUID v4 the collision chance is ~0; the assertions
// document the invariant across at least 100 generated inputs.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiri_check/kiri_check.dart';
import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';
import 'package:spwrite/domain/folder.dart';
import 'package:spwrite/domain/folder_repository.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/domain/project_repository.dart';
import 'package:spwrite/state/app_navigation_state.dart';
import 'package:spwrite/state/project_workspace_state.dart';

/// A Map-backed [ProjectRepository] whose [create] records the entity so the
/// test can inspect every id and timestamp it produced. Reads/updates are
/// unused by this property but implemented for completeness.
class FakeProjectRepository implements ProjectRepository {
  final Map<String, Project> store = <String, Project>{};

  @override
  Future<Project> create(Project project) async {
    store[project.id] = project;
    return project;
  }

  @override
  Future<void> deleteCascade(String id) async {
    store.remove(id);
  }

  @override
  Future<List<Project>> getAll() async =>
      store.values.toList(growable: false);

  @override
  Future<Project?> getById(String id) async => store[id];

  @override
  Future<void> update(Project project) async {
    store[project.id] = project;
  }
}

/// A Map-backed [FolderRepository] whose [create] records the entity.
class FakeFolderRepository implements FolderRepository {
  final Map<String, Folder> store = <String, Folder>{};

  @override
  Future<Folder> create(Folder folder) async {
    store[folder.id] = folder;
    return folder;
  }

  @override
  Future<void> deleteCascade(String id) async {
    store.remove(id);
  }

  @override
  Future<Folder?> getById(String id) async => store[id];

  @override
  Future<List<Folder>> getByProject(String projectId) async => store.values
      .where((Folder f) => f.projectId == projectId)
      .toList(growable: false);

  @override
  Future<void> update(Folder folder) async {
    store[folder.id] = folder;
  }

  @override
  Future<void> updatePositions(List<Folder> folders) async {
    for (final Folder f in folders) {
      store[f.id] = f;
    }
  }
}

/// A Map-backed [DocumentRepository] whose [create] records the entity.
class FakeDocumentRepository implements DocumentRepository {
  final Map<String, Document> store = <String, Document>{};

  @override
  Future<Document> create(Document doc) async {
    store[doc.id] = doc;
    return doc;
  }

  @override
  Future<void> delete(String id) async {
    store.remove(id);
  }

  @override
  Future<List<Document>> getByContainer(
      String projectId, String? folderId) async {
    return store.values
        .where((Document d) => d.projectId == projectId && d.folderId == folderId)
        .toList(growable: false);
  }

  @override
  Future<List<Document>> getByProject(String projectId) async => store.values
      .where((Document d) => d.projectId == projectId)
      .toList(growable: false);

  @override
  Future<Document?> getById(String id) async => store[id];

  @override
  Future<void> update(Document doc) async {
    store[doc.id] = doc;
  }

  @override
  Future<void> updatePositions(List<Document> documents) async {
    for (final Document d in documents) {
      store[d.id] = d;
    }
  }
}

void main() {
  group('Property 2: Creation yields a unique identifier with equal timestamps',
      () {
    property('projects created via AppNavigationState', () {
      forAll(
        integer(min: 1, max: 20),
        (int count) async {
          final FakeProjectRepository repo = FakeProjectRepository();
          final AppNavigationState state =
              AppNavigationState(repo, (Project p) => ChangeNotifier());

          for (var i = 0; i < count; i++) {
            await state.createProject('Valid Name');
          }

          final List<Project> created = repo.store.values.toList();

          // Every creation succeeded.
          expect(created.length, count,
              reason: 'Expected $count projects to be created');

          // No id collides with any other.
          final Set<String> ids = created.map((Project p) => p.id).toSet();
          expect(ids.length, created.length,
              reason: 'Project ids must be unique with no collisions');

          // Each created entity has modifiedAt == createdAt.
          for (final Project p in created) {
            expect(
              p.modifiedAt.millisecondsSinceEpoch,
              p.createdAt.millisecondsSinceEpoch,
              reason: 'Project ${p.id} must have modifiedAt == createdAt',
            );
          }

          state.dispose();
        },
        maxExamples: 100,
      );
    });

    property('folders and documents created via ProjectWorkspaceState', () {
      forAll(
        combine2(
          integer(min: 1, max: 20),
          integer(min: 1, max: 20),
        ),
        ((int, int) counts) async {
          final (int folderCount, int docCount) = counts;

          final Project project = Project.create(
            id: 'project-under-test',
            name: 'Project',
            now: DateTime.now().toUtc(),
          );
          final FakeFolderRepository folderRepo = FakeFolderRepository();
          final FakeDocumentRepository docRepo = FakeDocumentRepository();
          final ProjectWorkspaceState workspace =
              ProjectWorkspaceState(project, folderRepo, docRepo);

          // Create folders.
          for (var i = 0; i < folderCount; i++) {
            await workspace.createFolder('F');
          }

          final List<Folder> createdFolders = folderRepo.store.values.toList();
          expect(createdFolders.length, folderCount,
              reason: 'Expected $folderCount folders to be created');

          // Folder ids unique among folders.
          final Set<String> folderIds =
              createdFolders.map((Folder f) => f.id).toSet();
          expect(folderIds.length, createdFolders.length,
              reason: 'Folder ids must be unique with no collisions');

          // Each folder has modifiedAt == createdAt.
          for (final Folder f in createdFolders) {
            expect(
              f.modifiedAt.millisecondsSinceEpoch,
              f.createdAt.millisecondsSinceEpoch,
              reason: 'Folder ${f.id} must have modifiedAt == createdAt',
            );
          }

          // Pick an existing folder id (if any) to target some documents.
          final String? someFolderId =
              createdFolders.isNotEmpty ? createdFolders.first.id : null;

          // Create documents: alternate between root and a folder.
          for (var i = 0; i < docCount; i++) {
            if (i.isEven || someFolderId == null) {
              await workspace.createDocument();
            } else {
              await workspace.createDocument(folderId: someFolderId);
            }
          }

          final List<Document> createdDocs = docRepo.store.values.toList();
          expect(createdDocs.length, docCount,
              reason: 'Expected $docCount documents to be created');

          // Document ids unique among documents.
          final Set<String> docIds =
              createdDocs.map((Document d) => d.id).toSet();
          expect(docIds.length, createdDocs.length,
              reason: 'Document ids must be unique with no collisions');

          // Each document has modifiedAt == createdAt.
          for (final Document d in createdDocs) {
            expect(
              d.modifiedAt.millisecondsSinceEpoch,
              d.createdAt.millisecondsSinceEpoch,
              reason: 'Document ${d.id} must have modifiedAt == createdAt',
            );
          }

          workspace.dispose();
        },
        maxExamples: 100,
      );
    });
  });
}
