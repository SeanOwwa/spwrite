/// Native (mobile + desktop) database-path resolution. This library imports
/// `dart:io` and is selected on every non-web platform via the conditional
/// import in `database_provider.dart`.
library;

import 'dart:io' show Directory, Platform;

import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show getDatabasesPath;

/// Whether the current platform is a desktop platform (macOS, Windows, Linux)
/// that must use the FFI-based SQLite factory.
bool get isDesktop =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Resolves the on-disk path for the database [fileName].
///
/// On desktop, uses `path_provider`'s application-support directory. On mobile,
/// uses sqflite's [getDatabasesPath]. Both are per-platform writable locations.
Future<String> resolveDbPath(String fileName) async {
  if (isDesktop) {
    final Directory dir = await getApplicationSupportDirectory();
    return _joinPath(dir.path, fileName);
  }
  final String databasesPath = await getDatabasesPath();
  return _joinPath(databasesPath, fileName);
}

/// Joins a directory and a file name with the platform path separator, avoiding
/// a duplicate separator when [dir] already ends with one.
String _joinPath(String dir, String fileName) {
  final String sep = Platform.pathSeparator;
  if (dir.isEmpty) return fileName;
  return dir.endsWith(sep) ? '$dir$fileName' : '$dir$sep$fileName';
}
