/// Domain layer: the built-in **Developer Guide** project's content.
///
/// Plain data only. Keep it in sync with the code: when the architecture
/// changes, update the matching document here; the installer rewrites the
/// guide on the next launch.
///
/// Note: the guide is stored as Markdown, and the codec treats an unescaped
/// underscore as an italic marker, so file names in this text write each
/// underscore as `\_`.
library;

import 'built_in_guide.dart';

/// How Spwrite is built, for contributors, as a read-only project.
class DeveloperGuide extends BuiltInGuide {
  const DeveloperGuide();

  @override
  String get projectId => 'builtin.developer-guide';

  @override
  String get name => 'Developer Guide';

  @override
  List<GuideDocument> get rootDocuments => const <GuideDocument>[
        GuideDocument(title: 'Start here', markdown: _start),
      ];

  @override
  List<GuideFolder> get folders => const <GuideFolder>[
        GuideFolder(
          name: 'Architecture',
          documents: <GuideDocument>[
            GuideDocument(title: 'Layers', markdown: _layers),
            GuideDocument(title: 'SOLID in this codebase', markdown: _solid),
            GuideDocument(title: 'Composition root', markdown: _composition),
            GuideDocument(title: 'Data model and database', markdown: _data),
          ],
        ),
        GuideFolder(
          name: 'Features',
          documents: <GuideDocument>[
            GuideDocument(title: 'Editor and Markdown', markdown: _editor),
            GuideDocument(title: 'Saving', markdown: _saving),
            GuideDocument(title: 'Keyboard shortcuts', markdown: _shortcuts),
            GuideDocument(title: 'Built-in guides', markdown: _guides),
            GuideDocument(title: 'AI assistant', markdown: _ai),
          ],
        ),
        GuideFolder(
          name: 'Working on Spwrite',
          documents: <GuideDocument>[
            GuideDocument(title: 'Build and run', markdown: _build),
            GuideDocument(title: 'Testing', markdown: _testing),
            GuideDocument(title: 'Adding a feature', markdown: _adding),
            GuideDocument(title: 'Conventions', markdown: _conventions),
          ],
        ),
      ];
}

const String _start = r'''
# Developer Guide

Spwrite is a Flutter app for macOS, Windows, Linux and the web. Writing is stored locally in SQLite. There is no server.

This guide explains how the code is organised and how to change it safely. Read **Architecture** first, then the feature you want to work on.

## The short version

- Code lives in four layers under lib: domain, data, state and presentation.
- Dependencies point inward: presentation uses state, state uses domain, and data implements domain.
- Every collaborator is created in one place, lib/main.dart, and handed in through constructors.
- Tests replace real collaborators with fakes, so almost everything runs without a database, a network, or a model.
''';

const String _layers = r'''
# Layers

## domain

Pure Dart, with no Flutter widgets, SQLite or plugins. It holds:

- Value objects such as Project, Folder, Document and Character, with their ordering rules.
- Repository interfaces such as ProjectRepository, DocumentRepository and AppSettingsRepository.
- Pure services such as MarkdownDocumentCodec, and guide content in lib/domain/guides.

## data

Implements the domain interfaces over real technology: SQLite repositories (sqlite\_document\_repository.dart and friends), DatabaseProvider for the schema, the guide installer, and the AI runtime adapters. Nothing above this layer imports SQLite.

## state

ChangeNotifier classes that hold app state and rules:

- AppNavigationState: the project list, opening and closing projects.
- ProjectWorkspaceState: the open project's folders, documents, active document and autosave.
- CharacterPanelState, GuideVisibilityState, and the AI states.

State classes depend only on domain interfaces, so they are tested with in-memory fakes.

## presentation

Widgets. They read state with provider (context.watch, context.select) and send user intents back as method calls. Widgets do not talk to repositories. Colours and spacing come from lib/theme/app\_theme.dart (AppPalette, AppSpacing, AppStyle).
''';

const String _solid = r'''
# SOLID in this codebase

## Single responsibility

Each class has one reason to change. For example, the built-in guides are split into content (UserGuide, DeveloperGuide), installation (GuideInstaller), the show or hide choice (GuideVisibilityState) and display (the dashboard). Changing a guide's text touches only its content class.

## Open and closed

Add behaviour by adding code, not by editing working code. A new built-in guide is a new BuiltInGuide subclass listed in the catalog; the installer, dashboard and editor need no change. Editor shortcuts are a table in editor\_shortcuts.dart: a new shortcut is a new entry and a new EditorCommand case.

## Liskov substitution

Every implementation of an interface must be usable wherever the interface is expected. ObservableDocumentRepository wraps SqliteDocumentRepository and behaves identically, only adding change events. Test fakes follow the same contracts as the SQLite repositories.

## Interface segregation

Interfaces stay small and focused. Code that only needs to know whether a project is built in depends on BuiltInProjectPolicy, not on the whole catalog. AppSettingsRepository has just three methods.

## Dependency inversion

High-level code depends on abstractions, and lib/main.dart supplies the concrete classes. AppNavigationState receives a ProjectRepository and a BuiltInProjectPolicy; it never constructs SQLite objects. This is what makes the state layer testable with fakes.
''';

const String _composition = r'''
# Composition root

lib/main.dart is the only place that knows every concrete class. On startup it:

1. Picks the SQLite factory for the platform and opens the database.
2. Builds the repositories over the one database, wrapping documents and characters in change-observable decorators.
3. Installs or refreshes the built-in guides.
4. Builds the app-wide services and the per-project factories.
5. Creates AppNavigationState with a factory that builds a ProjectWorkspaceState for each opened project.
6. Runs the app with these objects provided through MultiProvider.

AppRoot shows the dashboard, or, when a project is open, provides the project-scoped states (workspace, characters, and the AI states when enabled), keyed by project id so they are rebuilt for each project.

When you add a collaborator, construct it here and pass it in. Do not create collaborators inside widgets or state classes.
''';

const String _data = r'''
# Data model and database

## Model

A project holds folders and documents. A document belongs to one project and at most one folder; a document with no folder sits at the top level. Characters belong to a project. Sidebar order uses a position column, then last-edited time, then name.

## Database

DatabaseProvider (lib/data/database\_provider.dart) owns the schema. The main tables are projects, folders, documents, characters, ai\_conversations, ai\_chunk\_embeddings, ai\_index\_state and app\_settings.

## Changing the schema

1. Add a helper that creates the table with CREATE TABLE IF NOT EXISTS, or adds a column and ignores the duplicate-column error.
2. Call it from the fresh-schema path, from onUpgrade behind a version check, and from onOpen. The web database does not reliably run onUpgrade, so onOpen is the safety net.
3. Bump schemaVersion and add a migration test that opens an older database and checks existing data survives.

Always use bound parameters in SQL. Only trusted table and column constants may be written into SQL text.
''';

const String _editor = r'''
# Editor and Markdown

The editor is flutter\_quill, which works on a Delta (a list of text runs with formatting). Documents are stored as Markdown. MarkdownDocumentCodec in lib/domain converts between the two, and it is the only place that does.

## Supported formatting

Bold, italic, headings, numbered and bulleted lists, and links. The toolbar and shortcuts only offer these, and shortcuts for anything else are switched off, so nothing can be created that the codec cannot store.

## Details worth knowing

- Italic is written with asterisks, and spaces at the edge of a bold or italic run are moved outside the markers, so the Markdown stays valid.
- Older documents that saved italic with underscores are repaired when they load.
- Blank lines and Tab indents are stored as no-break spaces, so Markdown does not collapse them.
- When you change the codec, add a round-trip test: save to Markdown, load back, and compare.
''';

const String _saving = r'''
# Saving

ProjectWorkspaceState.onContentChanged converts the Delta to Markdown, enforces the one-million-character limit, updates the document in memory, and schedules a save through AutosaveDebouncer (two seconds after the last change).

saveNow writes any pending change immediately. It runs before switching or creating a document, on Cmd or Ctrl+S, when the app is hidden or asked to quit (an AppLifecycleListener in the editor), and when the workspace is disposed.

A failed save keeps the text in memory, shows Save failed, and is retried by the next edit.
''';

const String _shortcuts = r'''
# Keyboard shortcuts

All editor shortcuts are defined in lib/presentation/editor\_shortcuts.dart:

- editorShortcuts builds the key map. The primary modifier is Cmd on Apple platforms and Ctrl elsewhere.
- Each shortcut maps to an EditorCommandIntent, and EditorView runs the command in one switch statement.
- The same map is given to the Quill editor and to a Shortcuts widget around the editor area, so shortcuts work wherever focus is.
- ShortcutLabel produces the platform-correct text for tooltips and the shortcut sheet.
- typingShortcutEvents holds typing replacements, such as three hyphens becoming an em dash.

To add a shortcut: add an EditorCommand value, add its key to editorShortcuts, handle it in EditorView, and list it in the shortcut sheet and the User Guide.
''';

const String _guides = r'''
# Built-in guides

The User Guide and Developer Guide are real projects, installed by the app.

## Pieces

- Content: UserGuide and DeveloperGuide in lib/domain/guides, each a BuiltInGuide with a fixed project id, root documents and folders of Markdown.
- Catalog: BuiltInGuideCatalog lists the guides in dashboard order and implements BuiltInProjectPolicy.
- Installer: GuideInstaller (lib/data/guides) creates a missing guide, and rewrites one whose content changed. It stores a SHA-256 fingerprint of each guide in app settings, so normal launches write nothing.
- Protection: AppNavigationState refuses to delete or rename a built-in project, and ProjectWorkspaceState opens it read-only, turning every editing method into a no-op. The sidebar and editor hide their editing controls.
- Visibility: GuideVisibilityState and the Guides switch on the dashboard hide or show the guides. The choice is saved in app settings.

## Editing a guide

Change the text in its content class and run the app. The fingerprint changes, so the guide is rewritten on launch. Escape underscores as a backslash followed by an underscore, and use only the supported formatting.

## Adding a guide

Write a new BuiltInGuide subclass with a new fixed id, and add it to the catalog in lib/main.dart. Nothing else changes.
''';

const String _ai = r'''
# AI assistant

The on-device assistant (chat, keyword and semantic retrieval, background indexing) is developed on the ai\_feature branch.

On main it is switched off by AppInfo.aiAssistantAvailable in lib/app\_info.dart. While it is false, AppRoot does not create the AI states, so no model is downloaded and no indexing runs, and the AI panel shows a Coming soon placeholder.

The AI code is layered like the rest of the app: LlmEngine, EmbeddingModel and ContextRetriever are domain interfaces, with fllama and SQLite implementations in lib/data/ai.
''';

const String _build = r'''
# Build and run

The installer scripts in the scripts folder set up Flutter and build the app. To work by hand:

- Get packages: flutter pub get
- Web only, once: dart run sqflite\_common\_ffi\_web:setup
- Run while developing: flutter run -d macos (or windows, linux, chrome)
- Release build: flutter build macos --release (or windows, linux, web)

A desktop app must be built on its own operating system: the Windows build on Windows, the Linux build on Linux.
''';

const String _testing = r'''
# Testing

- Run everything: flutter test
- Static checks: flutter analyze

Tests mirror lib: test/domain, test/data, test/state and test/presentation.

- Domain and state tests use in-memory fakes of the repository interfaces.
- Data tests use real SQLite in memory through sqflite\_common\_ffi.
- Property tests use kiri\_check and are named with a property\_test suffix.

Every bug fix gets a test that fails without the fix. Changes to the Markdown codec need round-trip tests.
''';

const String _adding = r'''
# Adding a feature

1. Decide which layer each part belongs to. Rules and data shapes go in domain, storage in data, app state in state, and widgets in presentation.
2. Define small interfaces in domain for anything the state layer needs from outside.
3. Implement them in data.
4. Put the behaviour in a state class that takes its collaborators through the constructor.
5. Build the widgets, using AppPalette and AppSpacing for every colour and space.
6. Wire the new classes in lib/main.dart.
7. Write tests for the domain logic and the state class, using fakes.
8. Update the User Guide, and this guide if the architecture changed.
''';

const String _conventions = r'''
# Conventions

- Every file starts with a library comment saying which layer it is in and what it does.
- Prefer immutable value objects with copyWith.
- State classes guard against use after dispose, and report recoverable problems through a transient error rather than throwing.
- SQL uses bound parameters only.
- UI colours, spacing and shapes come from lib/theme/app\_theme.dart, never hard-coded values.
- Keep main buildable at all times. Larger work happens on a feature branch.
''';
