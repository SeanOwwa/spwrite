// Feature: writing-app-v2, Property 13: For any Active_Project containing one or more Documents with one marked as the Active_Document, deleting the Active_Document — or deleting the Folder that contains it — sets the new Active_Document to the Document of the Active_Project that sorts first under the ordering rule across the project's remaining Documents; when no Documents remain in the Active_Project, no Document is active.
//
// Validates: Requirements 9.6, 9.7, 13.5, 13.6
//
// This test drives the state layer's successor selection in
// ProjectWorkspaceState.deleteDocument and .deleteFolder. Successor selection
// is scoped to the WHOLE Active_Project across every container (root + folders),
// ordered by the shared compareDocuments rule — NOT scoped to the container the
// deleted document lived in. This property nails that project-wide behavior.
//
// Rather than stand up SQLite, the workspace is driven against hand-written,
// Map-backed fake repositories that mirror the real transactional behavior the
// state layer relies on:
//   * _FakeDocumentRepository.delete removes a document by id.
//   * _FakeFolderRepository.deleteCascade removes the folder AND every document
//     it contains from the shared fake document store (mirroring the real
//     all-or-nothing cascade). The workspace itself removes those documents
//     from its in-memory list by folderId and does NOT reload after
//     deleteFolder, so the cascade just needs to keep the fake store honest and
//     not throw.
//
// For each generated case:
//   1. A project's documents are generated: 1..8 documents spread across the
//      root and 0..3 folders, with distinct ids, varied modifiedAt timestamps
//      (including deliberate ties), and varied titles (including case variants
//      to exercise the case-insensitive title tie-breaker).
//   2. The fakes are pre-populated and workspace.loadContents() is called.
//   3. One document is marked active via workspace.selectDocument.
//   4. The case either (a) deletes the active document, or (b) deletes the
//      folder containing the active document (only when the active doc is in a
//      folder).
//   5. The expected successor is computed independently: the project's
//      remaining documents (after the delete), sorted by compareDocuments;
//      expectedActive = remaining.isEmpty ? null : remaining.first.
//   6. It asserts workspace.activeDocument?.id == expectedActive?.id.
//
// Async is handled by passing an `async` block to `forAll`: kiri_check 1.3.1
// declares the block as `FutureOr<void> Function(T)` and awaits it internally,
// so each loadContents / selectDocument / delete completes before the next
// example runs.

import 'package:flutter_test/flutter_test.dart';
import 'package:kiri_check/kiri_check.dart';

import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';
import 'package:spwrite/domain/folder.dart';
import 'package:spwrite/domain/folder_repository.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/state/project_workspace_state.dart';

// ---------------------------------------------------------------------------
// Map-backed fake repositories
//
// Both fakes share the same document store map so a folder cascade and a plain
// document delete stay consistent. Only the methods the workspace actually
// calls in the exercised flows are meaningfully implemented; the rest throw
// UnimplementedError so an accidental dependency surfaces loudly.
// ---------------------------------------------------------------------------

/// A Map-backed [FolderRepository] sharing its document store with the document
/// fake, so [deleteCascade] can remove the folder's documents transactionally
/// (mirroring the real repository's explicit cascade).
class _FakeFolderRepository implements FolderRepository {
  _FakeFolderRepository(this._folders, this._documents);

  final Map<String, Folder> _folders;
  final Map<String, Document> _documents;

  @override
  Future<List<Folder>> getByProject(String projectId) async {
    return _folders.values
        .where((Folder f) => f.projectId == projectId)
        .toList(growable: false);
  }

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
    // Mirror the real transactional cascade: drop the folder AND every document
    // it contains from the shared store, all-or-nothing.
    _folders.remove(id);
    _documents.removeWhere((_, Document d) => d.folderId == id);
  }
}

/// A Map-backed [DocumentRepository] sharing its store with the folder fake.
class _FakeDocumentRepository implements DocumentRepository {
  _FakeDocumentRepository(this._documents);

  final Map<String, Document> _documents;

  @override
  Future<List<Document>> getByProject(String projectId) async {
    return _documents.values
        .where((Document d) => d.projectId == projectId)
        .toList(growable: false);
  }

  @override
  Future<List<Document>> getByContainer(
    String projectId,
    String? folderId,
  ) async {
    return _documents.values
        .where((Document d) => d.projectId == projectId && d.folderId == folderId)
        .toList(growable: false);
  }

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
// Generation spec
// ---------------------------------------------------------------------------

/// One generated document: which folder it lives in (index into the project's
/// folders, or null for a root-level document), a modified-at offset (small
/// pool so ties are frequent), and a title selector (small pool with case
/// variants so the case-insensitive title tie-breaker is exercised).
typedef _DocSpec = ({
  int? folderIndex,
  int modifiedOffset,
  int titleSelector,
});

/// Shape of a whole case: how many folders the project has, the per-document
/// specs, which document (by index into the generated doc list) is made active,
/// and whether to delete the containing folder instead of the document (only
/// honored when the active doc is in a folder).
typedef _CaseSpec = ({
  int folderCount,
  List<_DocSpec> docs,
  int activeSelector,
  bool deleteFolderInstead,
});

/// A small pool of titles with intentional case variants so identical
/// modified-at timestamps are broken by case-insensitive title ascending.
const List<String> _titlePool = <String>[
  'alpha',
  'Alpha',
  'BETA',
  'beta',
  'gamma',
  '',
  'Zed',
];

Arbitrary<_DocSpec> _docSpecArbitrary(int folderCount) {
  // folderIndex is 0..folderCount (folderCount == null bucket = root). We model
  // it as an integer 0..folderCount where `folderCount` maps to root (null).
  return combine3(
    integer(min: 0, max: folderCount),
    integer(min: 0, max: 4), // modifiedOffset: small pool → frequent ties
    integer(min: 0, max: _titlePool.length - 1),
  ).map(
    (t) => (
      folderIndex: t.$1 == folderCount ? null : t.$1,
      modifiedOffset: t.$2,
      titleSelector: t.$3,
    ),
  );
}

Arbitrary<_CaseSpec> _caseArbitrary() {
  return integer(min: 0, max: 3).flatMap((int folderCount) {
    return combine4(
      // At least one document so there is always something to make active.
      list(_docSpecArbitrary(folderCount), minLength: 1, maxLength: 8),
      constant(folderCount),
      integer(min: 0, max: 1000000), // activeSelector (mod docs.length)
      boolean(),
    ).map(
      (t) => (
        folderCount: t.$2,
        docs: t.$1,
        activeSelector: t.$3,
        deleteFolderInstead: t.$4,
      ),
    );
  });
}

void main() {
  property('Property 13: project-scoped successor selection on delete', () {
    forAll(
      _caseArbitrary(),
      (_CaseSpec spec) async {
        // ------------------------------------------------------------------
        // Materialize the project, folders, and documents with distinct ids.
        // ------------------------------------------------------------------
        final DateTime baseTs =
            DateTime.fromMillisecondsSinceEpoch(1000000, isUtc: true);
        final Project project = Project(
          id: 'project-1',
          name: 'Project 1',
          createdAt: baseTs,
          modifiedAt: baseTs,
        );

        final folders = <Folder>[];
        for (var f = 0; f < spec.folderCount; f++) {
          folders.add(
            Folder(
              id: 'folder-$f',
              name: 'Folder $f',
              projectId: project.id,
              createdAt: baseTs,
              modifiedAt: baseTs,
            ),
          );
        }

        final documents = <Document>[];
        for (var i = 0; i < spec.docs.length; i++) {
          final _DocSpec ds = spec.docs[i];
          final String? folderId =
              ds.folderIndex == null ? null : 'folder-${ds.folderIndex}';
          // modifiedAt drawn from a small pool of distinct timestamps so ties
          // are common; the small step keeps ordering deterministic.
          final DateTime modifiedAt = DateTime.fromMillisecondsSinceEpoch(
            2000000 + ds.modifiedOffset * 1000,
            isUtc: true,
          );
          documents.add(
            Document(
              id: 'doc-$i',
              title: _titlePool[ds.titleSelector],
              content: 'content-$i',
              projectId: project.id,
              folderId: folderId,
              createdAt: baseTs,
              modifiedAt: modifiedAt,
            ),
          );
        }

        // ------------------------------------------------------------------
        // Pre-populate the shared fake store and construct the workspace.
        // ------------------------------------------------------------------
        final docStore = <String, Document>{
          for (final Document d in documents) d.id: d,
        };
        final folderStore = <String, Folder>{
          for (final Folder f in folders) f.id: f,
        };
        final folderRepo = _FakeFolderRepository(folderStore, docStore);
        final docRepo = _FakeDocumentRepository(docStore);

        final workspace =
            ProjectWorkspaceState(project, folderRepo, docRepo);
        try {
          await workspace.loadContents();

          // Choose the active document and select it.
          final Document activeDoc =
              documents[spec.activeSelector % documents.length];
          await workspace.selectDocument(activeDoc.id);
          expect(
            workspace.activeDocument?.id,
            activeDoc.id,
            reason: 'the chosen document should be active before deletion',
          );

          // ----------------------------------------------------------------
          // Decide the operation: delete the folder when asked AND the active
          // doc lives in one; otherwise delete the active document.
          // ----------------------------------------------------------------
          final bool deleteFolder =
              spec.deleteFolderInstead && activeDoc.folderId != null;

          // Compute the expected surviving documents of the project.
          final List<Document> remaining;
          if (deleteFolder) {
            final String targetFolderId = activeDoc.folderId!;
            remaining = documents
                .where((Document d) => d.folderId != targetFolderId)
                .toList();
          } else {
            remaining =
                documents.where((Document d) => d.id != activeDoc.id).toList();
          }
          remaining.sort(compareDocuments);
          final Document? expectedActive =
              remaining.isEmpty ? null : remaining.first;

          // Perform the operation.
          if (deleteFolder) {
            await workspace.deleteFolder(activeDoc.folderId!);
          } else {
            await workspace.deleteDocument(activeDoc.id);
          }

          // ----------------------------------------------------------------
          // The new Active_Document is the project's first remaining document
          // under the ordering rule, or null when none remain.
          // ----------------------------------------------------------------
          expect(
            workspace.activeDocument?.id,
            expectedActive?.id,
            reason: deleteFolder
                ? 'after deleting the active doc\'s folder, the successor '
                    'must be the project\'s first remaining document (or null)'
                : 'after deleting the active doc, the successor must be the '
                    'project\'s first remaining document (or null)',
          );
        } finally {
          workspace.dispose();
        }
      },
      maxExamples: 100,
    );
  });
}
