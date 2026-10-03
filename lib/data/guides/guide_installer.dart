/// Data layer: [GuideInstaller] keeps the built-in guide projects present and
/// up to date in the writer's database, and
/// [SettingsGuideVisibilityPreference] stores the dashboard's show/hide switch.
///
/// Both depend only on domain repository abstractions (dependency inversion),
/// so they work over SQLite in the app and over in-memory fakes in tests.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/app_settings_repository.dart';
import '../../domain/document.dart';
import '../../domain/document_repository.dart';
import '../../domain/folder.dart';
import '../../domain/folder_repository.dart';
import '../../domain/guides/built_in_guide.dart';
import '../../domain/project.dart';
import '../../domain/project_repository.dart';

/// Installs each [BuiltInGuide] as a project, and rewrites it whenever the
/// shipped content changes.
///
/// A fingerprint (SHA-256 of [BuiltInGuide.canonicalContent]) is stored per
/// guide in app settings. On startup a guide is (re)written only when its
/// project is missing or its fingerprint differs, so normal launches do no
/// writes. Guides are read-only in the app, so rewriting never loses work.
class GuideInstaller {
  GuideInstaller({
    required ProjectRepository projects,
    required FolderRepository folders,
    required DocumentRepository documents,
    required AppSettingsRepository settings,
    DateTime Function()? clock,
  })  : _projects = projects,
        _folders = folders,
        _documents = documents,
        _settings = settings,
        _clock = clock ?? DateTime.now;

  final ProjectRepository _projects;
  final FolderRepository _folders;
  final DocumentRepository _documents;
  final AppSettingsRepository _settings;
  final DateTime Function() _clock;

  /// Settings key holding a guide's installed-content fingerprint.
  static String fingerprintKey(String projectId) =>
      'builtin_guide.$projectId.fingerprint';

  /// SHA-256 of the guide's canonical content.
  static String fingerprintOf(BuiltInGuide guide) =>
      sha256.convert(utf8.encode(guide.canonicalContent)).toString();

  /// Ensures every guide in [catalog] is installed and current. A failure on
  /// one guide does not stop the others; errors are reported through
  /// [onError] so startup never fails because of a guide.
  Future<void> installAll(
    BuiltInGuideCatalog catalog, {
    void Function(BuiltInGuide guide, Object error)? onError,
  }) async {
    for (final BuiltInGuide guide in catalog.guides) {
      try {
        await install(guide);
      } catch (error) {
        onError?.call(guide, error);
      }
    }
  }

  /// Installs or refreshes one [guide]. Returns `true` when anything was
  /// written.
  Future<bool> install(BuiltInGuide guide) async {
    final String fingerprint = fingerprintOf(guide);
    final Project? existing = await _projects.getById(guide.projectId);
    final String? stored =
        await _settings.getString(fingerprintKey(guide.projectId));
    if (existing != null && stored == fingerprint) return false;

    final DateTime now = _clock().toUtc();
    if (existing == null) {
      await _projects.create(
        Project.create(id: guide.projectId, name: guide.name, now: now),
      );
    } else {
      await _clearContents(guide.projectId);
      if (existing.name != guide.name) {
        await _projects.update(existing.copyWith(name: guide.name));
      }
    }
    await _writeContents(guide, now);
    // Written last, so an interrupted install is retried on the next launch.
    await _settings.setString(fingerprintKey(guide.projectId), fingerprint);
    return true;
  }

  /// Removes the guide's folders (with their documents) and root documents.
  Future<void> _clearContents(String projectId) async {
    for (final Folder folder in await _folders.getByProject(projectId)) {
      await _folders.deleteCascade(folder.id);
    }
    for (final Document doc in await _documents.getByProject(projectId)) {
      await _documents.delete(doc.id);
    }
  }

  /// Writes root documents first, then each folder with its documents, using
  /// ids derived from the guide so they are stable across reinstalls.
  Future<void> _writeContents(BuiltInGuide guide, DateTime now) async {
    final String pid = guide.projectId;
    int rootPosition = 0;

    Future<void> writeDoc(GuideDocument d, String id, String? folderId,
        int position) async {
      await _documents.create(
        Document.newDocument(
          id: id,
          projectId: pid,
          folderId: folderId,
          now: now,
          position: position,
        ).copyWith(title: d.title, content: d.markdown),
      );
    }

    for (int i = 0; i < guide.rootDocuments.length; i++) {
      await writeDoc(guide.rootDocuments[i], '$pid.doc.$i', null,
          rootPosition++);
    }
    for (int f = 0; f < guide.folders.length; f++) {
      final GuideFolder folder = guide.folders[f];
      final String folderId = '$pid.folder.$f';
      await _folders.create(
        Folder.create(
          id: folderId,
          projectId: pid,
          name: folder.name,
          now: now,
          position: rootPosition++,
        ),
      );
      for (int d = 0; d < folder.documents.length; d++) {
        await writeDoc(folder.documents[d], '$folderId.doc.$d', folderId, d);
      }
    }
  }
}

/// [GuideVisibilityPreference] stored in the app's key/value settings.
class SettingsGuideVisibilityPreference implements GuideVisibilityPreference {
  SettingsGuideVisibilityPreference(this._settings);

  final AppSettingsRepository _settings;

  static const String key = 'dashboard.show_builtin_guides';

  @override
  Future<bool> load() async => (await _settings.getString(key)) != 'false';

  @override
  Future<void> save(bool visible) =>
      _settings.setString(key, visible ? 'true' : 'false');
}
