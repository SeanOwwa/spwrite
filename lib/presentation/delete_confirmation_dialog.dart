/// Presentation layer: [DeleteConfirmationDialog], the confirm / cancel prompt
/// shown before a Project, Folder, or Document is deleted (Req 4.1, 9.1, 13.1).
///
/// The prompt names the target so the user knows exactly what they are about to
/// remove. For a **Project** it additionally states that the Project's Folders
/// and Documents will also be removed (Req 4.1); for a **Folder** it states
/// that the Documents contained in the Folder will also be removed (Req 9.1);
/// for a **Document** it names the Document Title alone (Req 13.1), reusing the
/// same [displayTitle] transformation the sidebar uses so an untitled or
/// over-long title reads identically here.
///
/// Confirming resolves the dialog to `true`; cancelling (or dismissing)
/// resolves it to `false` so the caller closes the prompt without removing
/// anything.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'document_list_item.dart';

/// The kind of entity a [DeleteConfirmationDialog] is confirming deletion of.
///
/// The kind determines the dialog title and whether the body warns that
/// contained items will also be removed (Req 4.1, 9.1, 13.1).
enum DeleteTargetKind {
  /// A Project. Deleting it also removes its Folders and Documents (Req 4.1).
  project,

  /// A Folder. Deleting it also removes the Documents it contains (Req 9.1).
  folder,

  /// A Document. Only the Document itself is removed (Req 13.1).
  document,

  /// A Character. Only the Character itself is removed.
  character,
}

/// A modal confirm / cancel dialog for deleting a Project, Folder, or Document
/// (Req 4.1, 9.1, 13.1).
///
/// Rendered as an [AlertDialog] so it inherits the dark [DialogTheme] from
/// `AppTheme.dark`. Use the [show] helper (or the [showForProject],
/// [showForFolder], [showForDocument] shortcuts) rather than constructing this
/// widget directly.
class DeleteConfirmationDialog extends StatelessWidget {
  /// The kind of entity proposed for deletion (Req 4.1, 9.1, 13.1).
  final DeleteTargetKind kind;

  /// The Name (Project / Folder) or Title (Document) of the entity proposed
  /// for deletion, shown in the prompt so the user can confirm which entity is
  /// affected. For a [DeleteTargetKind.document] this is passed through
  /// [displayTitle]; for a Project or Folder the Name is shown as stored.
  final String name;

  const DeleteConfirmationDialog({
    super.key,
    required this.kind,
    required this.name,
  });

  /// Shows the delete confirmation dialog for the entity of [kind] named
  /// [name] and resolves to the user's decision (Req 4.1, 9.1, 13.1).
  ///
  /// Returns `true` when the user confirms the deletion. Returns `false` when
  /// the user cancels or dismisses the dialog (e.g. by tapping the barrier or
  /// pressing back), so the caller closes the prompt without removing anything.
  static Future<bool> show(
    BuildContext context, {
    required DeleteTargetKind kind,
    required String name,
  }) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) =>
          DeleteConfirmationDialog(kind: kind, name: name),
    );
    // A dismissed dialog yields null; treat it as a cancel.
    return confirmed ?? false;
  }

  /// Confirms deletion of the Project named [projectName], warning that its
  /// Folders and Documents will also be removed (Req 4.1).
  static Future<bool> showForProject(
    BuildContext context, {
    required String projectName,
  }) =>
      show(context, kind: DeleteTargetKind.project, name: projectName);

  /// Confirms deletion of the Folder named [folderName], warning that the
  /// Documents it contains will also be removed (Req 9.1).
  static Future<bool> showForFolder(
    BuildContext context, {
    required String folderName,
  }) =>
      show(context, kind: DeleteTargetKind.folder, name: folderName);

  /// Confirms deletion of the Document titled [documentTitle] (Req 13.1). The
  /// Title is passed through [displayTitle] so an untitled / over-long title
  /// reads the same here as it does in the sidebar.
  static Future<bool> showForDocument(
    BuildContext context, {
    required String documentTitle,
  }) =>
      show(context, kind: DeleteTargetKind.document, name: documentTitle);

  /// Confirms deletion of the Character named [characterName].
  static Future<bool> showForCharacter(
    BuildContext context, {
    required String characterName,
  }) =>
      show(context, kind: DeleteTargetKind.character, name: characterName);

  /// The dialog title for each target kind.
  String get _dialogTitle {
    switch (kind) {
      case DeleteTargetKind.project:
        return 'Delete project?';
      case DeleteTargetKind.folder:
        return 'Delete folder?';
      case DeleteTargetKind.document:
        return 'Delete document?';
      case DeleteTargetKind.character:
        return 'Delete character?';
    }
  }

  /// The body message for each target kind.
  ///
  /// Projects and Folders warn that their contained items will also be removed
  /// (Req 4.1, 9.1); Documents name the display title alone (Req 13.1). Every
  /// message ends by noting the action cannot be undone.
  String _body(String shownName) {
    switch (kind) {
      case DeleteTargetKind.project:
        // Req 4.1: the Project's Folders and Documents will also be removed.
        return 'This will permanently delete "$shownName" and all of its '
            'folders and documents. This action cannot be undone.';
      case DeleteTargetKind.folder:
        // Req 9.1: the Documents contained in the Folder will also be removed.
        return 'This will permanently delete "$shownName" and all of the '
            'documents it contains. This action cannot be undone.';
      case DeleteTargetKind.document:
        // Req 13.1: name the Document alone.
        return 'This will permanently delete "$shownName". This action cannot '
            'be undone.';
      case DeleteTargetKind.character:
        return 'This will permanently delete "$shownName". This action cannot '
            'be undone.';
    }
  }

  @override
  Widget build(BuildContext context) {
    // For a Document, present the same display title the sidebar shows
    // (placeholder for empty, truncation for over-long) so the prompt is
    // unambiguous (Req 13.1). Project / Folder Names are shown as stored.
    final String shownName =
        kind == DeleteTargetKind.document ? displayTitle(name) : name;

    return AlertDialog(
      title: Text(_dialogTitle),
      content: Text(
        _body(shownName),
        style: const TextStyle(color: AppPalette.textPrimary),
      ),
      actions: <Widget>[
        // Cancel: close without deleting.
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        // Confirm: destructive-styled action drawn from the palette.
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppPalette.error),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}
