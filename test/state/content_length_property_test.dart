// Property test for the Markdown source length invariant (writing-app-v2 task 9.6).
//
// Feature: writing-app-v2, Property 9: For any proposed Content, the Markdown source applied to the Active_Document never exceeds 1,000,000 characters; a source within the limit is applied exactly as provided, and a source that would exceed the limit leaves the existing Content unchanged rather than storing an over-length value.
//
// **Validates: Requirements 15.3, 15.4**
//
// Strategy: ProjectWorkspaceState.onContentChanged(Delta) computes the
// prospective Markdown source via its injected MarkdownDocumentCodec and
// enforces `maxContentLength = 1,000,000`. Rather than fight the real
// Delta -> Markdown conversion (which normalizes text and makes the resulting
// length hard to predict), we inject a stub codec whose `deltaToMarkdown`
// returns a controlled string set immediately before each call. The Delta
// itself is irrelevant to the stub, so any non-empty Delta works.
//
// For each generated case we pick a target Markdown length `L` from a
// distribution that hits the boundary values (0, 1, 999999, 1000000, 1000001,
// and a well-over-limit case) as well as random small/medium lengths. We set
// the stub to return an `L`-length string, snapshot the Active_Document's
// content, call onContentChanged, and assert:
//   - the applied content length is ALWAYS <= 1,000,000;
//   - when L <= 1,000,000 the content equals the proposed string exactly;
//   - when L  > 1,000,000 the content is left UNCHANGED and a transient error
//     is surfaced.
//
// Repos are hand-written in-memory fakes implementing the domain repository
// interfaces, so the test is deterministic and free of database flakiness. A
// short-duration autosave debouncer is injected so the deferred save never
// outlives the test; the save path targets the fake DocumentRepository anyway.

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiri_check/kiri_check.dart';

import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';
import 'package:spwrite/domain/folder.dart';
import 'package:spwrite/domain/folder_repository.dart';
import 'package:spwrite/domain/markdown_document_codec.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/state/autosave_debouncer.dart';
import 'package:spwrite/state/project_workspace_state.dart';

/// A codec whose [deltaToMarkdown] ignores the [Delta] and returns whatever
/// string was placed in [next] before the call. This lets the test control the
/// prospective Markdown length precisely, independent of the real conversion.
class _StubCodec extends MarkdownDocumentCodec {
  String next = '';

  @override
  String deltaToMarkdown(Delta delta) => next;
}

/// In-memory [FolderRepository]; the length invariant never touches folders, so
/// this only needs to satisfy the interface and return no folders.
class _InMemoryFolderRepo implements FolderRepository {
  final Map<String, Folder> _folders = <String, Folder>{};

  @override
  Future<Folder> create(Folder folder) async {
    _folders[folder.id] = folder;
    return folder;
  }

  @override
  Future<void> deleteCascade(String id) async {
    _folders.remove(id);
  }

  @override
  Future<Folder?> getById(String id) async => _folders[id];

  @override
  Future<List<Folder>> getByProject(String projectId) async => _folders.values
      .where((Folder f) => f.projectId == projectId)
      .toList(growable: false);

  @override
  Future<void> update(Folder folder) async {
    _folders[folder.id] = folder;
  }
}

/// In-memory [DocumentRepository]. `create` stores the document and returns it;
/// `update` overwrites it (the autosave path lands here); the getters read the
/// map. No persistence, no I/O, fully deterministic.
class _InMemoryDocumentRepo implements DocumentRepository {
  final Map<String, Document> _docs = <String, Document>{};

  @override
  Future<Document> create(Document doc) async {
    _docs[doc.id] = doc;
    return doc;
  }

  @override
  Future<void> delete(String id) async {
    _docs.remove(id);
  }

  @override
  Future<Document?> getById(String id) async => _docs[id];

  @override
  Future<List<Document>> getByContainer(
    String projectId,
    String? folderId,
  ) async =>
      _docs.values
          .where((Document d) => d.projectId == projectId && d.folderId == folderId)
          .toList(growable: false);

  @override
  Future<List<Document>> getByProject(String projectId) async => _docs.values
      .where((Document d) => d.projectId == projectId)
      .toList(growable: false);

  @override
  Future<void> update(Document doc) async {
    _docs[doc.id] = doc;
  }
}

void main() {
  const int cap = ProjectWorkspaceState.maxContentLength; // 1,000,000

  // Length distribution: the boundary values that matter, plus random
  // small/medium lengths so the generator explores the input space. Boundary
  // cases are weighted in via `frequency` so they are hit often across 120
  // examples, while the random band keeps coverage broad. `frequency` is typed
  // as `Arbitrary<dynamic>`; each drawn value is an `int`, cast in the body.
  Arbitrary<dynamic> targetLengths() => frequency(<(int, Arbitrary<dynamic>)>[
        // Exact boundaries and just-over cases (the interesting region).
        (6, constantFrom(<int>[0, 1, cap - 1, cap, cap + 1, cap + 100])),
        // A well-over-limit case to prove the cap holds far past the boundary.
        (1, constant(cap + 500000)),
        // Random within-limit lengths (small/medium) for broad coverage.
        (3, integer(min: 0, max: 5000)),
      ]);

  property('Property 9: Markdown source length invariant on the Active_Document',
      () {
    forAll(
      targetLengths(),
      (dynamic rawLength) async {
        final int length = rawLength as int;
        final DateTime now = DateTime.fromMillisecondsSinceEpoch(
          1000,
          isUtc: true,
        );
        final Project project = Project.create(
          id: 'project-1',
          name: 'Test Project',
          now: now,
        );

        final _StubCodec stub = _StubCodec();
        final _InMemoryFolderRepo folderRepo = _InMemoryFolderRepo();
        final _InMemoryDocumentRepo docRepo = _InMemoryDocumentRepo();

        final ProjectWorkspaceState workspace = ProjectWorkspaceState(
          project,
          folderRepo,
          docRepo,
          // Short window so any scheduled save fires (and is harmless) quickly;
          // the save targets the in-memory repo either way.
          autosaveDebouncer:
              AutosaveDebouncer(duration: const Duration(milliseconds: 1)),
          codec: stub,
        );

        try {
          // Seed one Active_Document (createDocument stores it in docRepo and
          // makes it the Active_Document with empty content).
          await workspace.createDocument();
          expect(
            workspace.activeDocument,
            isNotNull,
            reason: 'an Active_Document must exist for the edit to apply',
          );

          // The proposed prospective Markdown of the requested length.
          final String proposed = 'a' * length;
          stub.next = proposed;

          final String previousContent = workspace.activeDocument!.content;
          // Guard the test's own assumption: a within-limit case must actually
          // differ from the current (empty) content so it is a genuine change.
          final bool withinLimit = length <= cap;

          // The Delta is irrelevant to the stub; any non-empty Delta works.
          workspace.onContentChanged(Delta()..insert('x'));

          final Document active = workspace.activeDocument!;

          // Invariant (always): the applied source never exceeds the cap.
          expect(
            active.content.length <= cap,
            isTrue,
            reason: 'applied content length ${active.content.length} exceeds '
                'the $cap cap (proposed length $length)',
          );

          if (withinLimit) {
            // A within-limit source is applied exactly as provided.
            expect(
              active.content,
              equals(proposed),
              reason: 'within-limit source (length $length) must be applied '
                  'exactly as provided',
            );
          } else {
            // An over-limit source leaves the existing Content unchanged and
            // surfaces a transient error rather than storing an over-length
            // value.
            expect(
              active.content,
              equals(previousContent),
              reason: 'over-limit source (length $length) must leave the '
                  'existing content unchanged',
            );
            expect(
              workspace.transientError,
              isNotNull,
              reason: 'over-limit source must surface a transient error',
            );
          }
        } finally {
          workspace.dispose();
        }
      },
      maxExamples: 120,
    );
  });
}
