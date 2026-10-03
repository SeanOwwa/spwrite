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

// flutter_quill's `QuillEditorConfig.onKeyPressed` (used to hard-wire the Tab
// indent) is annotated @experimental in 11.6.0. We rely on it deliberately and
// in one contained place, so silence that specific lint for this file.
// ignore_for_file: experimental_member_use

import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
// The flutter_quill barrel exports a `Document` class that collides with the
// app's domain [Document]. Hide it from the general import and pull it in under
// a `quill` prefix so both can be used unambiguously in one file.
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' hide Document;
import 'package:flutter_quill/flutter_quill.dart' as quill show Document;
import 'package:flutter_quill/quill_delta.dart';
import 'package:provider/provider.dart';

import '../app_info.dart';
import '../domain/document.dart';
import '../state/project_workspace_state.dart';
import '../theme/app_theme.dart';
import 'ai_coming_soon_panel.dart';
import 'ai_panel_view.dart';
import 'character_panel_view.dart';
import 'editor_shortcuts.dart';
import 'editor_toolbar.dart';
import 'export/export_dialog.dart';

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
  ///
  /// Tab handling is not done here; it is wired through
  /// [QuillEditorConfig.onKeyPressed] (see [_onEditorKeyPressed]), which
  /// flutter_quill invokes before its own key handling.
  final FocusNode _editorFocusNode = FocusNode();

  /// Scroll controller for the editor's content viewport.
  final ScrollController _editorScrollController = ScrollController();

  /// The id of the document currently mirrored into [_controller], or `null`
  /// when no document is loaded. Compared against the active document's id in
  /// [build] to detect an identity change.
  String? _loadedDocId;

  /// The live word count of the current editor content, shown in the upper-
  /// right of the title bar. Recomputed whenever the document changes.
  int _wordCount = 0;

  /// Whether the right-hand Character Panel is currently open.
  bool _characterPanelOpen = false;

  /// Whether the right-hand AI Panel is currently open. Backs the AI toolbar
  /// toggle's open/closed tint (Req 1.4). The full open/close + panel-hosting
  /// behaviour (and the mutual exclusivity with the Character Panel) is wired
  /// in a subsequent task; here it only drives the icon tint.
  bool _aiPanelOpen = false;

  /// Guards against re-entrant [onContentChanged] dispatches while we are
  /// programmatically replacing the controller's document (load path), and
  /// avoids notifying the state during the frame in which we rebuild.
  bool _syncingDocument = false;

  /// Word count when the current document was opened, so the badge can show
  /// how much was written this sitting ("+312").
  int _baselineWordCount = 0;

  /// Flushes pending edits when the app is backgrounded or asked to quit, so
  /// closing the window right after typing never loses the last sentence.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onInactive: _saveNow,
      onHide: _saveNow,
      onPause: _saveNow,
      onExitRequested: () async {
        await _saveNowAsync();
        return AppExitResponse.exit;
      },
    );
  }

  void _saveNow() => _saveNowAsync();

  Future<void> _saveNowAsync() async {
    if (!mounted) return;
    try {
      await context.read<ProjectWorkspaceState>().saveNow();
    } catch (_) {
      // Save failures surface through the state's own save indicator.
    }
  }

  /// Runs an [EditorCommand] bound in editor_shortcuts.dart.
  void _runCommand(EditorCommand command) {
    final ProjectWorkspaceState state = context.read<ProjectWorkspaceState>();
    final QuillController? controller = _controller;
    switch (command) {
      case EditorCommand.saveNow:
        _saveNow();
      case EditorCommand.toggleFocusMode:
        if (!state.focusMode) {
          // Focus mode is just the page: close the side panels too.
          setState(() {
            _aiPanelOpen = false;
            _characterPanelOpen = false;
          });
        }
        state.toggleFocusMode();
        _editorFocusNode.requestFocus();
      case EditorCommand.exitFocusMode:
        state.exitFocusMode();
      case EditorCommand.toggleSidebar:
        state.toggleSidebar();
      case EditorCommand.toggleAiPanel:
        state.exitFocusMode();
        setState(() {
          _aiPanelOpen = !_aiPanelOpen;
          if (_aiPanelOpen) _characterPanelOpen = false;
        });
      case EditorCommand.showShortcuts:
        showShortcutsDialog(context);
      case EditorCommand.numberedList:
        if (controller != null) _toggleList(controller, Attribute.ol);
      case EditorCommand.bulletedList:
        if (controller != null) _toggleList(controller, Attribute.ul);
      case EditorCommand.redo:
        if (controller != null && controller.hasRedo) controller.redo();
    }
  }

  /// Applies [list] to the selected lines, or removes it if already applied.
  void _toggleList(QuillController controller, Attribute<String?> list) {
    final Attribute<Object?>? current =
        controller.getSelectionStyle().attributes[Attribute.list.key];
    controller.formatSelection(
      current?.value == list.value
          ? Attribute.clone(Attribute.list, null)
          : list,
    );
  }

  /// The actions behind [editorShortcuts], shared by the editor itself and the
  /// surrounding chrome (toolbar, panels) so shortcuts work wherever focus is.
  late final Map<Type, Action<Intent>> _commandActions =
      <Type, Action<Intent>>{
    EditorCommandIntent: CallbackAction<EditorCommandIntent>(
      onInvoke: (EditorCommandIntent intent) {
        _runCommand(intent.command);
        return null;
      },
    ),
  };

  @override
  void dispose() {
    _lifecycle.dispose();
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

    // Seed the word count from the freshly loaded document.
    _wordCount = _countWords(controller.document.toPlainText());
    _baselineWordCount = _wordCount;

    // Forward local edits (typing / toolbar formatting) to the state layer,
    // which computes the Markdown, enforces the cap, and schedules the save
    // (Req 14.8, 15.4). Programmatic replacements (the load path above) are
    // marked ChangeSource.local by the document API too, but we only ever
    // attach this listener *after* construction, so it fires solely for user
    // edits made through this controller.
    controller.document.changes.listen((DocChange event) {
      if (!mounted) return;

      // Keep the live word count in sync with the current content on every
      // change (user edits and any programmatic replacement).
      final int count = _countWords(controller.document.toPlainText());
      if (count != _wordCount) {
        setState(() => _wordCount = count);
      }

      if (_syncingDocument) return;
      if (event.source != ChangeSource.local) return;
      // [state] is the single workspace instance for this open project; it is
      // stable for the lifetime of this view, so capturing it here (rather than
      // reading the BuildContext in this async callback) is safe.
      state.onContentChanged(controller.document.toDelta());
    });

    _controller = controller;
  }

  /// Counts the words in [text], where a word is any run of non-whitespace
  /// characters. Returns 0 for empty or whitespace-only content.
  int _countWords(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    return trimmed.split(RegExp(r'\s+')).length;
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

    final bool focusMode = state.focusMode;

    final Widget editorColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Focus mode keeps only the page; everything else steps away.
        if (!focusMode) _buildTitleBar(context, active),
        if (!focusMode) _buildToolbarRow(context),
        if (atMaxLength) _buildMaxLengthIndicator(context),
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(child: _buildEditor(focusMode: focusMode)),
              if (focusMode)
                Positioned(
                  right: AppSpacing.lg,
                  bottom: AppSpacing.lg,
                  child: _buildFocusModePill(context),
                ),
            ],
          ),
        ),
      ],
    );

    // Shortcuts also work while focus is in the toolbar or a side panel; when
    // the editor has focus, its own (identical) bindings handle them first.
    return Shortcuts(
      shortcuts: editorShortcuts(inFocusMode: focusMode),
      child: Actions(
        actions: _commandActions,
        child: _buildEditorRow(editorColumn, focusMode: focusMode),
      ),
    );
  }

  /// The editor column plus, outside focus mode, the shared right-hand panel.
  Widget _buildEditorRow(Widget editorColumn, {required bool focusMode}) {
    // The Character Panel and the AI Panel share a single right-hand sidebar
    // slot beside the editor: at most one is open at a time (Req 1.2, 1.3,
    // 1.5), so opening one closes the other and the editor keeps its width.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: editorColumn),
        if (focusMode)
          ...const <Widget>[]
        else if (_characterPanelOpen) ...<Widget>[
          const VerticalDivider(
            width: 1,
            thickness: 1,
            color: AppPalette.hairline,
          ),
          SizedBox(
            width: _sidePanelWidth,
            child: CharacterPanelView(
              onClose: () => setState(() => _characterPanelOpen = false),
            ),
          ),
        ] else if (_aiPanelOpen) ...<Widget>[
          const VerticalDivider(
            width: 1,
            thickness: 1,
            color: AppPalette.hairline,
          ),
          SizedBox(
            width: _sidePanelWidth,
            // While the assistant is unavailable the slot shows a "Coming
            // soon" panel; AiPanelView (and its providers) are never built.
            child: AppInfo.aiAssistantAvailable
                ? AiPanelView(
                    onClose: () => setState(() => _aiPanelOpen = false),
                  )
                : AiComingSoonPanel(
                    onClose: () => setState(() => _aiPanelOpen = false),
                  ),
          ),
        ],
      ],
    );
  }

  /// The fixed width of the right-hand sidebar (Character Panel or AI Panel)
  /// when open.
  static const double _sidePanelWidth = 340;

  /// The panel toggles' style: when a panel is open its toggle sits on a
  /// soft raised pill (instead of the theme's solid primary fill used by the
  /// formatting toggles), so "open" reads clearly without shouting.
  static const ButtonStyle _panelToggleStyle = ButtonStyle(
    backgroundColor: WidgetStateProperty<Color?>.fromMap(
      <WidgetStatesConstraint, Color?>{
        WidgetState.selected: AppPalette.surfaceVariant,
        WidgetState.any: null,
      },
    ),
  );

  /// The toolbar row: the WYSIWYG [EditorToolbar] on the left and the Character
  /// Panel toggle pinned to the right (Req: "put it in the right side of the
  /// editor tool").
  Widget _buildToolbarRow(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppPalette.surface,
        border: Border(bottom: BorderSide(color: AppPalette.hairline)),
      ),
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.xs,
        horizontal: AppSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          // The autosave indicator is pinned to the top-left of the toolbar
          // line so the writer can see at a glance that their text is being
          // saved.
          _buildSaveIndicator(context),
          Expanded(child: EditorToolbar(controller: _controller!)),
          // A hairline separates formatting from the document / panel actions.
          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            color: AppPalette.hairline,
          ),
          IconButton(
            tooltip: 'Export documents',
            icon: const Icon(
              Icons.file_download_outlined,
              color: AppPalette.textSecondary,
            ),
            onPressed: () => showExportDialog(context),
          ),
          const SizedBox(width: AppSpacing.xxs),
          IconButton(
            tooltip: _aiPanelOpen ? 'Hide AI assistant' : 'Show AI assistant',
            isSelected: _aiPanelOpen,
            style: _panelToggleStyle,
            icon: Icon(
              Icons.auto_awesome,
              color: _aiPanelOpen
                  ? AppPalette.secondary
                  : AppPalette.textSecondary,
            ),
            onPressed: () => setState(() {
              _aiPanelOpen = !_aiPanelOpen;
              // Both panels share the one right-hand slot; opening the AI Panel
              // closes the Character Panel so the editor keeps its width
              // (Req 1.5).
              if (_aiPanelOpen) _characterPanelOpen = false;
            }),
          ),
          const SizedBox(width: AppSpacing.xxs),
          IconButton(
            tooltip:
                _characterPanelOpen ? 'Hide characters' : 'Show characters',
            isSelected: _characterPanelOpen,
            style: _panelToggleStyle,
            icon: Icon(
              Icons.people_alt_outlined,
              color: _characterPanelOpen
                  ? AppPalette.secondary
                  : AppPalette.textSecondary,
            ),
            onPressed: () => setState(() {
              _characterPanelOpen = !_characterPanelOpen;
              // Opening the Character Panel closes the AI Panel — the two
              // panels are mutually exclusive in the shared slot (Req 1.5).
              if (_characterPanelOpen) _aiPanelOpen = false;
            }),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  /// The autosave status indicator shown at the top-left of the toolbar line.
  ///
  /// It reflects [ProjectWorkspaceState.saveStatus]: a spinner with "Saving…"
  /// while an edit is unsaved / being written, a check with "Saved" once the
  /// content is on disk, and a warning with "Save failed" if the last save
  /// errored. Before any edit is made to the current document (idle) it renders
  /// nothing, keeping the toolbar clean until the writer starts typing.
  Widget _buildSaveIndicator(BuildContext context) {
    final SaveStatus status = context.select<ProjectWorkspaceState, SaveStatus>(
      (ProjectWorkspaceState s) => s.saveStatus,
    );

    final TextStyle? labelStyle = Theme.of(context).textTheme.bodySmall;

    late final Widget leading;
    late final String label;
    late final Color color;

    switch (status) {
      case SaveStatus.idle:
        return const SizedBox(width: 12);
      case SaveStatus.saving:
        color = AppPalette.textSecondary;
        label = 'Saving…';
        leading = const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AppPalette.textSecondary),
          ),
        );
      case SaveStatus.saved:
        color = AppPalette.secondary;
        label = 'Saved';
        leading = const Icon(
          Icons.cloud_done_outlined,
          size: 14,
          color: AppPalette.secondary,
        );
      case SaveStatus.error:
        color = AppPalette.error;
        label = 'Save failed';
        leading = const Icon(
          Icons.error_outline,
          size: 14,
          color: AppPalette.error,
        );
    }

    // A soft, rounded status pill so the indicator reads as a distinct chip
    // rather than loose text next to the toolbar.
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.sm, right: AppSpacing.xs),
      child: AnimatedContainer(
        duration: AppMotion.medium,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppPalette.surfaceVariant,
          borderRadius: AppStyle.pillRadius,
          border: Border.all(color: AppPalette.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            leading,
            const SizedBox(width: 6),
            Text(
              label,
              style: labelStyle?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The no-active-document placeholder prompting the user to select or create
  /// a document (Req 14.10). Contains no editor, so input is rejected.
  Widget _buildPlaceholder(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: AppStyle.appBackground),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppPalette.surfaceVariant,
                    borderRadius: AppStyle.cardRadius,
                    border: Border.all(color: AppPalette.hairline),
                  ),
                  child: const Icon(
                    Icons.edit_note_rounded,
                    size: 34,
                    color: AppPalette.secondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Select a document from the list, or create a new one to '
                  'start writing.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: AppPalette.textSecondary,
                        height: 1.5,
                      ),
                ),
              ],
            ),
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
      decoration: const BoxDecoration(gradient: AppStyle.panelSurface),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xl - 4,
        vertical: AppSpacing.md + 2,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: widget.onRenameRequested == null
                ? titleText
                : InkWell(
                    onTap: widget.onRenameRequested,
                    borderRadius: AppStyle.pillRadius,
                    focusColor: AppPalette.pressedOverlay,
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
          const SizedBox(width: 12),
          _buildWordCount(context),
        ],
      ),
    );
  }

  /// The live word-count badge shown in the upper-right corner of the title
  /// bar. Reflects [_wordCount], which is kept in sync with the editor content.
  Widget _buildWordCount(BuildContext context) {
    final int written = _wordCount - _baselineWordCount;
    final String label = written > 0
        ? '${_wordsLabel(_wordCount)}  ·  +${_formatCount(written)}'
        : _wordsLabel(_wordCount);
    return Tooltip(
      message: written > 0
          ? '${_formatCount(written)} words written since you opened this '
              'document'
          : 'Words in this document',
      child: _buildWordCountChip(context, label),
    );
  }

  /// "1 word" / "1,234 words".
  static String _wordsLabel(int count) =>
      count == 1 ? '1 word' : '${_formatCount(count)} words';

  /// Formats [n] with thousands separators (1234 → "1,234").
  static String _formatCount(int n) {
    final String digits = n.abs().toString();
    final StringBuffer out = StringBuffer(n < 0 ? '-' : '');
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  /// The quiet status pill shown in focus mode: word count and how to leave.
  Widget _buildFocusModePill(BuildContext context) {
    return Opacity(
      opacity: 0.85,
      child: _buildWordCountChip(
        context,
        '${_wordsLabel(_wordCount)}  ·  Esc to leave focus mode',
      ),
    );
  }

  Widget _buildWordCountChip(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs + 1,
      ),
      decoration: BoxDecoration(
        color: AppPalette.surfaceVariant,
        borderRadius: AppStyle.pillRadius,
        border: Border.all(color: AppPalette.hairline),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppPalette.secondary,
              fontWeight: FontWeight.w600,
            ),
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
  Widget _buildEditor({required bool focusMode}) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Keep the manuscript at a comfortable reading measure on wide desktop
        // windows. The margin is applied *inside* the editor's scroll view so
        // the wheel scrolls anywhere and the scrollbar stays at the edge.
        // Focus mode uses a slightly narrower, book-like column.
        final double measure = focusMode ? _focusMeasure : _maxMeasure;
        final double side = constraints.maxWidth > measure + 2 * AppSpacing.xl
            ? (constraints.maxWidth - measure) / 2
            : AppSpacing.xl;
        // Generous bottom padding lets the last lines be scrolled up to eye
        // level instead of being pinned to the bottom edge of the window.
        final double bottom = constraints.maxHeight.isFinite
            ? constraints.maxHeight * 0.4
            : AppSpacing.xxl;
        return _buildQuillEditor(
          EdgeInsets.fromLTRB(
            side,
            focusMode ? AppSpacing.xxl : AppSpacing.lg,
            side,
            bottom,
          ),
          focusMode: focusMode,
        );
      },
    );
  }

  /// The widest the manuscript text column grows, in logical pixels.
  static const double _maxMeasure = 860;

  /// The text column width in focus mode (~70 characters per line).
  static const double _focusMeasure = 720;

  Widget _buildQuillEditor(EdgeInsets padding, {required bool focusMode}) {
    return ColoredBox(
      color: AppPalette.background,
      child: QuillEditor(
        controller: _controller!,
        focusNode: _editorFocusNode,
        scrollController: _editorScrollController,
        config: QuillEditorConfig(
          placeholder: 'Start writing…',
          padding: padding,
          expands: true,
          scrollable: true,
          autoFocus: false,
          // Hard-wire Tab to insert our fixed 10-wide indent. flutter_quill
          // calls [onKeyPressed] *before* its own internal Tab handling (which
          // would otherwise insert a single '\t' or indent a list); returning a
          // non-null result here short-circuits that, so our indent always
          // wins on every platform, including web.
          onKeyPressed: _onEditorKeyPressed,
          // Word-processor shortcuts on top of flutter_quill's defaults, and
          // unsupported default formats switched off (editor_shortcuts.dart).
          customShortcuts: editorShortcuts(inFocusMode: focusMode),
          customActions: _commandActions,
          // Typing replacements, e.g. `---` becomes an em dash (—).
          characterShortcutEvents: typingShortcutEvents,
          // Serif body text with double (2.0) line spacing — the Google Docs
          // standard for manuscripts. Only the styles we want to override are
          // provided; flutter_quill merges these over its defaults.
          customStyles: _editorStyles,
        ),
      ),
    );
  }

  /// flutter_quill's pre-handler hook, wired via [QuillEditorConfig.onKeyPressed]
  /// and invoked before the editor's built-in key handling. On a Tab key-down
  /// (without Shift) it inserts the fixed 10-wide indent and returns
  /// [KeyEventResult.handled] so the editor's default Tab behaviour is skipped.
  /// Every other key returns `null`, letting the editor handle it normally.
  KeyEventResult? _onEditorKeyPressed(KeyEvent event, Node? node) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    if (event.logicalKey != LogicalKeyboardKey.tab) return null;
    // Leave Shift+Tab to the default (outdent) behaviour.
    if (HardwareKeyboard.instance.isShiftPressed) return null;

    _insertTabIndent();
    return KeyEventResult.handled;
  }

  /// The number of spaces one Tab press inserts (the indent width).
  static const int _tabWidth = 10;

  /// The literal text a Tab press inserts: [_tabWidth] no-break spaces
  /// (U+00A0).
  ///
  /// Plain ASCII spaces are NOT used because the document body is persisted as
  /// Markdown: on save/reload, Markdown collapses runs of spaces and turns four
  /// or more leading spaces into a code block, so an ASCII-space indent would
  /// visibly disappear or turn into monospaced code after autosave. No-break
  /// spaces are ordinary text to the Markdown codec, so the 10-wide indent
  /// round-trips intact and renders as a real indent in the editor and exports.
  static final String _tabIndent = '\u00A0' * _tabWidth;

  /// Inserts [_tabWidth] no-break spaces at the current selection (replacing any
  /// selected text) and places the caret after the indent. Invoked from
  /// [_onEditorKey] on Tab so it runs before the editor's default Tab handling;
  /// the edit goes through the normal local-edit path so it is captured, saved,
  /// and Markdown-encoded.
  void _insertTabIndent() {
    final QuillController? controller = _controller;
    if (controller == null) return;

    final TextSelection selection = controller.selection;
    if (!selection.isValid) return;

    final int start = selection.start;
    final int length = selection.end - selection.start;
    controller.replaceText(
      start,
      length,
      _tabIndent,
      TextSelection.collapsed(offset: start + _tabIndent.length),
    );
  }

  /// The bundled book serif used for the editor body. Declared in pubspec.yaml
  /// from the EB Garamond variable fonts under assets/fonts/, so it renders the
  /// same literary typeface on every platform (including web).
  static const String _serifFamily = 'EB Garamond';

  /// The body font size for the paragraph / list text. EB Garamond runs a
  /// little small, so it is set slightly larger to read comfortably like a book.
  static const double _bodyFontSize = 19;

  /// The line-height multiplier applied to body text: 2.0 (double spacing),
  /// the Google Docs standard.
  static const double _lineHeight = 2.0;

  /// Fallback serif faces used if the bundled [_serifFamily] is unavailable.
  static const List<String> _serifFallback = <String>[
    'Georgia',
    'Times New Roman',
    'serif',
  ];

  /// Serif body text styles with double (2.0) line spacing, layered over
  /// flutter_quill's defaults via [QuillEditorConfig.customStyles]. The body,
  /// list items, and every heading level use the bundled book serif so the
  /// whole manuscript reads as one serif, double-spaced document.
  static const DefaultStyles _editorStyles = DefaultStyles(
    h1: DefaultTextBlockStyle(
      TextStyle(
        fontFamily: _serifFamily,
        fontFamilyFallback: _serifFallback,
        fontSize: 34,
        height: 1.25,
        fontWeight: FontWeight.w700,
        color: AppPalette.textPrimary,
        decoration: TextDecoration.none,
      ),
      HorizontalSpacing(0, 0),
      VerticalSpacing(16, 0),
      VerticalSpacing(0, 0),
      null,
    ),
    h2: DefaultTextBlockStyle(
      TextStyle(
        fontFamily: _serifFamily,
        fontFamilyFallback: _serifFallback,
        fontSize: 28,
        height: 1.3,
        fontWeight: FontWeight.w700,
        color: AppPalette.textPrimary,
        decoration: TextDecoration.none,
      ),
      HorizontalSpacing(0, 0),
      VerticalSpacing(12, 0),
      VerticalSpacing(0, 0),
      null,
    ),
    h3: DefaultTextBlockStyle(
      TextStyle(
        fontFamily: _serifFamily,
        fontFamilyFallback: _serifFallback,
        fontSize: 23,
        height: 1.35,
        fontWeight: FontWeight.w700,
        color: AppPalette.textPrimary,
        decoration: TextDecoration.none,
      ),
      HorizontalSpacing(0, 0),
      VerticalSpacing(8, 0),
      VerticalSpacing(0, 0),
      null,
    ),
    paragraph: DefaultTextBlockStyle(
      TextStyle(
        fontFamily: _serifFamily,
        fontFamilyFallback: _serifFallback,
        fontSize: _bodyFontSize,
        height: _lineHeight,
        color: AppPalette.textPrimary,
        decoration: TextDecoration.none,
      ),
      HorizontalSpacing(0, 0),
      VerticalSpacing(0, 0),
      VerticalSpacing(0, 0),
      null,
    ),
    lists: DefaultListBlockStyle(
      TextStyle(
        fontFamily: _serifFamily,
        fontFamilyFallback: _serifFallback,
        fontSize: _bodyFontSize,
        height: _lineHeight,
        color: AppPalette.textPrimary,
        decoration: TextDecoration.none,
      ),
      HorizontalSpacing(0, 0),
      VerticalSpacing(6, 0),
      VerticalSpacing(0, 6),
      null,
      null,
    ),
  );
}
