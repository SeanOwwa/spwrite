// Property test for document creation scoped to its container
// (writing-app-v2 task 9.5).
//
// Feature: writing-app-v2, Property 3: For any Active_Project and any target container (the project root, or a specific Folder of that project), creating a Document sets the Document's project_id to the Active_Project and its folder_id to null for the root or to that Folder's id otherwise.
//
// **Validates: Requirements 10.1, 10.2**
//
// Strategy: fix a single Active_Project ('proj-1') and construct a
// [ProjectWorkspaceState] over hand-written in-memory fake repositories. For
// each generated case pick a target container — either the project root
// (folderId == null) or a specific folder id drawn from a small pre-seeded set
// — and call `createDocument(folderId: ...)`. Because the property is about
// what `createDocument` *stores*, an arbitrary non-null folder id is a valid
// target, but drawing from a fixed set keeps the assertions concrete.
//
// After creation the test asserts, over at least 100 generated inputs:
//   - the workspace exposes a non-null Active_Document;
//   - its projectId equals the Active_Project's id ('proj-1');
//   - its folderId is null for the root case, or the chosen folder id
//     otherwise;
//   - the fake DocumentRepository received exactly one `create` whose stored
//     entity carries the same projectId/folderId (the stored entity matches
//     what the workspace exposes).
//
// The fakes store entities in a Map and implement the repository interfaces
// directly; `create` records and returns the entity, keeping the test
// deterministic and fast with no database.

import 'package:kiri_check/kiri_check.dart';
import 'package:test/test.dart';

import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';
import 'package:spwrite/domain/folder.dart';
import 'package:spwrite/domain/folder_repository.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/state/project_workspace_state.dart';

/// Hand-written in-memory [FolderRepository]. Stores folders in a Map keyed by
/// id; only the reads used by the workspace under test are needed here.
class _FakeFolderRepository implements FolderRepository {
  final Map<String, Folder> _store = <String, Folder>{};

  void seed(Folder folder) => _store[folder.id] = folder;

  @override
  Future<Folder> create(Folder folder) async {
    _store[folder.id] = folder;
    return folder;
  }

  @override
  Future<void> deleteCascade(String id) async {
    _store.remove(id);
  }

  @override
  Future<Folder?> getById(String id) async => _store[id];

  @override
  Future<List<Folder>> getByProject(String projectId) async => _store.values
      .where((Folder f) => f.projectId == projectId)
      .toList(growable: false);

  @override
  Future<void> update(Folder folder) async {
    _store[folder.id] = folder;
  }

  @override
  Future<void> updatePositions(List<Folder> folders) async {
    for (final Folder f in folders) {
      _store[f.id] = f;
    }
  }
}

/// Hand-written in-memory [DocumentRepository]. Stores documents in a Map keyed
/// by id and records every `create` call so the test can assert the stored
/// entity matches what the workspace exposes.
class _FakeDocumentRepository implements DocumentRepository {
  final Map<String, Document> _store = <String, Document>{};

  /// Every document passed to [create], in call order.
  final List<Document> created = <Document>[];

  @override
  Future<Document> create(Document doc) async {
    created.add(doc);
    _store[doc.id] = doc;
    return doc;
  }

  @override
  Future<void> delete(String id) async {
    _store.remove(id);
  }

  @override
  Future<Document?> getById(String id) async => _store[id];

  @override
  Future<List<Document>> getByContainer(
    String projectId,
    String? folderId,
  ) async =>
      _store.values
          .where((Document d) =>
              d.projectId == projectId && d.folderId == folderId)
          .toList(growable: false);

  @override
  Future<List<Document>> getByProject(String projectId) async => _store.values
      .where((Document d) => d.projectId == projectId)
      .toList(growable: false);

  @override
  Future<void> update(Document doc) async {
    _store[doc.id] = doc;
  }

  @override
  Future<void> updatePositions(List<Document> documents) async {
    for (final Document d in documents) {
      _store[d.id] = d;
    }
  }
}

void main() {
  const String projectId = 'proj-1';

  // A small set of pre-seeded folder ids belonging to the Active_Project. A
  // generated "folder" case draws its target folder id from this set.
  const List<String> folderIds = <String>['folder-a', 'folder-b', 'folder-c'];

  final DateTime base = DateTime.fromMillisecondsSinceEpoch(
    1700000000000,
    isUtc: true,
  );

  Project buildProject() => Project(
        id: projectId,
        name: 'Active Project',
        createdAt: base,
        modifiedAt: base,
      );

  property('Property 3: document creation is correctly scoped to its container',
      () {
    forAll(
      combine2(
        // true == create at the project root; false == create inside a folder.
        boolean(),
        // Which pre-seeded folder to target when not at root.
        integer(min: 0, max: folderIds.length - 1),
      ),
      (input) async {
        final (atRoot, folderIndex) = input;
        final String? targetFolderId = atRoot ? null : folderIds[folderIndex];

        // Fresh fakes and workspace per case so cases never leak into each
        // other.
        final _FakeFolderRepository folderRepo = _FakeFolderRepository();
        final _FakeDocumentRepository documentRepo = _FakeDocumentRepository();

        // Seed the folders of the Active_Project so a folder target is a real
        // folder of the project.
        for (final String id in folderIds) {
          folderRepo.seed(
            Folder(
              id: id,
              name: id,
              projectId: projectId,
              createdAt: base,
              modifiedAt: base,
            ),
          );
        }

        final ProjectWorkspaceState workspace = ProjectWorkspaceState(
          buildProject(),
          folderRepo,
          documentRepo,
        );

        try {
          await workspace.createDocument(folderId: targetFolderId);

          // The created document is now the Active_Document.
          final Document? active = workspace.activeDocument;
          expect(
            active,
            isNotNull,
            reason: 'createDocument must set an Active_Document',
          );

          // project_id is the Active_Project (Req 10.1, 10.2).
          expect(
            active!.projectId,
            projectId,
            reason: 'created document must be scoped to the Active_Project',
          );

          // folder_id is null for the root, or the chosen folder id otherwise
          // (Req 10.1 root; Req 10.2 folder).
          expect(
            active.folderId,
            targetFolderId,
            reason: atRoot
                ? 'a root document must have a null folder_id'
                : 'an in-folder document must carry that folder id',
          );

          // The repository received exactly one create, and the STORED entity
          // matches the exposed Active_Document's scoping.
          expect(
            documentRepo.created.length,
            1,
            reason: 'exactly one document should have been created',
          );
          final Document stored = documentRepo.created.single;
          expect(
            stored.projectId,
            projectId,
            reason: 'the stored entity must carry the Active_Project id',
          );
          expect(
            stored.folderId,
            targetFolderId,
            reason: 'the stored entity must carry the target folder id '
                '(null for root)',
          );
          expect(
            stored.id,
            active.id,
            reason: 'the stored entity must be the Active_Document',
          );
        } finally {
          workspace.dispose();
        }
      },
      maxExamples: 100,
    );
  });
}
