/// Domain layer: the [AppSettingsRepository] abstraction over a tiny, local
/// key/value store for app-wide preferences (e.g. the last folder an export was
/// saved to).
///
/// The presentation/state layers depend only on this interface; the data
/// layer's `SqliteAppSettingsRepository` implements it over the app database's
/// `app_settings` table (schema v8).
library;

/// Reads and writes app-wide string preferences by key.
///
/// Implementations must use parameterized SQL only (keys and values are bound,
/// never interpolated). Failures are surfaced by throwing.
abstract class AppSettingsRepository {
  /// Returns the value stored under [key], or `null` when none is stored.
  Future<String?> getString(String key);

  /// Stores [value] under [key], replacing any previous value.
  Future<void> setString(String key, String value);

  /// Removes the value stored under [key] (a no-op when absent).
  Future<void> remove(String key);
}
