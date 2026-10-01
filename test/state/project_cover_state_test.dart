// Unit tests for the AppNavigationState cover-photo flows: create with a
// cover, rename keeps the cover, updateProject replaces / clears it, and a
// failed save retains the in-memory state.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/domain/project_repository.dart';
import 'package:spwrite/state/app_navigation_state.dart';

/// A minimal in-memory [ProjectRepository].
class _MemoryProjectRepository implements ProjectRepository {
  final Map<String, Project> rows = <String, Project>{};
  bool failUpdates = false;

  @override
  Future<Project> create(Project project) async {
    rows[project.id] = project;
    return project;
  }

  @override
  Future<void> deleteCascade(String id) async => rows.remove(id);

  @override
  Future<List<Project>> getAll() async =>
      rows.values.toList()..sort(compareProjects);

  @override
  Future<Project?> getById(String id) async => rows[id];

  @override
  Future<void> update(Project project) async {
    if (failUpdates) throw StateError('disk full');
    rows[project.id] = project;
  }
}

void main() {
  final Uint8List cover = Uint8List.fromList(<int>[0xFF, 0xD8, 1]);
  late _MemoryProjectRepository repo;
  late AppNavigationState state;

  setUp(() {
    repo = _MemoryProjectRepository();
    state = AppNavigationState(repo, (Project p) => ChangeNotifier());
  });

  tearDown(() => state.dispose());

  test('createProject persists the cover', () async {
    await state.createProject('  Book  ', coverImage: cover);
    final Project created = state.projects.single;
    expect(created.name, 'Book');
    expect(created.coverImage, cover);
    expect(repo.rows[created.id]!.coverImage, cover);
  });

  test('renameProject keeps the cover', () async {
    await state.createProject('Book', coverImage: cover);
    final String id = state.projects.single.id;
    await state.renameProject(id, 'Renamed');
    expect(state.projects.single.name, 'Renamed');
    expect(repo.rows[id]!.coverImage, cover);
  });

  test('updateProject replaces and then clears the cover', () async {
    await state.createProject('Book');
    final String id = state.projects.single.id;
    expect(state.projects.single.coverImage, isNull);

    await state.updateProject(id, name: 'Book', coverImage: cover);
    expect(repo.rows[id]!.coverImage, cover);

    await state.updateProject(id, name: 'Book 2', clearCoverImage: true);
    expect(repo.rows[id]!.coverImage, isNull);
    expect(repo.rows[id]!.name, 'Book 2');
  });

  test('updateProject validates the name like rename', () async {
    await state.createProject('Book');
    final String id = state.projects.single.id;
    await state.updateProject(id, name: '   ', coverImage: cover);
    expect(state.transientError, 'A name is required.');
    expect(repo.rows[id]!.coverImage, isNull);
  });

  test('a failed update retains the in-memory project', () async {
    await state.createProject('Book', coverImage: cover);
    final String id = state.projects.single.id;
    repo.failUpdates = true;
    await state.updateProject(id, name: 'Book', clearCoverImage: true);
    expect(state.projects.single.coverImage, cover);
    expect(state.transientError, isNotNull);
  });
}
