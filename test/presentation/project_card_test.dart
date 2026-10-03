/// Widget tests for the Dashboard's portrait project cards and grid: a project
/// with a cover shows the cover image, one without shows the colorful initial
/// badge fallback, the controls are labelled, and the New-project dialog
/// (button and Ctrl+N shortcut) creates a card.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:spwrite/app_info.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/domain/project_repository.dart';
import 'package:spwrite/presentation/dashboard_view.dart';
import 'package:spwrite/presentation/project_card.dart';
import 'package:spwrite/state/app_navigation_state.dart';
import 'package:spwrite/theme/app_theme.dart';

Uint8List _png() {
  final img.Image image = img.Image(width: 16, height: 26);
  img.fill(image, color: img.ColorRgb8(10, 200, 120));
  return img.encodePng(image);
}

class _MemoryProjectRepository implements ProjectRepository {
  final Map<String, Project> rows = <String, Project>{};

  @override
  Future<Project> create(Project project) async => rows[project.id] = project;

  @override
  Future<void> deleteCascade(String id) async => rows.remove(id);

  @override
  Future<List<Project>> getAll() async =>
      rows.values.toList()..sort(compareProjects);

  @override
  Future<Project?> getById(String id) async => rows[id];

  @override
  Future<void> update(Project project) async => rows[project.id] = project;
}

Future<void> _pumpCard(WidgetTester tester, Project project) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 380,
            child: ProjectCard(
              project: project,
              onOpen: () {},
              onRename: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  final DateTime now = DateTime.utc(2026, 5, 17, 12);

  testWidgets('a project with a cover shows the cover image',
      (WidgetTester tester) async {
    await _pumpCard(
      tester,
      Project.create(id: 'p1', name: 'Moonlit', now: now, coverImage: _png()),
    );

    expect(find.byKey(const ValueKey<String>('project-cover-image')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('project-cover-fallback')),
        findsNothing);
    expect(find.text('Moonlit'), findsOneWidget);
    expect(find.textContaining('Edited May 17, 2026'), findsOneWidget);
  });

  testWidgets('a project without a cover shows the initial badge fallback',
      (WidgetTester tester) async {
    await _pumpCard(tester, Project.create(id: 'p1', name: 'moonlit', now: now));

    expect(find.byKey(const ValueKey<String>('project-cover-fallback')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('project-cover-image')),
        findsNothing);
    expect(find.text('M'), findsOneWidget);
  });

  testWidgets('the cover keeps a portrait 1:1.6 shape and controls have '
      'tooltips', (WidgetTester tester) async {
    await _pumpCard(tester, Project.create(id: 'p1', name: 'Shape', now: now));

    final Size size = tester
        .getSize(find.byKey(const ValueKey<String>('project-cover-fallback')));
    expect(size.height / size.width, closeTo(1.6, 0.01));
    expect(find.byTooltip('Edit project'), findsOneWidget);
    expect(find.byTooltip('Delete project'), findsOneWidget);
  });

  testWidgets('New project button and Ctrl+N open the create dialog and add '
      'a card', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final AppNavigationState state = AppNavigationState(
      _MemoryProjectRepository(),
      (Project p) => ChangeNotifier(),
    );
    addTearDown(state.dispose);
    await state.loadProjects();

    await tester.pumpWidget(
      ChangeNotifierProvider<AppNavigationState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: DashboardView(pickCoverBytes: () async => null),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No projects yet'), findsWidgets);

    // The keyboard shortcut (Ctrl+N off Apple platforms) opens the dialog.
    expect(defaultTargetPlatform, isNot(TargetPlatform.macOS));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Create project'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Harbor Lights');
    await tester.tap(find.text('Create project'));
    await tester.pumpAndSettle();

    expect(find.byType(ProjectCard), findsOneWidget);
    expect(find.text('Harbor Lights'), findsOneWidget);
    expect(find.text('1 project'), findsOneWidget);
  });

  testWidgets('the dashboard header shows the app version label',
      (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final AppNavigationState state = AppNavigationState(
      _MemoryProjectRepository(),
      (Project p) => ChangeNotifier(),
    );
    addTearDown(state.dispose);
    await state.loadProjects();

    await tester.pumpWidget(
      ChangeNotifierProvider<AppNavigationState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: DashboardView(pickCoverBytes: () async => null),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(AppInfo.version, 'Beta 1.3.4');
    expect(find.text('Beta 1.3.4'), findsOneWidget);
    expect(find.bySemanticsLabel('Version Beta 1.3.4'), findsOneWidget);
    final Text label = tester
        .widget<Text>(find.byKey(const ValueKey<String>('app-version-label')));
    expect(label.style?.color, AppPalette.textSecondary);
    semantics.dispose();
  });
}
