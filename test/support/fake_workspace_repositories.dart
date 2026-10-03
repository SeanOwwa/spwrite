/// Map-backed folder and document repositories for widget tests that need a
/// real [ProjectWorkspaceState] without a database. Every future completes
/// immediately, so state changes settle with a plain `pump()`.
library;

import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';
import 'package:spwrite/domain/folder.dart';
import 'package:spwrite/domain/folder_repository.dart';

class FakeFolderRepository implements FolderRepository {
  FakeFolderRepository(this.folders, this.documents);

  final Map<String, Folder> folders;
  final Map<String, Document> documents;

  @override
  Future<List<Folder>> getByProject(String projectId) async => folders.values
      .where((Folder f) => f.projectId == projectId)
      .toList(growable: false);

  @override
  Future<Folder?> getById(String id) async => folders[id];

  @override
  Future<Folder> create(Folder folder) async => folders[folder.id] = folder;

  @override
  Future<void> update(Folder folder) async => folders[folder.id] = folder;

  @override
  Future<void> updatePositions(List<Folder> changed) async {
    for (final Folder f in changed) {
      folders[f.id] = f;
    }
  }

  @override
  Future<void> deleteCascade(String id) async {
    folders.remove(id);
    documents.removeWhere((_, Document d) => d.folderId == id);
  }
}

class FakeDocumentRepository implements DocumentRepository {
  FakeDocumentRepository(this.documents);

  final Map<String, Document> documents;

  @override
  Future<List<Document>> getByProject(String projectId) async => documents
      .values
      .where((Document d) => d.projectId == projectId)
      .toList(growable: false);

  @override
  Future<List<Document>> getByContainer(
    String projectId,
    String? folderId,
  ) async =>
      documents.values
          .where((Document d) =>
              d.projectId == projectId && d.folderId == folderId)
          .toList(growable: false);

  @override
  Future<Document?> getById(String id) async => documents[id];

  @override
  Future<Document> create(Document doc) async => documents[doc.id] = doc;

  @override
  Future<void> update(Document doc) async => documents[doc.id] = doc;

  @override
  Future<void> updatePositions(List<Document> changed) async {
    for (final Document d in changed) {
      documents[d.id] = d;
    }
  }

  @override
  Future<void> delete(String id) async => documents.remove(id);
}
