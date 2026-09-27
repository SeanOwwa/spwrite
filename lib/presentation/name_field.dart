/// Presentation layer: [NameField], the reusable inline editable Name/Title
/// field the app presents when the user activates a create or rename control
/// for a Project, Folder, or Document (Req 2.1, 3.1, 7.1, 8.1, 12.1).
///
/// This is the generalized successor to v1's `RenameField`. It is used in three
/// places with the same shape:
///   * Project Name (Dashboard create / rename) — Req 2.1, 3.1.
///   * Folder Name (Project_Sidebar create / rename) — Req 7.1, 8.1.
///   * Document Title (Project_Sidebar rename) — Req 12.1.
///
/// The field opens pre-filled with the current value and with that text fully
/// selected so the user can immediately overtype it (Req 3.1, 8.1, 12.1). It
/// offers confirm (submit / check button) and cancel (escape / X button)
/// affordances. On confirm with a locally valid value it hands the trimmed
/// value to [onConfirm]; on cancel it invokes [onCancel] so the caller can
/// close the field and retain the previous value (Req 3.6, 8.6, 12.6).
///
/// The *authoritative* validation lives in the state layer (e.g.
/// `AppNavigationState.createProject` / `renameProject`,
/// `ProjectWorkspaceState.createFolder` / `renameFolder` / `renameDocument`),
/// which trims and accepts a 1..255 character value. This widget performs only
/// lightweight local validation for immediate feedback, using messages that
/// name the field ("Name" or "Title") so the user sees consistent wording
/// whether the value is caught here or there (Req 2.3, 2.4, 3.3, 3.4, 7.3, 7.4,
/// 8.3, 8.4, 12.3, 12.4).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// The kind of label this [NameField] edits. Determines the wording of the
/// hint text and validation messages so they name the field the user is
/// editing ("Name" for Projects/Folders, "Title" for Documents).
enum NameFieldLabel {
  /// Project or Folder Name (Req 2.1, 3.1, 7.1, 8.1).
  name('Name'),

  /// Document Title (Req 12.1).
  title('Title');

  const NameFieldLabel(this.text);

  /// The human-readable noun used in the hint and validation messages.
  final String text;
}

/// A reusable inline editable Name/Title field with confirm / cancel
/// affordances and lightweight local validation messaging (Req 2.1, 3.1, 7.1,
/// 8.1, 12.1).
///
/// Managed as a [StatefulWidget] so it can own the [TextEditingController] and
/// [FocusNode] it needs to pre-select the text and hold focus, and dispose them
/// when the field closes.
class NameField extends StatefulWidget {
  /// The current Name/Title, used to pre-fill the field. The full text is
  /// selected when the field opens so the user can overtype it immediately
  /// (Req 3.1, 8.1, 12.1). For a create flow this is typically an empty string.
  final String initialValue;

  /// Which noun this field edits ("Name" or "Title"). Controls the hint and
  /// validation message wording so they match the entity being edited.
  final NameFieldLabel label;

  /// Called when the user confirms a locally valid value (submit / check). The
  /// caller forwards this to the authoritative flow, which re-validates,
  /// trims, and persists it. The value passed here is already trimmed.
  final void Function(String value) onConfirm;

  /// Called when the user cancels (escape / X button). The caller closes the
  /// field and retains the previous value (Req 3.6, 8.6, 12.6).
  final VoidCallback onCancel;

  const NameField({
    super.key,
    required this.initialValue,
    required this.onConfirm,
    required this.onCancel,
    this.label = NameFieldLabel.name,
  });

  @override
  State<NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<NameField> {
  /// The maximum trimmed length accepted by the authoritative flows (Req 2.2,
  /// 3.2, 7.2, 8.2, 12.2). Mirrored here so the local pre-check matches the
  /// state layer exactly.
  static const int _maxLength = 255;

  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  /// The current inline validation message, or `null` when the value is
  /// locally valid. Rendered beneath the field for immediate feedback.
  String? _errorText;

  /// Message shown for an empty / whitespace-only value (Req 2.3, 3.3, 7.3,
  /// 8.3, 12.3). Named for the field so the wording matches the entity.
  String get _emptyMessage => 'A ${widget.label.text.toLowerCase()} is required.';

  /// Message shown for an over-length value (Req 2.4, 3.4, 7.4, 8.4, 12.4).
  String get _tooLongMessage =>
      '${widget.label.text} exceeds the $_maxLength character maximum.';

  @override
  void initState() {
    super.initState();
    // Pre-fill with the current value and select the whole text so the user
    // can immediately overtype it (Req 3.1, 8.1, 12.1).
    _controller = TextEditingController(text: widget.initialValue);
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
    _focusNode = FocusNode();
    // Request focus once the field is mounted so it opens ready for input.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Lightweight local validation mirroring the authoritative rules (empty /
  /// over-length). Returns an error message, or `null` when the trimmed value
  /// is acceptable.
  String? _validate(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) return _emptyMessage;
    if (trimmed.length > _maxLength) return _tooLongMessage;
    return null;
  }

  /// Handles a confirm gesture (submit / check button). On a locally valid
  /// value, forwards the trimmed value to [NameField.onConfirm]; otherwise
  /// surfaces the inline error for immediate feedback.
  void _handleConfirm() {
    final String value = _controller.text;
    final String? error = _validate(value);
    if (error != null) {
      setState(() => _errorText = error);
      return;
    }
    widget.onConfirm(value.trim());
  }

  /// Handles a cancel gesture (escape / X button): retains the previous value
  /// and lets the caller close the field (Req 3.6, 8.6, 12.6).
  void _handleCancel() {
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final String noun = widget.label.text;
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              _handleCancel();
              return null;
            },
          ),
        },
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                autofocus: true,
                maxLines: 1,
                textInputAction: TextInputAction.done,
                style: const TextStyle(color: AppPalette.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: noun,
                  // Inline validation feedback. Error color is drawn from the
                  // dark palette (Req 18.x).
                  errorText: _errorText,
                  errorStyle: const TextStyle(color: AppPalette.error),
                ),
                // Clear a stale error as soon as the user edits again.
                onChanged: (_) {
                  if (_errorText != null) {
                    setState(() => _errorText = null);
                  }
                },
                // Confirm on submit / Enter.
                onSubmitted: (_) => _handleConfirm(),
              ),
            ),
            // Confirm affordance.
            IconButton(
              tooltip: 'Confirm',
              icon: const Icon(Icons.check, color: AppPalette.primary),
              onPressed: _handleConfirm,
            ),
            // Cancel affordance (Req 3.6, 8.6, 12.6).
            IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close, color: AppPalette.textSecondary),
              onPressed: _handleCancel,
            ),
          ],
        ),
      ),
    );
  }
}
