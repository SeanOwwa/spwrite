/// Presentation layer: [DocumentListItem], one row of the Sidebar's
/// Document_List, and [displayTitle], the pure display-title transformation it
/// uses.
///
/// The transformation is exposed as a top-level pure function ([displayTitle])
/// so it can be verified directly by the Property 4 test without building a
/// widget tree. The widget only reads a [Document]'s stored title through this
/// function; it never mutates the stored title (Req 1.2, 1.3).
library;

import 'package:flutter/material.dart';

import '../domain/document.dart';
import '../theme/app_theme.dart';

/// The placeholder shown when a Document has no meaningful Title (Req 1.2).
///
/// This is intentionally the same string as [Document.newDocument]'s default
/// title so that a brand-new document and a document whose title has been
/// cleared to whitespace present identically in the Sidebar.
const String kUntitledPlaceholder = 'Untitled Document';

/// The maximum number of characters of the stored Title shown before it is
/// truncated (Req 1.3). The [kTruncationIndicator] is appended *in addition*
/// to these characters, so a truncated display string is
/// `kMaxDisplayTitleLength` title characters followed by the indicator.
const int kMaxDisplayTitleLength = 60;

/// The truncation indicator appended after the first [kMaxDisplayTitleLength]
/// characters when a Title is truncated (Req 1.3). A single-character ellipsis
/// (U+2026), counted separately from the 60 title characters.
const String kTruncationIndicator = '\u2026';

/// Transforms a Document's stored Title into the string the Sidebar displays,
/// without altering the stored Title (Property 4, Req 1.2, 1.3).
///
/// Rules, applied in order:
/// 1. If [storedTitle] trims to empty (empty or whitespace-only), return the
///    untitled placeholder [kUntitledPlaceholder] (Req 1.2).
/// 2. Otherwise, if [storedTitle] is longer than [kMaxDisplayTitleLength]
///    (60) characters, return its first 60 characters followed by the
///    truncation indicator [kTruncationIndicator] (Req 1.3). The 60 counts
///    Title characters only; the indicator is appended in addition.
/// 3. Otherwise, return [storedTitle] unchanged.
///
/// This function is pure: it reads [storedTitle] and returns a new string,
/// leaving the caller's [Document.title] fully intact and retrievable.
String displayTitle(String storedTitle) {
  if (storedTitle.trim().isEmpty) {
    return kUntitledPlaceholder;
  }
  if (storedTitle.length > kMaxDisplayTitleLength) {
    return storedTitle.substring(0, kMaxDisplayTitleLength) +
        kTruncationIndicator;
  }
  return storedTitle;
}

/// A single row in the Sidebar's Document_List.
///
/// Renders the Document's display title (via [displayTitle]) and visually
/// distinguishes the row when it represents the Active_Document (Req 1.8),
/// using colors drawn only from [AppPalette]. Tapping the row invokes
/// [onTap]; the optional [trailing] slot holds per-item controls (e.g. rename
/// / delete) supplied by the Sidebar.
class DocumentListItem extends StatelessWidget {
  /// The Document this row represents. Its stored [Document.title] is read but
  /// never modified.
  final Document document;

  /// Whether this Document is the Active_Document. When true, the row is
  /// visually highlighted (Req 1.8).
  final bool isActive;

  /// Called when the user taps the row (select the Document).
  final VoidCallback? onTap;

  /// Optional trailing widget, typically the per-item rename/delete controls.
  final Widget? trailing;

  const DocumentListItem({
    super.key,
    required this.document,
    this.isActive = false,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final String shown = displayTitle(document.title);

    // Wrap in a Material with the Sidebar surface color so the ListTile's
    // (selected)tile color and ink splashes have a surface to paint on;
    // without a Material ancestor Flutter warns that those colors may be
    // invisible. The color still comes only from the dark palette (Req 8.5).
    return Material(
      color: AppPalette.surface,
      child: ListTile(
        selected: isActive,
        // Active-row highlight and text emphasis come from the dark palette so
        // the row never falls back to a light-mode/system-default color
        // (Req 1.8, 8.5).
        selectedTileColor: AppPalette.surfaceVariant,
        selectedColor: AppPalette.textPrimary,
        title: Text(
          shown,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isActive ? AppPalette.textPrimary : AppPalette.textSecondary,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        onTap: onTap,
        trailing: trailing,
      ),
    );
  }
}
