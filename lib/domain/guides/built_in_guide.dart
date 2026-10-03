/// Domain layer: built-in guide projects (the User Guide and Developer Guide)
/// that ship inside the app.
///
/// A guide is pure content: a project name plus folders of Markdown
/// documents. It knows nothing about storage, so new guides are added by
/// writing a new [BuiltInGuide] (open for extension) without touching the
/// installer, the dashboard, or the editor (closed for modification).
library;

/// One document of a guide: a title and its Markdown body.
///
/// The body may use only the formatting the editor stores: headings, bold,
/// italic, bulleted and numbered lists, and links.
class GuideDocument {
  final String title;
  final String markdown;

  const GuideDocument({required this.title, required this.markdown});
}

/// A folder of guide documents, shown in the sidebar in list order.
class GuideFolder {
  final String name;
  final List<GuideDocument> documents;

  const GuideFolder({required this.name, required this.documents});
}

/// A project that ships with the app and is kept in sync with its content.
abstract class BuiltInGuide {
  const BuiltInGuide();

  /// A stable, never-changing project id (not a UUID, so it can never collide
  /// with a writer's project).
  String get projectId;

  /// The project name shown on the dashboard.
  String get name;

  /// Documents shown at the top of the sidebar, before any folder.
  List<GuideDocument> get rootDocuments => const <GuideDocument>[];

  /// Folders shown after [rootDocuments], each with its documents.
  List<GuideFolder> get folders => const <GuideFolder>[];

  /// A deterministic text form of the whole guide. The installer hashes it to
  /// notice when a new app version ships changed content.
  String get canonicalContent {
    final StringBuffer out = StringBuffer()
      ..writeln(projectId)
      ..writeln(name);
    void writeDoc(GuideDocument d) => out
      ..writeln('# ${d.title}')
      ..writeln(d.markdown);
    rootDocuments.forEach(writeDoc);
    for (final GuideFolder f in folders) {
      out.writeln('## ${f.name}');
      f.documents.forEach(writeDoc);
    }
    return out.toString();
  }
}

/// Answers "is this project built in?" for code that must protect guides
/// (no delete, no rename, no edits) without knowing which guides exist.
abstract class BuiltInProjectPolicy {
  /// Whether [projectId] is a built-in guide.
  bool isBuiltIn(String projectId);

  /// The dashboard position of a built-in project (0 = first), or `-1` for a
  /// writer's own project.
  int orderOf(String projectId);
}

/// The guides that ship with the app, in dashboard order.
class BuiltInGuideCatalog implements BuiltInProjectPolicy {
  final List<BuiltInGuide> guides;

  const BuiltInGuideCatalog(this.guides);

  @override
  bool isBuiltIn(String projectId) =>
      guides.any((BuiltInGuide g) => g.projectId == projectId);

  @override
  int orderOf(String projectId) =>
      guides.indexWhere((BuiltInGuide g) => g.projectId == projectId);
}

/// Persists whether the dashboard shows the built-in guides.
abstract class GuideVisibilityPreference {
  /// Whether guides are shown. Defaults to `true` when never set.
  Future<bool> load();

  /// Saves the writer's choice.
  Future<void> save(bool visible);
}
