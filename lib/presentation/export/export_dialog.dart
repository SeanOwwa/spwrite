/// The export dialog: lets the user pick an output format (PDF or DOCX) and
/// The export dialog: lets the user pick which documents of the open project to
/// include, then builds and delivers a Word (.docx) file via [DocumentExporter].
///
/// Each selected document's title becomes a heading and its content the body,
/// with a page break between documents (handled by the exporter). The dialog
/// reads the project's documents from [ProjectWorkspaceState] and flattens each
/// one's stored Markdown to paragraphs via
/// [ProjectWorkspaceState.contentParagraphs].
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../domain/document.dart';
import '../../state/project_workspace_state.dart';
import '../../theme/app_theme.dart';
import 'document_exporter.dart';
import 'exportable_document.dart';

/// Opens the export dialog for the open project. Returns when the dialog is
/// dismissed.
///
/// The [ProjectWorkspaceState] is read from [context] here — where the provider
/// is in scope — and handed to the dialog explicitly. `showDialog` builds its
/// content under the root navigator, which sits *above* the workspace provider
/// scope, so the dialog itself cannot look the state up; passing it in avoids a
/// `ProviderNotFoundException`.
Future<void> showExportDialog(BuildContext context) {
  final ProjectWorkspaceState state = context.read<ProjectWorkspaceState>();
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => ExportDialog(state: state),
  );
}

class ExportDialog extends StatefulWidget {
  /// The open project's workspace state, passed in from the caller's context
  /// because the dialog is mounted above the provider scope.
  final ProjectWorkspaceState state;

  const ExportDialog({super.key, required this.state});

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  final Set<String> _selectedIds = <String>{};
  bool _exporting = false;

  static const DocumentExporter _exporter = DocumentExporter();

  @override
  Widget build(BuildContext context) {
    final ProjectWorkspaceState state = widget.state;
    final List<Document> documents = state.allDocuments();

    return AlertDialog(
      backgroundColor: AppPalette.surface,
      title: const Text(
        'Export documents',
        style: TextStyle(color: AppPalette.textPrimary),
      ),
      content: SizedBox(
        width: 420,
        child: documents.isEmpty
            ? _buildEmpty()
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Row(
                    children: <Widget>[
                      Icon(
                        Icons.description_outlined,
                        size: 18,
                        color: AppPalette.secondary,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Export as Word document (.docx)',
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Choose documents',
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Flexible(child: _buildDocumentList(state, documents)),
                ],
              ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _exporting ? null : () => Navigator.of(context).pop(),
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppPalette.textSecondary),
          ),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: AppPalette.primary,
            foregroundColor: AppPalette.background,
          ),
          onPressed: (_exporting || _selectedIds.isEmpty)
              ? null
              : () => _runExport(context, state, documents),
          icon: _exporting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppPalette.background,
                  ),
                )
              : const Icon(Icons.file_download_outlined, size: 18),
          label: Text(_exporting ? 'Exporting…' : 'Export'),
        ),
      ],
    );
  }

  Widget _buildEmpty() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Text(
        'This project has no documents to export yet.',
        style: TextStyle(color: AppPalette.textSecondary),
      ),
    );
  }

  /// A scrollable, checkable list of the project's documents. A "Select all"
  /// row sits at the top for convenience.
  Widget _buildDocumentList(
    ProjectWorkspaceState state,
    List<Document> documents,
  ) {
    final bool allSelected = _selectedIds.length == documents.length;
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppPalette.outline),
      ),
      child: ListView(
        shrinkWrap: true,
        children: <Widget>[
          CheckboxListTile(
            dense: true,
            value: allSelected,
            onChanged: (bool? checked) {
              setState(() {
                if (checked ?? false) {
                  _selectedIds
                    ..clear()
                    ..addAll(documents.map((Document d) => d.id));
                } else {
                  _selectedIds.clear();
                }
              });
            },
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: AppPalette.primary,
            title: const Text(
              'Select all',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          const Divider(height: 1, color: AppPalette.outline),
          ...documents.map((Document doc) {
            final String shownTitle = doc.title.trim().isEmpty
                ? 'Untitled Document'
                : doc.title;
            return CheckboxListTile(
              dense: true,
              value: _selectedIds.contains(doc.id),
              onChanged: (bool? checked) {
                setState(() {
                  if (checked ?? false) {
                    _selectedIds.add(doc.id);
                  } else {
                    _selectedIds.remove(doc.id);
                  }
                });
              },
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: AppPalette.primary,
              title: Text(
                shownTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppPalette.textPrimary),
              ),
            );
          }),
        ],
      ),
    );
  }

  Future<void> _runExport(
    BuildContext context,
    ProjectWorkspaceState state,
    List<Document> documents,
  ) async {
    // Capture the context-derived objects before the async gap so we don't use
    // the BuildContext after awaiting.
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    setState(() => _exporting = true);

    // Preserve the list order for the selected documents so the export matches
    // the sidebar order.
    final List<ExportableDocument> selected = documents
        .where((Document d) => _selectedIds.contains(d.id))
        .map(
          (Document d) => ExportableDocument(
            title: d.title.trim().isEmpty ? 'Untitled Document' : d.title,
            paragraphs: state.contentParagraphs(d.content),
          ),
        )
        .toList(growable: false);

    final String baseName = _sanitizeFileName(state.project.name);

    final ExportResult result = await _exporter.export(
      documents: selected,
      baseFileName: baseName.isEmpty ? 'export' : baseName,
    );

    if (!mounted) return;
    setState(() => _exporting = false);

    navigator.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.success
              ? 'Exported ${selected.length} document(s) to ${result.location}.'
              : (result.errorMessage ?? 'Export failed.'),
        ),
      ),
    );
  }

  /// Strips characters unsafe for a file name, collapsing whitespace to
  /// underscores so the export has a tidy, portable name.
  String _sanitizeFileName(String name) {
    final String cleaned = name
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .replaceAll(RegExp(r'\s+'), '_');
    return cleaned;
  }
}
