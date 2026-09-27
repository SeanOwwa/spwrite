/// Web database-"path" resolution. On the web there is no filesystem: the
/// database name is a key the IndexedDB-backed factory stores under. This
/// library is selected on web via the conditional import in
/// `database_provider.dart` and imports nothing from `dart:io`.
library;

/// The web build never uses the desktop FFI factory.
bool get isDesktop => false;

/// Returns [fileName] unchanged: on web it is the storage key, not a path.
Future<String> resolveDbPath(String fileName) async => fileName;
