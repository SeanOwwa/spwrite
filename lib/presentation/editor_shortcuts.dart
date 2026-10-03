/// Presentation layer: the editor's keyboard shortcuts.
///
/// One place defines every shortcut the writing surface responds to, the
/// platform-aware labels shown in tooltips, and the "Keyboard shortcuts"
/// help sheet, so what the writer sees always matches what the keys do.
///
/// flutter_quill ships its own defaults (Cmd/Ctrl+B, I, K, Z, Y, 0–3, F …).
/// Those are kept. Defaults that would produce formatting the Markdown codec
/// cannot store (underline, strikethrough, inline code, code block, quote,
/// checklist, indent, image) are disabled here so a stray key never creates
/// formatting that silently disappears after autosave.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// CharacterShortcutEvent is marked @experimental in flutter_quill 11.6.0; it
// is the editor's hook for typing-time replacements like `---`. Used
// deliberately in this one file, so the lint is silenced here only.
// ignore_for_file: experimental_member_use
import 'package:flutter_quill/flutter_quill.dart'
    show CharacterShortcutEvent, QuillController;

import '../theme/app_theme.dart';

/// The commands the editor binds to keys beyond flutter_quill's defaults.
enum EditorCommand {
  saveNow,
  toggleFocusMode,
  exitFocusMode,
  toggleSidebar,
  toggleAiPanel,
  showShortcuts,
  numberedList,
  bulletedList,
  redo,
}

/// The intent every editor shortcut maps to; the command says which.
class EditorCommandIntent extends Intent {
  final EditorCommand command;
  const EditorCommandIntent(this.command);
}

/// Whether shortcuts use Cmd (Apple platforms, including web on a Mac) or Ctrl.
bool get _usesCommandKey =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// A primary-modifier (Cmd on Mac, Ctrl elsewhere) activator for [key].
SingleActivator _primary(LogicalKeyboardKey key, {bool shift = false}) =>
    SingleActivator(
      key,
      meta: _usesCommandKey,
      control: !_usesCommandKey,
      shift: shift,
    );

/// Builds the shortcut map. [inFocusMode] additionally binds Esc to leave
/// focus mode (outside it, Esc keeps its usual meaning).
Map<ShortcutActivator, Intent> editorShortcuts({required bool inFocusMode}) {
  EditorCommandIntent cmd(EditorCommand c) => EditorCommandIntent(c);
  return <ShortcutActivator, Intent>{
    _primary(LogicalKeyboardKey.keyS): cmd(EditorCommand.saveNow),
    _primary(LogicalKeyboardKey.keyF, shift: true):
        cmd(EditorCommand.toggleFocusMode),
    _primary(LogicalKeyboardKey.backslash): cmd(EditorCommand.toggleSidebar),
    _primary(LogicalKeyboardKey.keyA, shift: true):
        cmd(EditorCommand.toggleAiPanel),
    _primary(LogicalKeyboardKey.slash): cmd(EditorCommand.showShortcuts),
    _primary(LogicalKeyboardKey.keyZ, shift: true): cmd(EditorCommand.redo),
    // Google Docs list shortcuts. Shift+7 / Shift+8 may report either the
    // digit or the shifted symbol depending on platform, so bind both.
    _primary(LogicalKeyboardKey.digit7, shift: true):
        cmd(EditorCommand.numberedList),
    _primary(LogicalKeyboardKey.ampersand, shift: true):
        cmd(EditorCommand.numberedList),
    _primary(LogicalKeyboardKey.digit8, shift: true):
        cmd(EditorCommand.bulletedList),
    _primary(LogicalKeyboardKey.asterisk, shift: true):
        cmd(EditorCommand.bulletedList),
    if (inFocusMode)
      const SingleActivator(LogicalKeyboardKey.escape):
          cmd(EditorCommand.exitFocusMode),

    // flutter_quill defaults for formatting Markdown cannot store: disabled.
    for (final SingleActivator unsupported in <SingleActivator>[
      _primary(LogicalKeyboardKey.keyU), // underline
      _primary(LogicalKeyboardKey.keyS, shift: true), // strikethrough
      _primary(LogicalKeyboardKey.backquote), // inline code
      _primary(LogicalKeyboardKey.tilde, shift: true), // code block
      _primary(LogicalKeyboardKey.keyB, shift: true), // block quote
      _primary(LogicalKeyboardKey.keyC, shift: true), // checklist
      _primary(LogicalKeyboardKey.keyM), // indent
      _primary(LogicalKeyboardKey.keyM, shift: true), // outdent
      _primary(LogicalKeyboardKey.keyG), // image embed
    ])
      unsupported: const DoNothingAndStopPropagationIntent(),
  };
}

/// The em dash (—) that typing three hyphens produces.
const String emDash = '\u2014';

/// Typing-time replacements, handed to `QuillEditorConfig.characterShortcutEvents`.
///
/// Typing `---` turns into an em dash (—), as in word processors. The handler
/// runs as the third `-` is typed: when the two characters before the caret
/// are `--`, they are replaced by `—` and the third hyphen is swallowed. Undo
/// (Cmd/Ctrl+Z) brings the hyphens back.
const List<CharacterShortcutEvent> typingShortcutEvents =
    <CharacterShortcutEvent>[
  CharacterShortcutEvent(
    key: 'Three hyphens make an em dash',
    character: '-',
    handler: applyEmDash,
  ),
];

/// Replaces `--` before a collapsed caret with [emDash] and returns `true`
/// (the typed `-` is then not inserted). Returns `false`, leaving the hyphen
/// to be typed normally, in every other case, including a range selection.
bool applyEmDash(QuillController controller) {
  if (controller.readOnly) return false;
  final TextSelection selection = controller.selection;
  if (!selection.isValid || !selection.isCollapsed) return false;
  final int caret = selection.baseOffset;
  if (caret < 2) return false;
  final String text = controller.document.toPlainText();
  if (caret > text.length || text.substring(caret - 2, caret) != '--') {
    return false;
  }
  controller.replaceText(
    caret - 2,
    2,
    emDash,
    TextSelection.collapsed(offset: caret - 1),
  );
  return true;
}

/// Platform-aware labels for tooltips and the help sheet ("⌘B" / "Ctrl+B").
class ShortcutLabel {
  const ShortcutLabel._();

  static String get _mod => _usesCommandKey ? '⌘' : 'Ctrl+';
  static String get _shift => _usesCommandKey ? '⇧' : 'Shift+';

  /// Primary modifier + [key], e.g. `of('B')` → "⌘B".
  static String of(String key) => '$_mod$key';

  /// Primary modifier + Shift + [key], e.g. `shifted('7')` → "⌘⇧7".
  static String shifted(String key) =>
      _usesCommandKey ? '$_mod$_shift$key' : '${_mod}Shift+$key';

  /// A tooltip such as "Bold (⌘B)".
  static String tooltip(String action, String keys) => '$action ($keys)';
}

/// Shows the "Keyboard shortcuts" sheet (opened with Cmd/Ctrl+/).
Future<void> showShortcutsDialog(BuildContext context) {
  final List<(String, List<(String, String)>)> groups =
      <(String, List<(String, String)>)>[
    (
      'Formatting',
      <(String, String)>[
        ('Bold', ShortcutLabel.of('B')),
        ('Italic', ShortcutLabel.of('I')),
        ('Heading 1 / 2 / 3', '${ShortcutLabel.of('1')} / 2 / 3'),
        ('Normal text', ShortcutLabel.of('0')),
        ('Numbered list', ShortcutLabel.shifted('7')),
        ('Bulleted list', ShortcutLabel.shifted('8')),
        ('Insert or edit link', ShortcutLabel.of('K')),
      ],
    ),
    (
      'Editing',
      <(String, String)>[
        ('Undo', ShortcutLabel.of('Z')),
        ('Redo', '${ShortcutLabel.shifted('Z')}  or  ${ShortcutLabel.of('Y')}'),
        ('Find in document', ShortcutLabel.of('F')),
        ('Save now', ShortcutLabel.of('S')),
        ('Indent paragraph', 'Tab'),
        ('Em dash (—)', 'Type ---'),
      ],
    ),
    (
      'View',
      <(String, String)>[
        ('Focus mode', ShortcutLabel.shifted('F')),
        ('Leave focus mode', 'Esc'),
        ('Show or hide the sidebar', ShortcutLabel.of('\\')),
        ('Show or hide the AI assistant', ShortcutLabel.shifted('A')),
        ('This list', ShortcutLabel.of('/')),
      ],
    ),
  ];

  return showDialog<void>(
    context: context,
    builder: (BuildContext context) {
      final TextTheme text = Theme.of(context).textTheme;
      return AlertDialog(
        backgroundColor: AppPalette.surface,
        title: Text(
          'Keyboard shortcuts',
          style: text.titleLarge?.copyWith(color: AppPalette.textPrimary),
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final (String title, List<(String, String)> rows)
                    in groups) ...<Widget>[
                  Padding(
                    padding: const EdgeInsets.only(
                      top: AppSpacing.md,
                      bottom: AppSpacing.xs,
                    ),
                    child: Text(
                      title,
                      style: text.labelLarge?.copyWith(
                        color: AppPalette.secondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  for (final (String action, String keys) in rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              action,
                              style: text.bodyMedium
                                  ?.copyWith(color: AppPalette.textPrimary),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppPalette.surfaceVariant,
                              borderRadius: AppStyle.pillRadius,
                              border: Border.all(color: AppPalette.hairline),
                            ),
                            child: Text(
                              keys,
                              style: text.bodySmall?.copyWith(
                                color: AppPalette.textSecondary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
