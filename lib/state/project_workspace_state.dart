/// State layer: [ProjectWorkspaceState], the `ChangeNotifier` that is the
/// single source of truth for an **open project** (the Active_Project).
///
/// It is the v2 evolution of v1's `DocumentAppState`, extended from a single
/// flat document list to the three-level model (Project → Folder → Document).
/// It owns the open project's in-memory ordered folders and per-container
/// documents, the Active_Document, folder expand/collapse state, editor status,
/// transient UI errors, and the [AutosaveDebouncer]. The presentation layer
/// (Project_Sidebar + Editor) observes it via `provider`; the state layer
/// depends only on the [FolderRepository] and [DocumentRepository]
/// abstractions, never on SQLite directly.
///
/// This file implements the **core** slice of the workspace state
/// (constructor / fields, contents load, folder expand/collapse, getters,
/// dispose). The folder CRUD, document CRUD, and content-change flows are added
/// to this same class by later tasks; the private repository and debouncer
/// fields and the shared in-memory ordering helpers exist here so those methods
/// can be added cleanly.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:uuid/uuid.dart';

import '../domain/document.dart';
import '../domain/document_repository.dart';
import '../domain/folder.dart';
import '../domain/folder_repository.dart';
import '../domain/markdown_document_codec.dart';
import '../domain/project.dart';
import 'autosave_debouncer.dart';
import 'load_status.dart';

/// Lifecycle of the Editor's `Active_Document` retrieval and editing
/// (Req 11.2, 11.3). Workspace-specific, so it lives with the workspace state
/// rather than in the shared `load_status.dart`.
enum DocStatus {
  /// No document is active.
  idle,

  /// A document is being retrieved for the Editor.
  loading,

  /// The active document is loaded and ready to edit.
  ready,

  /// Retrieval of the requested document failed.
  error,
}

/// The single source of truth the Project_Sidebar and Editor observe while a
/// project is open. Owns the open project's ordered folders and per-container
/// documents, the Active_Document, folder expand/collapse state, editor status,
/// transient errors, and the autosave debouncer.
///
/// Opening a project constructs this state (loading its contents); returning to
/// the Dashboard disposes it, which cancels the debouncer and drops the
/// Active_Document, clearing the Editor as a natural consequence (Req 5.4).
class ProjectWorkspaceState extends ChangeNotifier {
  /// The maximum length, in characters, of a Document's Markdown **source**
  /// Content. An edit whose prospective Markdown would exceed this cap is
  /// rejected, preserving the existing Content (Req 15.3, 15.4).
  static const int maxContentLength = 1000000;

  /// The Active_Project this workspace is scoped to (Req 5.1). Reassigned by a
  /// later task when the project is renamed in-place, so it is not `final`.
  // ignore: prefer_final_fields
  Project _project;

  /// Folder persistence abstraction. The state layer talks only to this
  /// interface, keeping it decoupled from SQLite. Consumed by [loadContents]
  /// here and by the folder CRUD flows added in a later task.
  final FolderRepository _folderRepo;

  /// Document persistence abstraction. The state layer talks only to this
  /// interface, keeping it decoupled from SQLite. Consumed by [loadContents]
  /// here and by the document CRUD / content-change flows added in a later
  /// task.
  final DocumentRepository _documentRepo;

  /// Coalesces rapid Content edits into a single deferred save (Req 16.1).
  /// Owned here and disposed with this state; consumed by the content-change
  /// flow added in a later task.
  final AutosaveDebouncer _autosaveDebouncer;

  /// Converts the editor's Quill [Delta] to the persisted Markdown source and
  /// back. Consumed by the content-change flow to compute prospective Markdown
  /// and measure its length against [maxContentLength] (Req 15.3, 15.4). May be
  /// injected for tests; otherwise the default codec is used.
  final MarkdownDocumentCodec _codec;

  /// The open project's folders, kept sorted by the shared [compareFolders]
  /// rule (Req 6.2).
  List<Folder> _folders = <Folder>[];

  /// **All** documents of the open project across every container (root-level
  /// documents and documents in any of the project's folders). Per-container,
  /// ordered views are derived on demand by [rootDocuments] and
  /// [documentsIn] via the shared [compareDocuments] rule (Req 6.3).
  List<Document> _documents = <Document>[];

  /// The `Active_Document`, or `null` when none is selected (Req 11).
  Document? _activeDocument;

  /// Status of the Editor's active-document retrieval / editing (Req 11.2,
  /// 11.3). Reassigned by the select / create / delete flows added in a later
  /// task, so it is not `final`.
  // ignore: prefer_final_fields
  DocStatus _editorStatus = DocStatus.idle;

  /// Status of the Active_Project's contents load (folders + documents)
  /// (Req 6.1, 6.11).
  LoadStatus _contentsStatus = LoadStatus.idle;

  /// The set of expanded folder ids. A folder id present here is expanded;
  /// absent means collapsed (Req 6.4, 6.5).
  final Set<String> _expandedFolderIds = <String>{};

  /// A recoverable message surfaced to the user via a transient banner /
  /// snackbar, or `null` when there is nothing to show (Req 6.11).
  String? _transientError;

  /// Set when a newly created document should take text-input focus in the
  /// Editor's Content area (Req 10.5). The Editor consumes and clears it via
  /// [consumeFocusRequest] once it has moved focus, so the request fires once
  /// per creation. Document selection deliberately does not set this.
  bool _focusRequested = false;

  /// Creates the workspace state over the Active_Project [_project] and the
  /// [_folderRepo] / [_documentRepo] persistence abstractions. An
  /// [AutosaveDebouncer] may be injected (for tests / a custom idle window);
  /// otherwise the default 2-second debouncer is used (Req 16.1). A
  /// [MarkdownDocumentCodec] may likewise be injected (for tests); otherwise
  /// the default codec is used.
  ProjectWorkspaceState(
    this._project,
    this._folderRepo,
    this._documentRepo, {
    AutosaveDebouncer? autosaveDebouncer,
    MarkdownDocumentCodec? codec,
  })  : _autosaveDebouncer = autosaveDebouncer ?? AutosaveDebouncer(),
        _codec = codec ?? MarkdownDocumentCodec();

  /// The Active_Project this workspace is scoped to (Req 5.1).
  Project get project => _project;

  /// The Delta <-> Markdown codec this workspace uses. Exposed so the Editor
  /// can render an Active_Document's stored Markdown into a fresh Quill
  /// controller on load (Req 15.2) through the exact same codec instance the
  /// save path uses, keeping load-time rendering and save-time source
  /// computation on one seam.
  MarkdownDocumentCodec get codec => _codec;

  /// The open project's folders in the shared [compareFolders] order (Req 6.2).
  /// Returned as an unmodifiable view so listeners cannot mutate the backing
  /// store.
  List<Folder> get folders => List<Folder>.unmodifiable(_folders);

  /// The Root-Level Documents (container == project root; `folderId == null`)
  /// in the shared [compareDocuments] order (Req 6.3).
  List<Document> rootDocuments() {
    final List<Document> rootDocs = _documents
        .where((Document d) => d.folderId == null)
        .toList(growable: false);
    return List<Document>.of(rootDocs)..sort(compareDocuments);
  }

  /// The documents contained in [folderId] in the shared [compareDocuments]
  /// order (Req 6.3).
  List<Document> documentsIn(String folderId) {
    final List<Document> inFolder = _documents
        .where((Document d) => d.folderId == folderId)
        .toList(growable: false);
    return List<Document>.of(inFolder)..sort(compareDocuments);
  }

  /// The `Active_Document`, or `null` when none is selected (Req 11).
  Document? get activeDocument => _activeDocument;

  /// Status of the Editor's active-document retrieval / editing.
  DocStatus get editorStatus => _editorStatus;

  /// Status of the Active_Project's contents load.
  LoadStatus get contentsStatus => _contentsStatus;

  /// Whether the folder identified by [folderId] is currently expanded
  /// (Req 6.4, 6.5).
  bool isExpanded(String folderId) => _expandedFolderIds.contains(folderId);

  /// The current transient error message, or `null` when none is pending.
  String? get transientError => _transientError;

  /// Clears the pending transient error (e.g. after the banner / snackbar has
  /// been shown or dismissed) and notifies listeners if anything changed.
  void clearTransientError() {
    if (_transientError == null) return;
    _transientError = null;
    notifyListeners();
  }

  /// Loads the Active_Project's contents — its folders and all of its documents
  /// across every container — from the repositories (Req 5.2, 6.1, 6.11).
  ///
  /// While the load is in flight [contentsStatus] is [LoadStatus.loading]. On
  /// success the folders and documents are replaced (re-sorted in memory by the
  /// shared comparators so the in-memory lists and the SQL `ORDER BY` always
  /// agree), [contentsStatus] becomes [LoadStatus.loaded], and any pending
  /// transient error is cleared. An empty project simply yields empty lists
  /// without error.
  ///
  /// On failure the previously displayed contents are retained,
  /// [contentsStatus] becomes [LoadStatus.error], and a [transientError]
  /// indicating the contents could not be loaded is surfaced (Req 6.11).
  Future<void> loadContents() async {
    _contentsStatus = LoadStatus.loading;
    notifyListeners();

    try {
      final List<Folder> loadedFolders =
          await _folderRepo.getByProject(_project.id);
      final List<Document> loadedDocuments =
          await _documentRepo.getByProject(_project.id);

      // Re-apply the shared ordering in memory so the in-memory lists and the
      // SQL `ORDER BY` always agree, even if an implementation returns rows
      // unsorted (Req 6.2, 6.3).
      _folders = _sortedFolders(loadedFolders);
      _documents = _sortedDocuments(loadedDocuments);
      _contentsStatus = LoadStatus.loaded;
      _transientError = null;
    } catch (_) {
      // Req 6.11: retain the previously displayed contents; surface a
      // recoverable error.
      _contentsStatus = LoadStatus.error;
      _transientError = 'Project contents could not be loaded.';
    } finally {
      notifyListeners();
    }
  }

  /// Toggles the expand/collapse state of the folder identified by [folderId]
  /// (Req 6.4, 6.5): an expanded folder collapses and a collapsed folder
  /// expands. Notifies listeners so the Project_Sidebar re-renders the tree.
  void toggleFolder(String folderId) {
    if (_expandedFolderIds.contains(folderId)) {
      _expandedFolderIds.remove(folderId);
    } else {
      _expandedFolderIds.add(folderId);
    }
    notifyListeners();
  }

  /// Creates a new folder named [name] in the Active_Project (Req 7.2).
  ///
  /// The candidate is trimmed of surrounding whitespace first. An empty trimmed
  /// name is rejected with a transient error and nothing is created (Req 7.3);
  /// a trimmed name longer than 255 characters is likewise rejected (Req 7.4).
  ///
  /// Otherwise a [Folder] is created (its last-modified timestamp equal to its
  /// creation timestamp) and persisted; on success it is added to the in-memory
  /// folders, the list is re-sorted by the shared [compareFolders] rule so the
  /// in-memory order and the SQL `ORDER BY` agree, and any pending transient
  /// error is cleared (Req 7.2). On a repository failure the previously
  /// displayed folders are retained and a recoverable error is surfaced
  /// (Req 7.6). Listeners are always notified.
  Future<void> createFolder(String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      // Req 7.3: a name is required.
      _transientError = 'A name is required.';
      notifyListeners();
      return;
    }
    if (trimmed.length > 255) {
      // Req 7.4: reject over-length names.
      _transientError = 'Name exceeds the 255 character maximum.';
      notifyListeners();
      return;
    }

    final Folder folder = Folder.create(
      id: const Uuid().v4(),
      projectId: _project.id,
      name: trimmed,
      now: DateTime.now().toUtc(),
    );

    try {
      await _folderRepo.create(folder);
      // Req 7.2: add and re-sort so the in-memory order matches the SQL rule.
      _folders = _sortedFolders(<Folder>[..._folders, folder]);
      _transientError = null;
    } catch (_) {
      // Req 7.6: retain the previously displayed folders; surface an error.
      _transientError = 'Folder could not be created.';
    } finally {
      notifyListeners();
    }
  }

  /// Renames the folder identified by [id] to [name] (Req 8.2).
  ///
  /// The candidate is trimmed first. An empty trimmed name is rejected with a
  /// transient error, leaving the folder unchanged (Req 8.3); a trimmed name
  /// longer than 255 characters is likewise rejected (Req 8.4). An unknown [id]
  /// is a no-op after validation.
  ///
  /// On accept the folder's name and last-modified timestamp are updated and
  /// persisted; on success the in-memory folder is replaced, the list is
  /// re-sorted by [compareFolders] (the advanced timestamp can change its
  /// position), and any pending transient error is cleared (Req 8.2). On a
  /// repository failure the previous name and timestamp are retained and a
  /// recoverable error is surfaced (Req 8.7). Listeners are always notified.
  Future<void> renameFolder(String id, String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      // Req 8.3: a name is required; retain the existing folder.
      _transientError = 'A name is required.';
      notifyListeners();
      return;
    }
    if (trimmed.length > 255) {
      // Req 8.4: reject over-length names; retain the existing folder.
      _transientError = 'Name exceeds the 255 character maximum.';
      notifyListeners();
      return;
    }

    final int index = _folders.indexWhere((Folder f) => f.id == id);
    if (index == -1) {
      // Unknown id: nothing to rename.
      notifyListeners();
      return;
    }

    final Folder updated = _folders[index].copyWith(
      name: trimmed,
      modifiedAt: DateTime.now().toUtc(),
    );

    try {
      await _folderRepo.update(updated);
      // Req 8.2: replace and re-sort (the advanced timestamp may reorder it).
      final List<Folder> next = List<Folder>.of(_folders);
      next[index] = updated;
      _folders = _sortedFolders(next);
      _transientError = null;
    } catch (_) {
      // Req 8.7: retain the previous name/timestamp; surface an error.
      _transientError = 'Rename could not be saved.';
    } finally {
      notifyListeners();
    }
  }

  /// Deletes the folder identified by [id] together with all documents it
  /// contains, transactionally (Req 9.2).
  ///
  /// The cascade is delegated to [FolderRepository.deleteCascade], which removes
  /// the folder and its documents all-or-nothing. On success the folder is
  /// removed from the in-memory folders, every document whose `folderId` equals
  /// [id] is removed from the in-memory documents, both lists are re-sorted by
  /// the shared comparators, and [id] is dropped from the expanded-folder set.
  ///
  /// If the Active_Document was one of the removed documents (it lived in the
  /// deleted folder), the successor is selected **scoped to the Active_Project
  /// across every container**: the Active_Document becomes the project's first
  /// remaining document under the shared [compareDocuments] ordering, or `null`
  /// when the project has no documents left. The editor status becomes
  /// [DocStatus.ready] when a successor exists, else [DocStatus.idle] (Req 9.6,
  /// 9.7).
  ///
  /// On a repository failure everything is retained (folders, documents, active
  /// document, expansion) and a recoverable error is surfaced (Req 9.4).
  /// Listeners are always notified.
  Future<void> deleteFolder(String id) async {
    try {
      // Req 9.2: remove the folder and its documents transactionally.
      await _folderRepo.deleteCascade(id);

      // Whether the Active_Document lived in the deleted folder determines
      // whether a successor must be promoted (Req 9.6, 9.7).
      final bool activeRemoved =
          _activeDocument != null && _activeDocument!.folderId == id;

      // Drop the folder and every document it contained; re-sort both.
      _folders =
          _sortedFolders(_folders.where((Folder f) => f.id != id).toList());
      _documents = _sortedDocuments(
        _documents.where((Document d) => d.folderId != id).toList(),
      );
      _expandedFolderIds.remove(id);

      if (activeRemoved) {
        // Req 9.6 / 9.7: successor is the first of the project's remaining
        // documents across all containers under the ordering rule, or none.
        if (_documents.isEmpty) {
          _activeDocument = null;
          _editorStatus = DocStatus.idle;
        } else {
          _activeDocument = _documents.first;
          _editorStatus = DocStatus.ready;
        }
      }

      _transientError = null;
    } catch (_) {
      // Req 9.4: retain folders, documents, active document, and expansion.
      _transientError = 'Deletion did not complete.';
    } finally {
      notifyListeners();
    }
  }

  /// Returns whether a newly created document is awaiting text-input focus in
  /// the Editor's Content area (Req 10.5), clearing the request as it does so.
  ///
  /// The Editor calls this once it is ready to move focus; the flag is set only
  /// by [createDocument] (never by [selectDocument]), so focus is forced on
  /// creation but not on plain selection. Returns `true` exactly once per
  /// creation, `false` thereafter.
  bool consumeFocusRequest() {
    if (!_focusRequested) return false;
    _focusRequested = false;
    return true;
  }

  /// Creates a new document in the Active_Project (Req 10.1, 10.2).
  ///
  /// A null [folderId] creates a Root-Level Document under the project root
  /// (Req 10.1); a non-null [folderId] creates the document inside that folder
  /// (Req 10.2). The document is built via [Document.newDocument] with the
  /// default "Untitled Document" title, empty content, and a last-modified
  /// timestamp equal to its creation timestamp (Req 10.3).
  ///
  /// On success the document is persisted, added to the in-memory documents and
  /// re-sorted by the shared [compareDocuments] rule so the in-memory order and
  /// the SQL `ORDER BY` agree, set as the Active_Document with editor status
  /// [DocStatus.ready] (Req 10.4), and a focus request is raised so the Editor
  /// places the caret in the Content area (Req 10.5). When the target folder is
  /// currently collapsed it is expanded to reveal the new document (Req 10.6),
  /// and any pending transient error is cleared.
  ///
  /// On a repository failure the previously Active_Document and the set of
  /// existing documents are retained unchanged and a recoverable error is
  /// surfaced (Req 10.7). Listeners are always notified.
  Future<void> createDocument({String? folderId}) async {
    final Document doc = Document.newDocument(
      id: const Uuid().v4(),
      projectId: _project.id,
      folderId: folderId,
      now: DateTime.now().toUtc(),
    );

    try {
      final Document created = await _documentRepo.create(doc);
      // Req 10.4: add, re-sort, and make it the Active_Document.
      _documents = _sortedDocuments(<Document>[..._documents, created]);
      _activeDocument = created;
      _editorStatus = DocStatus.ready;
      // Req 10.5: the Editor should focus the Content area for the new doc.
      _focusRequested = true;
      // Req 10.6: reveal the new document when it lands in a collapsed folder.
      if (folderId != null && !_expandedFolderIds.contains(folderId)) {
        _expandedFolderIds.add(folderId);
      }
      _transientError = null;
    } catch (_) {
      // Req 10.7: retain the previous active document and existing documents.
      _transientError = 'Document could not be created.';
    } finally {
      notifyListeners();
    }
  }

  /// Selects the document identified by [id] as the Active_Document (Req 11.1).
  ///
  /// When [id] is already the Active_Document this is a no-op: the document is
  /// kept without reloading its content (Req 11.5). Otherwise the editor status
  /// becomes [DocStatus.loading] while the document is retrieved from the
  /// repository (Req 11.3). On success the retrieved document becomes the
  /// Active_Document with editor status [DocStatus.ready] and any pending
  /// transient error is cleared; unlike creation, selection does not raise a
  /// focus request.
  ///
  /// If the document cannot be retrieved (not found or the repository throws),
  /// the previously Active_Document is retained, the editor status becomes
  /// [DocStatus.error], and a recoverable error is surfaced (Req 11.4).
  /// Listeners are notified as the status transitions.
  Future<void> selectDocument(String id) async {
    // Req 11.5: selecting the already-active document does not reload it.
    if (_activeDocument?.id == id) return;

    _editorStatus = DocStatus.loading; // Req 11.3
    notifyListeners();

    try {
      final Document? found = await _documentRepo.getById(id);
      if (found == null) {
        // Req 11.4: unknown id — retain the previous active document.
        _editorStatus = DocStatus.error;
        _transientError = 'Could not open the document.';
      } else {
        _activeDocument = found;
        _editorStatus = DocStatus.ready;
        _transientError = null;
      }
    } catch (_) {
      // Req 11.4: retrieval failed — retain the previous active document.
      _editorStatus = DocStatus.error;
      _transientError = 'Could not open the document.';
    } finally {
      notifyListeners();
    }
  }

  /// Renames the document identified by [id] to [title] (Req 12.2).
  ///
  /// The candidate is trimmed first. An empty trimmed title is rejected with a
  /// transient error, leaving the document unchanged (Req 12.3); a trimmed
  /// title longer than 255 characters is likewise rejected (Req 12.4). An
  /// unknown [id] is a no-op after validation.
  ///
  /// On accept the document's title and last-modified timestamp are updated and
  /// persisted; on success the in-memory document is replaced, the list is
  /// re-sorted by the shared [compareDocuments] rule (the advanced timestamp
  /// can change its position), the Active_Document is updated when it is the
  /// renamed document, and any pending transient error is cleared (Req 12.2).
  /// On a repository failure the previous title and timestamp are retained and
  /// a recoverable error is surfaced. Listeners are always notified.
  Future<void> renameDocument(String id, String title) async {
    final String trimmed = title.trim();
    if (trimmed.isEmpty) {
      // Req 12.3: a title is required; retain the existing document.
      _transientError = 'A title is required.';
      notifyListeners();
      return;
    }
    if (trimmed.length > 255) {
      // Req 12.4: reject over-length titles; retain the existing document.
      _transientError = 'Title exceeds the 255 character maximum.';
      notifyListeners();
      return;
    }

    final int index = _documents.indexWhere((Document d) => d.id == id);
    if (index == -1) {
      // Unknown id: nothing to rename.
      notifyListeners();
      return;
    }

    final Document updated = _documents[index].copyWith(
      title: trimmed,
      modifiedAt: DateTime.now().toUtc(),
    );

    try {
      await _documentRepo.update(updated);
      // Req 12.2: replace and re-sort (the advanced timestamp may reorder it).
      final List<Document> next = List<Document>.of(_documents);
      next[index] = updated;
      _documents = _sortedDocuments(next);
      if (_activeDocument?.id == id) {
        _activeDocument = updated;
      }
      _transientError = null;
    } catch (_) {
      // Retain the previous title/timestamp; surface an error.
      _transientError = 'Rename could not be saved.';
    } finally {
      notifyListeners();
    }
  }

  /// Deletes the document identified by [id] from the Active_Project (Req 13.2).
  ///
  /// On success the document is removed from the store and from the in-memory
  /// documents, and the list is re-sorted by the shared [compareDocuments]
  /// rule. When the deleted document was the Active_Document a successor is
  /// selected **scoped to the Active_Project across every container**: the
  /// Active_Document becomes the project's first remaining document under the
  /// ordering rule, or `null` when the project has no documents left. The
  /// editor status becomes [DocStatus.ready] when a successor exists, else
  /// [DocStatus.idle] (Req 13.5, 13.6).
  ///
  /// On a repository failure the document is retained unchanged and a
  /// recoverable error is surfaced (Req 13.3). Listeners are always notified.
  Future<void> deleteDocument(String id) async {
    try {
      // Req 13.2: remove the document and its content from the store.
      await _documentRepo.delete(id);

      // Whether the deleted document was active determines whether a successor
      // must be promoted (Req 13.5, 13.6).
      final bool activeRemoved = _activeDocument?.id == id;

      _documents =
          _sortedDocuments(_documents.where((Document d) => d.id != id).toList());

      if (activeRemoved) {
        // Req 13.5 / 13.6: successor is the first of the project's remaining
        // documents across all containers under the ordering rule, or none.
        if (_documents.isEmpty) {
          _activeDocument = null;
          _editorStatus = DocStatus.idle;
        } else {
          _activeDocument = _documents.first;
          _editorStatus = DocStatus.ready;
        }
      }

      _transientError = null;
    } catch (_) {
      // Req 13.3: retain the document unchanged; surface an error.
      _transientError = 'Deletion did not complete.';
    } finally {
      notifyListeners();
    }
  }

  /// Applies a Content edit from the Editor, expressed as the current Quill
  /// [Delta] of the Active_Document (Req 14.8, 14.9, 15.3, 15.4, 16.1, 16.2,
  /// 16.3).
  ///
  /// When there is no Active_Document this is a no-op. Otherwise the prospective
  /// Markdown source is computed from [delta] via the codec.
  ///
  /// If that Markdown would exceed [maxContentLength] characters the edit is
  /// rejected: the existing Content is preserved, a max-length transient error
  /// is surfaced, and listeners are notified (Req 15.3, 15.4).
  ///
  /// If the prospective Markdown equals the Active_Document's current Content
  /// the change is not genuine (e.g. a selection or caret move that leaves the
  /// source unchanged): nothing is updated, so the last-modified timestamp is
  /// not advanced and no save is scheduled (Req 14.9).
  ///
  /// On a genuine change the in-memory Active_Document's Content is updated
  /// immediately with an advanced `modifiedAt` (Req 14.8), the document is
  /// replaced in the in-memory list and re-sorted by the shared
  /// [compareDocuments] rule (the advanced timestamp may reorder it), any
  /// pending transient error is cleared, and listeners are notified. The
  /// persistence is then handed to the reused [AutosaveDebouncer] so a burst of
  /// edits coalesces into a single deferred save (Req 16.1). A failed save
  /// retains the in-memory Content and surfaces an error; because the in-memory
  /// Content is kept, the next edit reschedules the save and the change is
  /// retried naturally (Req 16.2, 16.3).
  void onContentChanged(Delta delta) {
    // No Active_Document: nothing to edit.
    if (_activeDocument == null) return;

    // Prospective Markdown source for the current editor state.
    final String md = _codec.deltaToMarkdown(delta);

    // Req 15.3 / 15.4: reject over-length source, preserving existing Content.
    if (md.length > maxContentLength) {
      _transientError = 'Maximum length of $maxContentLength characters reached.';
      notifyListeners();
      return;
    }

    // Req 14.9: only a genuine source change advances the timestamp and saves.
    if (md == _activeDocument!.content) return;

    // Req 14.8: update the in-memory Active_Document's Content immediately and
    // advance its last-modified timestamp.
    final Document updated = _activeDocument!.copyWith(
      content: md,
      modifiedAt: DateTime.now().toUtc(),
    );
    _activeDocument = updated;

    // Replace the document in the in-memory list and re-sort (the advanced
    // timestamp may reorder it within its container).
    final int index = _documents.indexWhere((Document d) => d.id == updated.id);
    if (index != -1) {
      final List<Document> next = List<Document>.of(_documents);
      next[index] = updated;
      _documents = _sortedDocuments(next);
    }
    _transientError = null;
    notifyListeners();

    // Req 16.1: coalesce rapid edits into a single deferred save.
    _autosaveDebouncer.schedule(() {
      unawaited(_persistActive());
    });
  }

  /// Persists the current Active_Document's Content, invoked by the autosave
  /// debouncer once editing has been idle for the debounce window (Req 16.1).
  ///
  /// The Active_Document is captured at call time; if it has since become null
  /// (e.g. the workspace closed or the document was deleted) this is a no-op.
  /// On a repository failure the in-memory Content is retained and a recoverable
  /// error is surfaced, so the next edit reschedules the save and the change is
  /// retried naturally (Req 16.2, 16.3).
  Future<void> _persistActive() async {
    final Document? activeDoc = _activeDocument;
    if (activeDoc == null) return;
    try {
      await _documentRepo.update(activeDoc);
    } catch (_) {
      // Req 16.2: retain the in-memory Content; surface a recoverable error.
      _transientError = 'Save failed.';
      notifyListeners();
    }
  }

  /// Returns a new list of [folders] sorted by the shared [compareFolders]
  /// rule (Req 6.2). Shared by [loadContents] and the folder CRUD flows added
  /// in a later task so every in-memory re-sort uses the one ordering rule.
  List<Folder> _sortedFolders(List<Folder> folders) =>
      List<Folder>.of(folders)..sort(compareFolders);

  /// Returns a new list of [documents] sorted by the shared [compareDocuments]
  /// rule (Req 6.3). Shared by [loadContents] and the document CRUD /
  /// content-change flows added in a later task so every in-memory re-sort uses
  /// the one ordering rule. The comparator orders within a container; the
  /// per-container getters ([rootDocuments], [documentsIn]) filter first.
  List<Document> _sortedDocuments(List<Document> documents) =>
      List<Document>.of(documents)..sort(compareDocuments);

  /// Cancels the autosave debouncer so no timer outlives this state, then
  /// completes the base `ChangeNotifier` disposal. Dropping the Active_Document
  /// as part of disposal clears the Editor when the workspace closes (Req 5.4).
  @override
  void dispose() {
    _autosaveDebouncer.dispose();
    super.dispose();
  }
}
