/// App-wide static metadata surfaced in the UI.
///
/// [AppInfo.version] is the human-readable release string shown to testers
/// (e.g. on an About surface). It mirrors the `version:` in `pubspec.yaml`;
/// keep the two in sync when bumping the release.
library;

/// Static application metadata (version, channel).
class AppInfo {
  const AppInfo._();

  /// The release channel label (e.g. `beta`), shown alongside [versionNumber].
  static const String channel = 'Beta';

  /// The semantic version number, matching `pubspec.yaml`'s `version:`.
  static const String versionNumber = '1.3.5';

  /// The full, display-ready version label, e.g. `Beta 1.3.5`.
  static const String version = '$channel $versionNumber';

  /// Whether the AI assistant is available in this build.
  ///
  /// `false` on `main`: the assistant is still being stabilised on the
  /// `ai_feature` branch. While off, the AI panel shows "Coming soon", no
  /// model can be downloaded, and no background indexing runs.
  static const bool aiAssistantAvailable = false;
}
