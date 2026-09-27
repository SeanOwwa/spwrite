/// Presentation layer: [EditorToolbar], the WYSIWYG formatting toolbar for the
/// [EditorView], built on `flutter_quill`'s [QuillSimpleToolbar] and bound to
/// the active [QuillController].
///
/// The toolbar is restricted to exactly the formatting controls the app
/// supports and stores as Markdown — bold, italic, heading levels, ordered
/// list, unordered (bullet) list, and link (Req 14.2–14.7). Every other
/// [QuillSimpleToolbar] button (font family/size, underline, strikethrough,
/// inline code, colors, clear-format, alignment, subscript/superscript,
/// checklist, code block, quote, indent, undo/redo, search, clipboard) is
/// disabled so the toolbar maps one-to-one to the supported Markdown feature
/// set — no control can produce Markdown the codec does not round-trip.
///
/// Colors are drawn only from [AppPalette] so the toolbar matches the dark
/// theme rather than falling back to a light-mode / system-default color
/// (Req 18.2, 18.5): the toolbar surface uses [AppPalette.surface], section
/// dividers use [AppPalette.outline], and the button icons are themed via a
/// [QuillIconTheme] — unselected controls in [AppPalette.textSecondary],
/// selected (active) controls in [AppPalette.primary] over an
/// [AppPalette.surfaceVariant] fill.
library;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../theme/app_theme.dart';

/// The WYSIWYG formatting toolbar bound to [controller], exposing only the
/// supported controls: bold, italic, headings, ordered list, unordered
/// (bullet) list, and link (Req 14.2–14.7). Dark-themed via [AppPalette].
class EditorToolbar extends StatelessWidget {
  /// The [QuillController] of the currently active document. Every toolbar
  /// action mutates this controller's document; the enclosing editor forwards
  /// those edits to the state layer, which converts and persists Markdown.
  final QuillController controller;

  const EditorToolbar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return QuillSimpleToolbar(
      controller: controller,
      config: const QuillSimpleToolbarConfig(
        // Draw the toolbar surface and its dividers from the dark palette so
        // no slot falls back to a light-mode / system-default color
        // (Req 18.2, 18.5).
        color: AppPalette.surface,
        sectionDividerColor: AppPalette.outline,
        iconTheme: _darkIconTheme,

        // --- Supported controls: on (Req 14.2–14.7) ----------------------
        showBoldButton: true, // Req 14.2
        showItalicButton: true, // Req 14.3
        showHeaderStyle: true, // Req 14.4 (heading levels)
        showListNumbers: true, // Req 14.6 (ordered list)
        showListBullets: true, // Req 14.5 (unordered / bullet list)
        showLink: true, // Req 14.7

        // --- Everything else: off ----------------------------------------
        // Disabled so the toolbar maps one-to-one to the supported Markdown
        // feature set — no button can introduce formatting the Markdown codec
        // does not round-trip.
        showFontFamily: false,
        showFontSize: false,
        showSmallButton: false,
        showUnderLineButton: false,
        showStrikeThrough: false,
        showInlineCode: false,
        showColorButton: false,
        showBackgroundColorButton: false,
        showClearFormat: false,
        showAlignmentButtons: false,
        showLineHeightButton: false,
        showListCheck: false,
        showCodeBlock: false,
        showQuote: false,
        showIndent: false,
        showUndo: false,
        showRedo: false,
        showDirection: false,
        showSearchButton: false,
        showSubscript: false,
        showSuperscript: false,
        // Clipboard cut/copy/paste buttons already default to off; the
        // (experimental) flags are left at their default rather than set
        // explicitly to keep the config on the stable API surface.
      ),
    );
  }

  /// Themes the toolbar's icon buttons from the dark palette (Req 18.2, 18.5):
  /// unselected controls in [AppPalette.textSecondary]; the active/selected
  /// control in [AppPalette.primary] over an [AppPalette.surfaceVariant] fill.
  static const QuillIconTheme _darkIconTheme = QuillIconTheme(
    iconButtonUnselectedData: IconButtonData(
      color: AppPalette.textSecondary,
    ),
    iconButtonSelectedData: IconButtonData(
      color: AppPalette.primary,
      style: ButtonStyle(
        backgroundColor: WidgetStatePropertyAll(AppPalette.surfaceVariant),
      ),
    ),
  );
}
