/// Presentation layer: [EditorView], the WYSIWYG writing surface that displays
/// and edits the [ProjectWorkspaceState.activeDocument].
///
/// This is the v2 rebuild of the v1 plain-text editor around `flutter_quill`.
/// The view observes [ProjectWorkspaceState] via `provider` and renders one of
/// three states:
/// - **loading** — while a document is being retrieved
///   ([DocStatus.loading]), a centered progress indicator (Req 11.3);
/// - **no active document** — a placeholder prompting the user to select or
///   create a document, with no editor mounted so text input is rejected
///   (Req 14.10);
/// - **ready** — a title bar acting as the rename entry point, the
///   [EditorToolbar], and the [QuillEditor] bound to a per-document
///   [QuillController] (Req 14.1).
///
/// On an active-document identity change the view builds a *fresh*
/// [QuillController] whose document is `markdownToDelta(active.content)`, so the
/// editor renders the stored Markdown (Req 15.2). Local edits to that
/// controller are forwarded as `onContentChanged(Delta)` to
/// [ProjectWorkspaceState], which computes the Markdown source via the codec,
/// enforces the cap, updates the in-memory Content immediately (Req 14.8), and
/// schedules the debounced save. When the prospective Markdown would exceed the
/// cap the state rejects the edit and surfaces a max-length indication, which
/// this view renders as a banner (Req 15.4).
///
/// A newly created document raises a one-shot focus request on the state
/// ([ProjectWorkspaceState.consumeFocusRequest]); the view honours it by moving
/// text-input focus into the content area so the document is immediately
/// writable (Req 10.5).
///
/// The [QuillController], [FocusNode], and [ScrollController] are owned here (a
/// [StatefulWidget]) and disposed with the view — the controller is also
/// disposed and rebuilt on every document identity change so no editing state
/// leaks between documents.
library;

import 'package:flutter/material.dart';
// The flutter_quill barrel exports a `Document` class that collides with the
// app's domain [Document]. Hide it from the general import and pull it in under
// a `quill` prefix so both can be used unambiguously in one file.
import 'package:flutter_quill/flutter_quill.dart' hide Document;
import 'package:flutter_quill/flutter_quill.dart' as quill show Document;
import 'package:flutter_quill/quill_delta.dart';
import 'package:provider/provider.dart';

import '../domain/document.dart';
import '../state/project_workspace_state.dart';
import '../theme/app_theme.dart';
import 'editor_toolbar.dart';

/// The WYSIWYG writing surface for the [ProjectWorkspaceState.activeDocument]
/// (Req 10.5, 11.2, 11.3, 14.1, 14.8, 14.10, 15.2, 15.4).
class EditorView extends StatefulWidget {
  /// Invoked when the user taps the title bar to begin renaming the active
  /// document. Wired up by the enclosing Project_Sidebar / Shell, which owns
  /// the inline rename flow (Req 12.1). When `null`, the title is shown as
  /// plain, non-interactive text.
  final VoidCallback? onRenameRequested;

  const EditorView({super.key, this.onRenameRequested});

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView> {
  /// The Quill controller for the currently loaded document, or `null` when no
  /// document is loaded. Rebuilt from scratch on every document identity
  /// change so no editing/history state leaks between documents.
  QuillController? _controller;

  /// Focus for the editor. Focus is requested when a newly created document
  /// asks for it via [ProjectWorkspaceState.consumeFocusRequest] so a new
  /// document is immediately writable (Req 10.5).
  final FocusNode _editorFocusNode = FocusNode();

  /// Scroll controller for the editor's content viewport.
  final ScrollController _editorScrollController = ScrollController();

  /// The id of the document currently mirrored into [_controller], or `null`
  /// when no document is loaded. Compared against the active document's id in
  /// [build] to detect an identity change.
  String? _loadedDocId;

  /// Guards against re-entrant [onContentChanged] dispatches while we are
  /// programmatically replacing the controller's document (load path), and
  /// avoids notifying the state during the frame in which we rebuild.
  bool _syncingDocument = false;

  @override
  void dispose() {
    _controller?.dispose();
    _editorFocusNode.dispose();
    _editorScrollController.dispose();
    super.dispose();
  }

  /// Builds a fresh [QuillController] for [active] by rendering its stored
  /// Markdown into a Delta via the workspace [codec] (Req 15.2), disposes any
  /// previous controller, and wires a document-change listener that forwards
  /// local edits to the state layer.
  void _syncToDocument(ProjectWorkspaceState state, Document active) {
    _loadedDocId = active.id;

    // Convert the stored Markdown source into a Delta for the editor (Req
    // 15.2). An empty document yields an empty (single newline) Delta.
    final Delta delta = _deltaFor(state, active.content);

    // Dispose the outgoing controller before replacing it so its listeners and
    // resources are released.
    _controller?.dispose();

    final QuillController controller = QuillController(
      document: quill.Document.fromDelta(delta),
      selection: const TextSelection.collapsed(offset: 0),
    );

    // Forward local edits (typing / toolbar formatting) to the state layer,
    // which computes the Markdown, enforces the cap, and schedules the save
    // (Req 14.8, 15.4). Programmatic replacements (the load path above) are
    // marked ChangeSource.local by the document API too, but we only ever
    // attach this listener *after* construction, so it fires solely for user
    // edits made through this controller.
    controller.document.changes.listen((DocChange event) {
      if (!mounted) return;
      if (_syncingDocument) return;
      if (event.source != ChangeSource.local) return;
      // [state] is the single workspace instance for this open project; it is
      // stable for the lifetime of this view, so capturing it here (rather than
      // reading the BuildContext in this async callback) is safe.
      state.onContentChanged(controller.document.toDelta());
    });

    _controller = controller;
  }

  /// Converts stored Markdown [markdown] to a Delta via the workspace codec,
  /// falling back to an empty document if conversion fails on unexpected input.
  Delta _deltaFor(ProjectWorkspaceState state, String markdown) {
    if (markdown.isEmpty) {
      return quill.Document().toDelta();
    }
    try {
      final Delta delta = state.codec.markdownToDelta(markdown);
      // A Quill document's Delta must end with a trailing newline; the codec
      // produces conformant Deltas for the supported feature set. Guard against
      // an empty result just in case.
      return delta.isEmpty ? quill.Document().toDelta() : delta;
    } catch (_) {
      return quill.Document().toDelta();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ProjectWorkspaceState state = context.watch<ProjectWorkspaceState>();
    final Document? active = state.activeDocument;
    final DocStatus status = state.editorStatus;

    // Req 11.3: while a document is being retrieved, show a loading indicator.
    if (status == DocStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Req 14.10: with no active document, show a placeholder and mount no
    // editor — text input is rejected because there is nothing to type into.
    if (active == null) {
      _loadedDocId = null;
      _controller?.dispose();
      _controller = null;
      return _buildPlaceholder(context);
    }

    // Rebuild the controller (from the stored Markdown) only when the active
    // document identity changes, so an in-progress edit is never clobbered.
    if (_loadedDocId != active.id) {
      _syncingDocument = true;
      _syncToDocument(state, active);
      _syncingDocument = false;
    }

    // Honour a one-shot focus request raised by a newly created document so it
    // is immediately writable (Req 10.5). Selection does not raise it.
    if (state.consumeFocusRequest()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editorFocusNode.requestFocus();
      });
    }

    final bool atMaxLength =
        active.content.length >= ProjectWorkspaceState.maxContentLength;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildTitleBar(context, active),
        EditorToolbar(controller: _controller!),
        const Divider(height: 1, thickness: 1, color: AppPalette.outline),
        if (atMaxLength) _buildMaxLengthIndicator(context),
        Expanded(child: _buildEditor()),
      ],
    );
  }

  /// The no-active-document placeholder prompting the user to select or create
  /// a document (Req 14.10). Contains no editor, so input is rejected.
  Widget _buildPlaceholder(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Select a document from the list, or create a new one to start '
          'writing.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: AppPalette.textSecondary,
              ),
        ),
      ),
    );
  }

  /// The title bar. Displays the active document's title (Req 11.2) and acts as
  /// the rename entry point: tapping it invokes [EditorView.onRenameRequested]
  /// when provided (Req 12.1).
  Widget _buildTitleBar(BuildContext context, Document active) {
    final String shownTitle =
        active.title.trim().isEmpty ? 'Untitled Document' : active.title;

    final Widget titleText = Text(
      shownTitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: AppPalette.textPrimary,
            fontWeight: FontWeight.w600,
          ),
    );

    return Container(
      color: AppPalette.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: widget.onRenameRequested == null
                ? titleText
                : InkWell(
                    onTap: widget.onRenameRequested,
                    child: Row(
                      children: <Widget>[
                        Flexible(child: titleText),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.edit_outlined,
                          size: 18,
                          color: AppPalette.textSecondary,
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// The max-length indication shown when the stored Markdown source is at the
  /// [ProjectWorkspaceState.maxContentLength] cap (Req 15.4). Further edits
  /// that would grow the source are rejected by the state layer, preserving the
  /// existing Content.
  Widget _buildMaxLengthIndicator(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppPalette.surfaceVariant,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        'Maximum length of ${ProjectWorkspaceState.maxContentLength} '
        'characters reached.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppPalette.error,
            ),
      ),
    );
  }

  /// The WYSIWYG content area bound to the per-document [_controller]
  /// (Req 14.1). Local edits are forwarded to
  /// [ProjectWorkspaceState.onContentChanged] via the document-change listener
  /// wired in [_syncToDocument]; the state layer enforces the cap
  /// authoritatively (Req 14.8, 15.4).
  Widget _buildEditor() {
    return Container(
      color: AppPalette.background,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: QuillEditor(
        controller: _controller!,
        focusNode: _editorFocusNode,
        scrollController: _editorScrollController,
        config: const QuillEditorConfig(
          placeholder: 'Start writing…',
          padding: EdgeInsets.zero,
          expands: true,
          scrollable: true,
          autoFocus: false,
        ),
      ),
    );
  }
}
