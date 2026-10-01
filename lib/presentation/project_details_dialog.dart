/// Presentation layer: [ProjectDetailsDialog], the create / edit project
/// dialog — the project Name plus an optional cover photo.
///
/// The cover picker opens a native file dialog (`file_selector`, which works on
/// macOS, Windows, Linux, and web), then normalizes the chosen picture to
/// exactly 1600 × 2560 px via [normalizeCoverImage] (center-cropping when the
/// aspect ratio differs, off the UI isolate). The dialog previews the result,
/// tells the user when it was cropped, and shows a friendly inline error for a
/// file that is not a readable PNG / JPG / WebP image. The cover is optional
/// and can be replaced or removed.
///
/// Name validation mirrors the authoritative rules in `AppNavigationState`
/// (trimmed, 1..255 characters) with the same wording, so the user sees
/// consistent messages wherever a value is caught. The dialog only collects
/// input; the caller forwards the [ProjectDetailsResult] to the state layer.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/cover_image_normalizer.dart';
import '../domain/project.dart';
import '../theme/app_theme.dart';
import 'project_cover.dart';

/// Picks an image file and returns its raw bytes, or `null` when cancelled.
typedef CoverBytesPicker = Future<Uint8List?> Function();

/// Normalizes raw image bytes into a cover photo (throws
/// [CoverImageException] on unreadable input).
typedef CoverNormalizer = Future<NormalizedCover> Function(Uint8List bytes);

/// What the user confirmed in the [ProjectDetailsDialog].
@immutable
class ProjectDetailsResult {
  /// The trimmed, locally valid project name.
  final String name;

  /// The normalized cover bytes, or `null` for no cover.
  final Uint8List? coverImage;

  /// Whether the user changed the cover (picked a new one or removed it).
  /// Always `true` for a create that has a cover.
  final bool coverChanged;

  const ProjectDetailsResult({
    required this.name,
    required this.coverImage,
    required this.coverChanged,
  });
}

/// The file types the cover picker offers. Extensions drive the native
/// dialogs on macOS / Windows / Linux; MIME types drive the browser picker.
const XTypeGroup kCoverImageTypeGroup = XTypeGroup(
  label: 'Images',
  extensions: CoverImageSpec.extensions,
  mimeTypes: <String>['image/png', 'image/jpeg', 'image/webp'],
);

/// The default [CoverBytesPicker]: the native open-file dialog.
Future<Uint8List?> pickCoverBytesWithFileSelector() async {
  final XFile? file =
      await openFile(acceptedTypeGroups: <XTypeGroup>[kCoverImageTypeGroup]);
  if (file == null) return null; // Cancelled.
  return file.readAsBytes();
}

/// The create / edit project dialog. Use [ProjectDetailsDialog.show].
class ProjectDetailsDialog extends StatefulWidget {
  /// The project being edited, or `null` to create a new one.
  final Project? project;

  /// Picks the source image bytes. Defaults to
  /// [pickCoverBytesWithFileSelector]; injectable for tests.
  final CoverBytesPicker pickCoverBytes;

  /// Normalizes picked bytes. Defaults to [normalizeCoverImage]; injectable
  /// for tests.
  final CoverNormalizer normalizeCover;

  const ProjectDetailsDialog({
    super.key,
    this.project,
    this.pickCoverBytes = pickCoverBytesWithFileSelector,
    this.normalizeCover = normalizeCoverImage,
  });

  /// Shows the dialog and resolves to the confirmed result, or `null` when the
  /// user cancels (Cancel, Escape, or tapping outside).
  static Future<ProjectDetailsResult?> show(
    BuildContext context, {
    Project? project,
    CoverBytesPicker pickCoverBytes = pickCoverBytesWithFileSelector,
    CoverNormalizer normalizeCover = normalizeCoverImage,
  }) {
    return showDialog<ProjectDetailsResult>(
      context: context,
      builder: (BuildContext context) => ProjectDetailsDialog(
        project: project,
        pickCoverBytes: pickCoverBytes,
        normalizeCover: normalizeCover,
      ),
    );
  }

  @override
  State<ProjectDetailsDialog> createState() => _ProjectDetailsDialogState();
}

class _ProjectDetailsDialogState extends State<ProjectDetailsDialog> {
  /// Mirrors the authoritative 255-character limit.
  static const int _maxLength = 255;

  /// The preview width; height follows the 1:1.6 cover ratio.
  static const double _previewWidth = 150;

  late final TextEditingController _nameController;

  /// The working cover bytes (normalized), or `null` for none.
  Uint8List? _cover;

  /// Whether the user picked or removed a cover in this dialog session.
  bool _coverChanged = false;

  /// Whether a pick / normalize is in flight.
  bool _processing = false;

  /// An inline name validation message, or `null`.
  String? _nameError;

  /// An inline cover error (unreadable / unsupported file), or `null`.
  String? _coverError;

  /// An informational note about the last processed cover (e.g. cropped).
  String? _coverNote;

  bool get _isEdit => widget.project != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.project?.name ?? '');
    _nameController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _nameController.text.length,
    );
    _cover = widget.project?.coverImage;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String? _validateName(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) return 'A name is required.';
    if (trimmed.length > _maxLength) {
      return 'Name exceeds the $_maxLength character maximum.';
    }
    return null;
  }

  /// Picks an image, normalizes it to 1600 × 2560, and updates the preview, or
  /// shows a friendly inline error when the file cannot be used.
  Future<void> _pickCover() async {
    if (_processing) return;
    setState(() {
      _coverError = null;
    });
    try {
      final Uint8List? bytes = await widget.pickCoverBytes();
      if (bytes == null || !mounted) return; // Cancelled.
      setState(() => _processing = true);
      final NormalizedCover normalized = await widget.normalizeCover(bytes);
      if (!mounted) return;
      final bool resized = normalized.sourceWidth != CoverImageSpec.width ||
          normalized.sourceHeight != CoverImageSpec.height;
      setState(() {
        _cover = normalized.bytes;
        _coverChanged = true;
        _coverNote = normalized.wasCropped
            ? 'Cropped to 1.6:1 (center) and resized to '
                '${CoverImageSpec.width} × ${CoverImageSpec.height} px.'
            : (resized
                ? 'Resized to ${CoverImageSpec.width} × '
                    '${CoverImageSpec.height} px.'
                : null);
      });
    } on CoverImageException catch (error) {
      if (!mounted) return;
      setState(() => _coverError = error.message);
    } catch (error, stackTrace) {
      debugPrint('Cover image pick failed: $error\n$stackTrace');
      if (!mounted) return;
      setState(() => _coverError = 'That image couldn\'t be loaded.');
    } finally {
      if (mounted && _processing) setState(() => _processing = false);
    }
  }

  void _removeCover() {
    setState(() {
      _cover = null;
      _coverChanged = true;
      _coverNote = null;
      _coverError = null;
    });
  }

  void _submit() {
    if (_processing) return;
    final String? error = _validateName(_nameController.text);
    if (error != null) {
      setState(() => _nameError = error);
      return;
    }
    Navigator.of(context).pop(
      ProjectDetailsResult(
        name: _nameController.text.trim(),
        coverImage: _cover,
        coverChanged: _coverChanged || (!_isEdit && _cover != null),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Semantics(
                header: true,
                child: Text(
                  _isEdit ? 'Edit project' : 'New project',
                  style: text.headlineSmall,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                _isEdit
                    ? 'Rename your project or change its cover.'
                    : 'Give your book a name and, if you like, a cover.',
                style: text.bodyMedium?.copyWith(
                  color: AppPalette.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final bool stacked = constraints.maxWidth < 440;
                  final Widget preview = _buildCoverColumn(text);
                  final Widget fields = _buildFields(text);
                  if (stacked) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        fields,
                        const SizedBox(height: AppSpacing.xl),
                        Center(child: preview),
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      preview,
                      const SizedBox(width: AppSpacing.xl),
                      Expanded(child: fields),
                    ],
                  );
                },
              ),
              const SizedBox(height: AppSpacing.xl),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    onPressed: _processing ? null : _submit,
                    child: Text(_isEdit ? 'Save' : 'Create project'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The name field plus the cover guidance, note, and error.
  Widget _buildFields(TextTheme text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TextField(
          controller: _nameController,
          autofocus: true,
          maxLines: 1,
          textInputAction: TextInputAction.done,
          style: const TextStyle(color: AppPalette.textPrimary),
          decoration: InputDecoration(
            labelText: 'Name',
            hintText: 'e.g. The Lighthouse Keeper',
            errorText: _nameError,
          ),
          onChanged: (_) => setState(() {
            // Live-update the fallback initial and clear a stale error.
            _nameError = null;
          }),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text('Cover photo', style: text.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        Text(
          CoverImageSpec.recommendation,
          style: text.bodySmall,
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          'PNG, JPG or WebP. Optional — other shapes are center-cropped.',
          style: text.bodySmall,
        ),
        if (_coverNote != null) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.crop, size: 16, color: AppPalette.secondary),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  _coverNote!,
                  style: text.bodySmall?.copyWith(color: AppPalette.secondary),
                ),
              ),
            ],
          ),
        ],
        if (_coverError != null) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.error_outline,
                    size: 16, color: AppPalette.error),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    _coverError!,
                    style: text.bodySmall?.copyWith(color: AppPalette.error),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// The 1:1.6 cover preview with its upload / replace / remove controls.
  Widget _buildCoverColumn(TextTheme text) {
    final bool hasCover = _cover != null;
    return SizedBox(
      width: _previewWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Tooltip(
            message: hasCover ? 'Replace cover photo' : 'Upload cover photo',
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: const ValueKey<String>('cover-preview'),
                onTap: _processing ? null : _pickCover,
                borderRadius: AppStyle.controlRadius,
                child: Ink(
                  width: _previewWidth,
                  height: _previewWidth / AppStyle.coverAspectRatio,
                  decoration: BoxDecoration(
                    borderRadius: AppStyle.controlRadius,
                    border: Border.all(color: AppPalette.hairline),
                    boxShadow: AppStyle.cardShadow,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      ProjectCover(
                        coverImage: _cover,
                        projectName: _nameController.text,
                        initialFontSize: 52,
                      ),
                      if (_processing)
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppPalette.coverScrim,
                            borderRadius: AppStyle.controlRadius,
                          ),
                          child: Center(
                            child: CircularProgressIndicator(
                              semanticsLabel: 'Processing cover photo',
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _processing ? null : _pickCover,
              icon: Icon(
                hasCover
                    ? Icons.photo_library_outlined
                    : Icons.add_photo_alternate_outlined,
                size: 18,
              ),
              label: Text(hasCover ? 'Replace' : 'Upload cover'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.md,
                ),
              ),
            ),
          ),
          if (hasCover) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            TextButton.icon(
              onPressed: _processing ? null : _removeCover,
              style: TextButton.styleFrom(foregroundColor: AppPalette.error),
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Remove cover'),
            ),
          ],
        ],
      ),
    );
  }
}
