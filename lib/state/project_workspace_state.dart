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
import '../presentation/export/exportable_document.dart';
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

/// Lifecycle of the Active_Document's autosave, surfaced to the Editor so it
/// can show a save indicator at the top-left of the toolbar. Transitions:
/// a genuine edit moves it to [saving]; a successful persist moves it to
/// [saved]; a failed persist moves it to [error]. It sits at [idle] before any
/// edit is made to the current document.
enum SaveStatus {
  /// No unsaved edit has been made to the active document yet.
  idle,

  /// The active document has an unsaved edit, or a save is in flight.
  saving,

  /// The most recent edit has been persisted to the store.
  saved,

  /// The most recent save attempt failed; the edit is kept in memory and will
  /// be retried on the next edit.
  error,
}

/// One entry in the project's root level, which is a single ordered sequence
/// that interleaves folders and root-level documents (Req v3: a document may
/// sit above, below, or between folders). Exactly one of [folder] / [document]
/// is non-null. [position] is the item's slot in that shared root ordering.
class RootItem {
  /// The folder, when this item is a folder; otherwise null.
  final Folder? folder;

  /// The root-level document, when this item is a document; otherwise null.
  final Document? document;

  const RootItem.folder(Folder this.folder) : document = null;
  const RootItem.document(Document this.document) : folder = null;

  /// Whether this root item is a folder.
  bool get isFolder => folder != null;

  /// The item's position in the shared root ordering.
  int get position => folder?.position ?? document!.position;

  /// A stable identity for keys / equality (folder and document ids never
  /// collide — both are UUIDs).
  String get id => folder?.id ?? document!.id;
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

  /// Lifecycle of the Active_Document's autosave, surfaced to the Editor's
  /// save indicator. Reset to [SaveStatus.idle] whenever the Active_Document
  /// changes, advanced to [SaveStatus.saving] on a genuine edit, and settled to
  /// [SaveStatus.saved] / [SaveStatus.error] by the debounced save.
  SaveStatus _saveStatus = SaveStatus.idle;

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

  /// The project's root level as a single ordered sequence interleaving folders
  /// and root-level documents, sorted by their shared `position` (Req v3). This
  /// lets a document sit above, below, or between folders. Folders and
  /// root-documents whose positions tie fall back to folders-first then the
  /// per-entity comparators for a stable order.
  List<RootItem> rootItems() {
    final List<RootItem> items = <RootItem>[
      for (final Folder f in _folders) RootItem.folder(f),
      for (final Document d in _documents.where((Document d) => d.folderId == null))
        RootItem.document(d),
    ];
    items.sort((RootItem a, RootItem b) {
      final int byPos = a.position.compareTo(b.position);
      if (byPos != 0) return byPos;
      // Stable tie-break: folders before documents, then per-entity order.
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      if (a.isFolder) return compareFolders(a.folder!, b.folder!);
      return compareDocuments(a.document!, b.document!);
    });
    return items;
  }

  /// The documents contained in [folderId] in the shared [compareDocuments]
  /// order (Req 6.3).
  List<Document> documentsIn(String folderId) {
    final List<Document> inFolder = _documents
        .where((Document d) => d.folderId == folderId)
        .toList(growable: false);
    return List<Document>.of(inFolder)..sort(compareDocuments);
  }

  /// **All** documents of the open project across every container (root-level
  /// documents plus documents in any folder) in the shared [compareDocuments]
  /// order. Returned as a fresh list so callers (e.g. the export dialog) cannot
  /// mutate the backing store. Each document already carries its full title and
  /// Markdown content from [loadContents], so no extra repository call is
  /// needed to export.
  List<Document> allDocuments() {
    return List<Document>.of(_documents)..sort(compareDocuments);
  }

  // ---------------------------------------------------------------------------
  // Drag-and-drop reordering & moving (persisted via `position`).
  //
  // Each method computes the affected container's ordered list, applies the
  // move, reassigns sequential positions (0..n-1) so the stored order is dense
  // and unambiguous, persists them transactionally via `updatePositions`, and
  // updates the in-memory documents/folders before notifying. On a repository
  // failure the in-memory lists are left untouched and a transient error is
  // surfaced.
  // ---------------------------------------------------------------------------

  /// Reorders the project's **root level** — the single interleaved sequence of
  /// folders and root-level documents from [rootItems] — moving the item at
  /// [oldIndex] to [newIndex] (Req v3). Positions are reassigned densely across
  /// both folders and documents so they share one ordering, and both kinds are
  /// persisted transactionally. A no-op move does nothing.
  Future<void> reorderRootItems(int oldIndex, int newIndex) async {
    final List<RootItem> ordered = rootItems();
    if (oldIndex < 0 || oldIndex >= ordered.length) return;
    final int target = _normalizeReorderIndex(oldIndex, newIndex, ordered.length);
    if (target == oldIndex) return;

    final RootItem moved = ordered.removeAt(oldIndex);
    ordered.insert(target, moved);

    // Reassign dense positions across the merged list, splitting into folder
    // and document updates.
    final List<Folder> folderUpdates = <Folder>[];
    final List<Document> docUpdates = <Document>[];
    for (int i = 0; i < ordered.length; i++) {
      final RootItem item = ordered[i];
      if (item.isFolder) {
        folderUpdates.add(item.folder!.copyWith(position: i));
      } else {
        docUpdates.add(item.document!.copyWith(position: i));
      }
    }

    try {
      if (folderUpdates.isNotEmpty) {
        await _folderRepo.updatePositions(folderUpdates);
      }
      if (docUpdates.isNotEmpty) {
        await _documentRepo.updatePositions(docUpdates);
      }
      // Merge updates back into the in-memory lists.
      if (folderUpdates.isNotEmpty) {
        final Map<String, Folder> byId = <String, Folder>{
          for (final Folder f in _folders) f.id: f,
        };
        for (final Folder f in folderUpdates) {
          byId[f.id] = f;
        }
        _folders = _sortedFolders(byId.values.toList());
      }
      if (docUpdates.isNotEmpty) {
        final Map<String, Document> byId = <String, Document>{
          for (final Document d in _documents) d.id: d,
        };
        for (final Document d in docUpdates) {
          byId[d.id] = d;
        }
        _documents = _sortedDocuments(byId.values.toList());
        if (_activeDocument != null && byId.containsKey(_activeDocument!.id)) {
          _activeDocument = byId[_activeDocument!.id];
        }
      }
      _transientError = null;
    } catch (_) {
      _transientError = 'Could not save the new order.';
    } finally {
      notifyListeners();
    }
  }

  /// Reorders the documents inside [folderId]: moves the document at [oldIndex]
  /// to [newIndex] within that folder's [documentsIn] ordering.
  Future<void> reorderDocumentsInFolder(
    String folderId,
    int oldIndex,
    int newIndex,
  ) async {
    await _reorderDocumentsInContainer(folderId, oldIndex, newIndex);
  }

  /// Shared reorder for a single container ([containerFolderId] == null for the
  /// project root, otherwise a folder id).
  Future<void> _reorderDocumentsInContainer(
    String? containerFolderId,
    int oldIndex,
    int newIndex,
  ) async {
    final List<Document> ordered = _documents
        .where((Document d) => d.folderId == containerFolderId)
        .toList()
      ..sort(compareDocuments);

    final int target = _normalizeReorderIndex(oldIndex, newIndex, ordered.length);
    if (oldIndex < 0 || oldIndex >= ordered.length) return;
    if (target == oldIndex) return;

    final Document moved = ordered.removeAt(oldIndex);
    ordered.insert(target, moved);

    final List<Document> renumbered = <Document>[
      for (int i = 0; i < ordered.length; i++) ordered[i].copyWith(position: i),
    ];

    await _persistDocumentChanges(renumbered);
  }

  /// Moves the document [docId] into [targetFolderId] (null == project root) at
  /// [targetIndex] within that container.
  ///
  /// - Into a folder: the document is re-homed and the folder's documents are
  ///   reindexed 0..n-1.
  /// - To the project root: the document joins the interleaved root sequence
  ///   (folders + root documents) at [targetIndex], and that whole sequence is
  ///   reindexed so the moved document shares one ordering with the folders
  ///   (Req v3).
  ///
  /// When the document is already in the target container this behaves like a
  /// reorder.
  Future<void> moveDocument(
    String docId,
    String? targetFolderId,
    int targetIndex,
  ) async {
    final int srcIndex = _documents.indexWhere((Document d) => d.id == docId);
    if (srcIndex == -1) return;
    final Document doc = _documents[srcIndex];

    if (targetFolderId != null) {
      // --- Move into a folder: reindex that folder's documents. ------------
      final List<Document> dest = _documents
          .where((Document d) => d.folderId == targetFolderId && d.id != docId)
          .toList()
        ..sort(compareDocuments);
      final int clampedIndex = targetIndex < 0
          ? 0
          : (targetIndex > dest.length ? dest.length : targetIndex);
      dest.insert(clampedIndex, doc.copyWith(folderId: targetFolderId));
      final List<Document> renumbered = <Document>[
        for (int i = 0; i < dest.length; i++) dest[i].copyWith(position: i),
      ];
      if (!_expandedFolderIds.contains(targetFolderId)) {
        _expandedFolderIds.add(targetFolderId);
      }
      await _persistDocumentChanges(renumbered, activeSync: docId);
      return;
    }

    // --- Move to the project root: splice into the interleaved root order. --
    final List<RootItem> root = rootItems()
        .where((RootItem it) => it.id != docId)
        .toList();
    final int clampedIndex = targetIndex < 0
        ? 0
        : (targetIndex > root.length ? root.length : targetIndex);
    root.insert(clampedIndex, RootItem.document(doc.copyWith(moveToRoot: true)));

    final List<Folder> folderUpdates = <Folder>[];
    final List<Document> docUpdates = <Document>[];
    for (int i = 0; i < root.length; i++) {
      final RootItem item = root[i];
      if (item.isFolder) {
        folderUpdates.add(item.folder!.copyWith(position: i));
      } else {
        docUpdates.add(item.document!.copyWith(position: i));
      }
    }

    try {
      if (folderUpdates.isNotEmpty) {
        await _folderRepo.updatePositions(folderUpdates);
      }
      if (docUpdates.isNotEmpty) {
        await _documentRepo.updatePositions(docUpdates);
      }
      if (folderUpdates.isNotEmpty) {
        final Map<String, Folder> byId = <String, Folder>{
          for (final Folder f in _folders) f.id: f,
        };
        for (final Folder f in folderUpdates) {
          byId[f.id] = f;
        }
        _folders = _sortedFolders(byId.values.toList());
      }
      final Map<String, Document> byDoc = <String, Document>{
        for (final Document d in _documents) d.id: d,
      };
      for (final Document d in docUpdates) {
        byDoc[d.id] = d;
      }
      _documents = _sortedDocuments(byDoc.values.toList());
      if (_activeDocument?.id == docId) {
        _activeDocument = byDoc[docId];
      }
      _transientError = null;
    } catch (_) {
      _transientError = 'Could not save the new order.';
    } finally {
      notifyListeners();
    }
  }

  /// Persists a batch of document position/folder changes and merges them into
  /// the in-memory [_documents], keeping the Active_Document reference current.
  Future<void> _persistDocumentChanges(
    List<Document> changed, {
    String? activeSync,
  }) async {
    if (changed.isEmpty) return;
    try {
      await _documentRepo.updatePositions(changed);
      // Merge the changed documents back into the master list by id.
      final Map<String, Document> byId = <String, Document>{
        for (final Document d in _documents) d.id: d,
      };
      for (final Document d in changed) {
        byId[d.id] = d;
      }
      _documents = _sortedDocuments(byId.values.toList());
      if (activeSync != null && _activeDocument?.id == activeSync) {
        _activeDocument = byId[activeSync];
      }
      _transientError = null;
    } catch (_) {
      _transientError = 'Could not save the new order.';
    } finally {
      notifyListeners();
    }
  }

  /// Clamps a `ReorderableListView.onReorderItem` destination index into range.
  /// `onReorderItem` already reports [newIndex] as the post-removal slot, so no
  /// off-by-one adjustment is needed here — only clamping for safety.
  int _normalizeReorderIndex(int oldIndex, int newIndex, int length) {
    int target = newIndex;
    if (target < 0) target = 0;
    if (target > length - 1) target = length - 1;
    return target;
  }

  /// The position to assign a newly created document in [folderId].
  ///
  /// For a folder, this is one past the max position among that folder's
  /// documents. For the project root (folderId == null), the root is the
  /// interleaved folder+document sequence, so the new document appends after
  /// the last root item (folder or document) (Req v3).
  int _nextDocumentPosition(String? folderId) {
    if (folderId == null) return _nextRootPosition();
    final Iterable<int> positions = _documents
        .where((Document d) => d.folderId == folderId)
        .map((Document d) => d.position);
    if (positions.isEmpty) return 0;
    return positions.reduce((int a, int b) => a > b ? a : b) + 1;
  }

  /// One past the maximum position across the interleaved root sequence
  /// (folders + root-level documents), so a newly created root folder or root
  /// document appends to the end of that shared order.
  int _nextRootPosition() {
    final List<RootItem> items = rootItems();
    if (items.isEmpty) return 0;
    return items
            .map((RootItem it) => it.position)
            .reduce((int a, int b) => a > b ? a : b) +
        1;
  }

  /// The position to assign a newly created folder: one past the maximum
  /// position across the interleaved root sequence, so a new folder appends to
  /// the end of that shared order (Req v3).
  int _nextFolderPosition() => _nextRootPosition();

  /// Renders a document's stored Markdown [content] to plain paragraph text for
  /// export, using the same [codec] the editor uses to load documents. Each
  /// element of the returned list is one paragraph (blank paragraphs dropped);
  /// formatting (bold, italic, headings, lists, links) is flattened to text.
  List<String> contentParagraphs(String content) {
    if (content.trim().isEmpty) return const <String>[];
    String plain;
    try {
      // Convert Markdown -> Delta, then concatenate the ops' text. A Delta's
      // insert ops carry the document text (with '\n' separating lines); this
      // yields the same plain text the editor shows, without pulling the
      // flutter_quill `Document` type (which name-clashes with the domain
      // [Document]) into the state layer.
      final Delta delta = _codec.markdownToDelta(content);
      final StringBuffer buffer = StringBuffer();
      for (final Operation op in delta.toList()) {
        final Object? data = op.data;
        if (data is String) buffer.write(data);
      }
      plain = buffer.toString();
    } catch (_) {
      // Fall back to the raw source if conversion fails on unexpected input.
      plain = content;
    }
    return plain
        .split('\n')
        .map((String line) => line.trimRight())
        .where((String line) => line.trim().isNotEmpty)
        .toList(growable: false);
  }

  /// Renders a document's stored Markdown [content] into structured
  /// [ExportBlock]s for export, using the same [codec] the editor uses to load
  /// documents. Unlike [contentParagraphs], this preserves the editor's
  /// formatting: each block carries its paragraph style (heading / list item /
  /// normal) and its inline runs carry bold / italic / underline /
  /// strikethrough, so the exporter can mirror what the editor shows rather than
  /// flattening to plain text.
  ///
  /// Blank paragraphs are dropped. On any conversion failure the raw source is
  /// emitted as plain paragraphs so export never loses the text entirely.
  List<ExportBlock> contentBlocks(String content) {
    if (content.trim().isEmpty) return const <ExportBlock>[];
    try {
      // Convert Markdown -> Delta. In a Quill Delta, inline formatting (bold,
      // italic, underline, strike) rides on the text insert ops, while
      // block-level formatting (header level, list type) rides on the
      // attributes of the trailing '\n' that closes each line. We accumulate
      // runs until a newline, then flush a block using the newline's block
      // attributes.
      final Delta delta = _codec.markdownToDelta(content);

      final List<ExportBlock> blocks = <ExportBlock>[];
      List<ExportRun> pending = <ExportRun>[];

      void flush(Map<String, dynamic>? lineAttrs) {
        // Drop entirely-blank lines (no runs, or only whitespace).
        final bool hasText =
            pending.any((ExportRun r) => r.text.trim().isNotEmpty);
        if (!hasText) {
          pending = <ExportRun>[];
          return;
        }
        blocks.add(
          ExportBlock(
            style: _blockStyleFor(lineAttrs),
            headingLevel: _headingLevelFor(lineAttrs),
            runs: pending,
          ),
        );
        pending = <ExportRun>[];
      }

      for (final Operation op in delta.toList()) {
        final Object? data = op.data;
        if (data is! String) continue; // Embeds (images etc.) are unsupported.
        final Map<String, dynamic>? attrs = op.attributes;

        // Split the insert on newlines. Each newline terminates the current
        // line; the block-level attributes on the op that *contains* the
        // newline apply to the line being closed.
        final List<String> segments = data.split('\n');
        for (int s = 0; s < segments.length; s++) {
          final String segment = segments[s];
          if (segment.isNotEmpty) {
            pending.add(_runFromAttributes(segment, attrs));
          }
          // Every split boundary except the last represents a real '\n'.
          if (s < segments.length - 1) {
            flush(attrs);
          }
        }
      }
      // Flush any trailing runs not terminated by a newline.
      flush(null);

      return List<ExportBlock>.unmodifiable(blocks);
    } catch (_) {
      // Fall back to raw paragraphs so text is never lost on unexpected input.
      return content
          .split('\n')
          .map((String line) => line.trimRight())
          .where((String line) => line.trim().isNotEmpty)
          .map(ExportBlock.plain)
          .toList(growable: false);
    }
  }

  /// Builds an [ExportRun] from a text [segment] and its Delta inline
  /// [attributes] (bold / italic / underline / strike).
  ExportRun _runFromAttributes(
    String segment,
    Map<String, dynamic>? attributes,
  ) {
    final Map<String, dynamic> a = attributes ?? const <String, dynamic>{};
    return ExportRun(
      text: segment,
      bold: a['bold'] == true,
      italic: a['italic'] == true,
      underline: a['underline'] == true,
      strikethrough: a['strike'] == true,
    );
  }

  /// Maps a line's Delta block [attributes] to an [ExportBlockStyle].
  ExportBlockStyle _blockStyleFor(Map<String, dynamic>? attributes) {
    if (attributes == null) return ExportBlockStyle.normal;
    if (attributes['header'] != null) return ExportBlockStyle.heading;
    final Object? list = attributes['list'];
    if (list == 'bullet') return ExportBlockStyle.bulletItem;
    if (list == 'ordered') return ExportBlockStyle.numberedItem;
    return ExportBlockStyle.normal;
  }

  /// Extracts the heading level (1..6) from a line's Delta block [attributes],
  /// defaulting to 1 when absent or out of range.
  int _headingLevelFor(Map<String, dynamic>? attributes) {
    final Object? header = attributes?['header'];
    if (header is int && header >= 1 && header <= 6) return header;
    return 1;
  }

  /// The `Active_Document`, or `null` when none is selected (Req 11).
  Document? get activeDocument => _activeDocument;

  /// Status of the Editor's active-document retrieval / editing.
  DocStatus get editorStatus => _editorStatus;

  /// Status of the Active_Project's contents load.
  LoadStatus get contentsStatus => _contentsStatus;

  /// Lifecycle of the Active_Document's autosave, for the Editor's save
  /// indicator: [SaveStatus.idle] before any edit, [SaveStatus.saving] while an
  /// edit is unsaved / being written, [SaveStatus.saved] once persisted, and
  /// [SaveStatus.error] if the last save failed.
  SaveStatus get saveStatus => _saveStatus;

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
      // Append after the current folders so a new folder lands at the end of
      // the manual order rather than jumping to the top.
      position: _nextFolderPosition(),
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
    // Persist the outgoing document's pending edit before the new one becomes
    // active (see [selectDocument]).
    await saveNow();
    final Document doc = Document.newDocument(
      id: const Uuid().v4(),
      projectId: _project.id,
      folderId: folderId,
      now: DateTime.now().toUtc(),
      // Append after the current documents in this container so a new document
      // lands at the end of the manual order rather than jumping to the top.
      position: _nextDocumentPosition(folderId),
    );

    try {
      final Document created = await _documentRepo.create(doc);
      // Req 10.4: add, re-sort, and make it the Active_Document.
      _documents = _sortedDocuments(<Document>[..._documents, created]);
      _activeDocument = created;
      _editorStatus = DocStatus.ready;
      // Newly created document has no pending edit: reset the save indicator.
      _saveStatus = SaveStatus.idle;
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

    // Write the outgoing document's pending edit before switching; otherwise
    // the debounced save would later persist whichever document is active then.
    await saveNow();

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
        // Fresh document: no pending edit, so reset the save indicator.
        _saveStatus = SaveStatus.idle;
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
    // The edit is not yet on disk; surface an in-flight save state so the
    // Editor's indicator shows the change is being saved.
    _saveStatus = SaveStatus.saving;
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
  /// Whether focus mode is on: the sidebar, title bar, toolbar and side panels
  /// are hidden so only the page remains (Cmd/Ctrl+Shift+F).
  bool get focusMode => _focusMode;
  bool _focusMode = false;

  /// Whether the project sidebar is shown in the wide layout (Cmd/Ctrl+\).
  /// Focus mode hides it regardless.
  bool get sidebarVisible => _sidebarVisible && !_focusMode;
  bool _sidebarVisible = true;

  /// Turns focus mode on or off.
  void toggleFocusMode() {
    _focusMode = !_focusMode;
    notifyListeners();
  }

  /// Leaves focus mode (Esc). A no-op when it is already off.
  void exitFocusMode() {
    if (!_focusMode) return;
    _focusMode = false;
    notifyListeners();
  }

  /// Shows or hides the project sidebar. Leaving focus mode first makes the
  /// shortcut always visibly do something.
  void toggleSidebar() {
    if (_focusMode) {
      _focusMode = false;
      _sidebarVisible = true;
    } else {
      _sidebarVisible = !_sidebarVisible;
    }
    notifyListeners();
  }

  /// Writes any pending (debounced) edit to disk right away.
  ///
  /// Backs the editor's Cmd/Ctrl+S shortcut and is also called before the
  /// active document changes and when the app is closing or backgrounded, so
  /// the last few seconds of typing are never lost. A no-op when nothing is
  /// pending.
  Future<void> saveNow() async {
    if (!_autosaveDebouncer.isPending) return;
    _autosaveDebouncer.cancel();
    await _persistActive();
  }

  Future<void> _persistActive() async {
    final Document? activeDoc = _activeDocument;
    if (activeDoc == null) return;
    try {
      await _documentRepo.update(activeDoc);
      if (_disposed) return;
      // The in-memory Content is now on disk: settle the indicator to "saved".
      // Guard against a document switch mid-save so we do not flash "saved"
      // for a document that is no longer active.
      if (_activeDocument?.id == activeDoc.id) {
        _saveStatus = SaveStatus.saved;
        notifyListeners();
      }
    } catch (_) {
      if (_disposed) return;
      // Req 16.2: retain the in-memory Content; surface a recoverable error.
      _transientError = 'Save failed.';
      _saveStatus = SaveStatus.error;
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
    // Closing the project with an edit still inside the debounce window: write
    // it now (fire-and-forget) instead of dropping it with the timer.
    final bool pending = _autosaveDebouncer.isPending;
    _autosaveDebouncer.dispose();
    _disposed = true;
    if (pending) unawaited(_persistActive());
    super.dispose();
  }

  /// Set once [dispose] runs, so a save settling afterwards does not notify.
  bool _disposed = false;
}
