/// Native (desktop) export helpers: file-system defaults for
/// [ExportLocationService] and "Show in folder". Selected on non-web builds via
/// the conditional import in `export_dialog.dart`.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/app_settings_repository.dart';
import 'export_location_service.dart';

/// Whether the native Save As export flow (and "Show in folder") is available.
bool get supportsExportLocation =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Builds the production [ExportLocationService] over [settings], using the
/// native `file_selector` dialogs and `dart:io` for the file system.
ExportLocationService createExportLocationService(
  AppSettingsRepository settings,
) {
  return ExportLocationService(
    settings: settings,
    directoryExists: directoryExists,
    writeBytes: writeBytesToFile,
    fallbackDirectory: fallbackExportDirectory,
  );
}

/// Whether a folder exists at [path].
Future<bool> directoryExists(String path) => Directory(path).exists();

/// Writes [bytes] to [path], flushing to disk.
Future<void> writeBytesToFile(String path, List<int> bytes) async {
  await File(path).writeAsBytes(bytes, flush: true);
}

/// The fallback export folder: the user's Downloads folder, then the
/// documents directory as a last resort.
Future<String?> fallbackExportDirectory() async {
  try {
    final Directory? downloads = await getDownloadsDirectory();
    if (downloads != null && await downloads.exists()) return downloads.path;
  } catch (_) {
    // Not available on this platform; fall through.
  }
  try {
    return (await getApplicationDocumentsDirectory()).path;
  } catch (_) {
    return null;
  }
}

/// The OS command (executable + argument list) that reveals [filePath] in the
/// platform file manager, or `null` on unsupported platforms. Arguments are
/// passed as a list — never through a shell — so paths are not interpreted.
({String executable, List<String> arguments})? revealCommand(
  String filePath, {
  String? operatingSystem,
}) {
  final String os = operatingSystem ?? Platform.operatingSystem;
  switch (os) {
    case 'macos':
      return (executable: 'open', arguments: <String>['-R', filePath]);
    case 'windows':
      return (executable: 'explorer', arguments: <String>['/select,$filePath']);
    case 'linux':
      final int index = filePath.lastIndexOf('/');
      final String dir = index > 0 ? filePath.substring(0, index) : '/';
      return (executable: 'xdg-open', arguments: <String>[dir]);
    default:
      return null;
  }
}

/// Reveals [filePath] in the platform file manager (Finder / Explorer / the
/// default Linux file manager). Failures are swallowed: this is a convenience.
Future<void> revealInFolder(String filePath) async {
  final command = revealCommand(filePath);
  if (command == null) return;
  try {
    // Explorer returns a non-zero exit code even on success, so the result is
    // intentionally ignored.
    await Process.run(command.executable, command.arguments);
  } catch (_) {
    // The file manager could not be launched; nothing else to do.
  }
}
