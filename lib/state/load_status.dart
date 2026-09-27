/// State layer: the shared [LoadStatus] enum describing the lifecycle of an
/// asynchronous list load (the Dashboard's project list, or a project's
/// contents).
///
/// Extracted into its own small file so multiple `ChangeNotifier`s
/// ([AppNavigationState], `ProjectWorkspaceState`) can share the same status
/// vocabulary without depending on one another.
library;

/// Lifecycle of an asynchronous list load (Req 1.1, 1.5, 17.8).
enum LoadStatus {
  /// No load has been attempted yet.
  idle,

  /// A load is in flight.
  loading,

  /// The list loaded successfully and reflects the store.
  loaded,

  /// The most recent load failed. On a startup failure an empty set is exposed
  /// alongside this status (Req 17.8); on a later reload failure the previously
  /// displayed list is retained (Req 1.5).
  error,
}
