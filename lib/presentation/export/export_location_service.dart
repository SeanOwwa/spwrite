/// Chooses where a desktop `.docx` export is saved and remembers the folder.
///
/// Flow (desktop only; web keeps its browser download):
/// - The native "Save As" dialog is ALWAYS shown, pre-selecting the remembered
///   folder (or a fallback) via `initialDirectory`. On sandboxed macOS a folder
///   remembered from a previous launch is not writable without a
///   security-scoped bookmark, so the app never writes to it silently; the
///   user's pick in the dialog grants the access.
/// - Cancelling the dialog aborts the export (returns `null`, nothing written).
/// - A `.docx` extension is appended when the user removed it.
/// - The chosen file's folder is persisted via [AppSettingsRepository] so the
///   next export (and next launch) starts there.
///
/// This file has no `dart:io` dependency: the native dialogs, the file-system
/// checks, and the writer are injected so tests never open a real dialog. The
/// production defaults for the dialogs live here ([fileSelectorSavePicker],
/// [fileSelectorDirectoryPicker]); the file-system defaults come from
/// `export_platform_io.dart`.
library;

import 'package:file_selector/file_selector.dart' as fs;

import '../../domain/app_settings_repository.dart';

/// Shows a "Save As" dialog and returns the chosen file path, or `null` when
/// the user cancelled.
typedef SaveLocationPicker = Future<String?> Function({
  required String suggestedName,
  String? initialDirectory,
});

/// Shows a folder picker and returns the chosen folder path, or `null` when
/// the user cancelled.
typedef DirectoryPicker = Future<String?> Function({String? initialDirectory});

/// Whether a folder exists at the given path.
typedef DirectoryExists = Future<bool> Function(String path);

/// Writes bytes to the file at the given path.
typedef BytesWriter = Future<void> Function(String path, List<int> bytes);

/// Resolves the fallback folder used when nothing (valid) is remembered.
typedef FallbackDirectoryResolver = Future<String?> Function();

/// The file-type filter offered by the Save As dialog.
const fs.XTypeGroup docxTypeGroup = fs.XTypeGroup(
  label: 'Word document',
  extensions: <String>['docx'],
  uniformTypeIdentifiers: <String>[
    'org.openxmlformats.wordprocessingml.document'
  ],
);

/// Production [SaveLocationPicker] backed by `file_selector`'s
/// `getSaveLocation`.
Future<String?> fileSelectorSavePicker({
  required String suggestedName,
  String? initialDirectory,
}) async {
  final fs.FileSaveLocation? location = await fs.getSaveLocation(
    suggestedName: suggestedName,
    initialDirectory: initialDirectory,
    acceptedTypeGroups: const <fs.XTypeGroup>[docxTypeGroup],
    confirmButtonText: 'Save',
  );
  return location?.path;
}

/// Production [DirectoryPicker] backed by `file_selector`'s `getDirectoryPath`.
Future<String?> fileSelectorDirectoryPicker({String? initialDirectory}) {
  return fs.getDirectoryPath(
    initialDirectory: initialDirectory,
    confirmButtonText: 'Choose',
  );
}

/// Picks, writes, and remembers the destination of desktop exports.
class ExportLocationService {
  ExportLocationService({
    required AppSettingsRepository settings,
    required DirectoryExists directoryExists,
    required BytesWriter writeBytes,
    required FallbackDirectoryResolver fallbackDirectory,
    SaveLocationPicker? pickSaveLocation,
    DirectoryPicker? pickDirectory,
  })  : _settings = settings,
        _directoryExists = directoryExists,
        _writeBytes = writeBytes,
        _fallbackDirectory = fallbackDirectory,
        _pickSaveLocation = pickSaveLocation ?? fileSelectorSavePicker,
        _pickDirectory = pickDirectory ?? fileSelectorDirectoryPicker;

  /// The settings key under which the last export folder is stored.
  static const String lastFolderKey = 'export.last_folder';

  final AppSettingsRepository _settings;
  final DirectoryExists _directoryExists;
  final BytesWriter _writeBytes;
  final FallbackDirectoryResolver _fallbackDirectory;
  final SaveLocationPicker _pickSaveLocation;
  final DirectoryPicker _pickDirectory;

  /// The folder exports start in: the remembered folder when it still exists,
  /// otherwise the platform fallback (Downloads, then Documents). Returns
  /// `null` only when nothing can be resolved.
  Future<String?> resolveDefaultFolder() async {
    String? remembered;
    try {
      remembered = await _settings.getString(lastFolderKey);
    } catch (_) {
      // Preferences are best-effort; an unreadable store never blocks export.
      remembered = null;
    }
    if (remembered != null && remembered.isNotEmpty) {
      try {
        if (await _directoryExists(remembered)) return remembered;
      } catch (_) {
        // Treat an unreadable path like a missing one.
      }
    }
    try {
      return await _fallbackDirectory();
    } catch (_) {
      return null;
    }
  }

  /// Lets the user pick the default export folder up front. Persists and
  /// returns the chosen folder, or returns `null` when cancelled (nothing
  /// stored).
  Future<String?> chooseDefaultFolder() async {
    final String? chosen = await _pickDirectory(
      initialDirectory: await resolveDefaultFolder(),
    );
    if (chosen == null || chosen.isEmpty) return null;
    await _remember(chosen);
    return chosen;
  }

  /// Shows the Save As dialog for [suggestedFileName] and writes [bytes] to
  /// the chosen path (with `.docx` appended when missing). Returns the written
  /// path, or `null` when the user cancelled (nothing is written).
  Future<String?> saveDocx(List<int> bytes, String suggestedFileName) async {
    final String? picked = await _pickSaveLocation(
      suggestedName: suggestedFileName,
      initialDirectory: await resolveDefaultFolder(),
    );
    if (picked == null || picked.trim().isEmpty) return null;
    final String path = ensureDocxExtension(picked);
    await _writeBytes(path, bytes);
    final String? folder = parentDirectory(path);
    if (folder != null) await _remember(folder);
    return path;
  }

  Future<void> _remember(String folder) async {
    try {
      await _settings.setString(lastFolderKey, folder);
    } catch (_) {
      // Best-effort: failing to remember the folder must not fail the export.
    }
  }

  /// Returns [path] with a `.docx` extension, appending it (case-insensitive
  /// check) when absent.
  static String ensureDocxExtension(String path) {
    return path.toLowerCase().endsWith('.docx') ? path : '$path.docx';
  }

  /// The folder containing [path] (handles `/` and `\` separators), or `null`
  /// when [path] has no folder component.
  static String? parentDirectory(String path) {
    final int index = path.lastIndexOf(RegExp(r'[/\\]'));
    if (index < 0) return null;
    if (index == 0) return path.substring(0, 1); // POSIX root.
    final String parent = path.substring(0, index);
    // Keep a Windows drive root as "C:\" rather than "C:".
    if (RegExp(r'^[A-Za-z]:$').hasMatch(parent)) return '$parent\\';
    return parent;
  }
}
