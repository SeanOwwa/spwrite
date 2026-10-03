/// Widget tests for the built-in guides on the Dashboard: they are pinned
/// first with no delete or edit controls, and the "Guides" switch beside
/// New project hides and shows them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:spwrite/domain/guides/built_in_guide.dart';
import 'package:spwrite/domain/guides/developer_guide.dart';
import 'package:spwrite/domain/guides/user_guide.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/domain/project_repository.dart';
import 'package:spwrite/presentation/dashboard_view.dart';
import 'package:spwrite/state/app_navigation_state.dart';
import 'package:spwrite/state/guide_visibility_state.dart';
import 'package:spwrite/theme/app_theme.dart';

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

class _MemoryPreference implements GuideVisibilityPreference {
  bool stored = true;

  @override
  Future<bool> load() async => stored;

  @override
  Future<void> save(bool visible) async => stored = visible;
}

void main() {
  testWidgets('guides are pinned, protected, and hidden by the switch',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final DateTime now = DateTime.utc(2026, 10, 3);
    final _MemoryProjectRepository repo = _MemoryProjectRepository();
    for (final BuiltInGuide g in const <BuiltInGuide>[
      UserGuide(),
      DeveloperGuide(),
    ]) {
      await repo.create(
          Project.create(id: g.projectId, name: g.name, now: DateTime.utc(2020)));
    }
    await repo.create(Project.create(id: 'mine', name: 'My novel', now: now));

    final AppNavigationState nav = AppNavigationState(
      repo,
      (Project p) => ChangeNotifier(),
      builtInPolicy: const BuiltInGuideCatalog(
        <BuiltInGuide>[UserGuide(), DeveloperGuide()],
      ),
    );
    addTearDown(nav.dispose);
    await nav.loadProjects();
    final _MemoryPreference pref = _MemoryPreference();
    final GuideVisibilityState guides = GuideVisibilityState(pref);
    addTearDown(guides.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: <ChangeNotifierProvider<ChangeNotifier?>>[
          ChangeNotifierProvider<AppNavigationState>.value(value: nav),
          ChangeNotifierProvider<GuideVisibilityState?>.value(value: guides),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: DashboardView(pickCoverBytes: () async => null),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Pinned first, in catalog order, even though they are the oldest.
    final double userX = tester.getTopLeft(find.text('User Guide')).dx;
    final double devX = tester.getTopLeft(find.text('Developer Guide')).dx;
    final double mineX = tester.getTopLeft(find.text('My novel')).dx;
    expect(userX, lessThan(devX));
    expect(devX, lessThan(mineX));

    // Only the writer's project has edit and delete controls.
    expect(find.byTooltip('Delete project'), findsOneWidget);
    expect(find.byTooltip('Edit project'), findsOneWidget);
    expect(find.text('Built-in guide · read-only'), findsNWidgets(2));
    // The header counts only the writer's projects.
    expect(find.text('1 project'), findsOneWidget);

    // Turning the switch off hides the guides and remembers the choice.
    await tester.tap(find.byKey(const ValueKey<String>('dashboard-guides-switch')));
    await tester.pumpAndSettle();
    expect(find.text('User Guide'), findsNothing);
    expect(find.text('Developer Guide'), findsNothing);
    expect(find.text('My novel'), findsOneWidget);
    expect(pref.stored, isFalse);

    // And back on.
    await tester.tap(find.byKey(const ValueKey<String>('dashboard-guides-switch')));
    await tester.pumpAndSettle();
    expect(find.text('User Guide'), findsOneWidget);
  });
}
