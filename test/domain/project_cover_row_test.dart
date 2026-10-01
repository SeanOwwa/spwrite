// Unit tests for the Project cover photo: toRow/fromRow round-trip with and
// without a cover, List<int> normalization from the platform factory, rows
// read before the v7 column existed, and copyWith replace / keep / clear.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spwrite/domain/project.dart';

void main() {
  final DateTime now = DateTime.utc(2026, 3, 4, 5, 6, 7);
  final Uint8List cover = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 9, 8, 7]);

  group('Project cover row round-trip', () {
    test('a project with a cover round-trips field-for-field', () {
      final Project project =
          Project.create(id: 'p1', name: 'Covered', now: now, coverImage: cover);
      final Map<String, Object?> row = project.toRow();
      expect(row[ProjectColumns.coverImage], cover);

      final Project restored = Project.fromRow(row);
      expect(restored, project);
      expect(restored.coverImage, cover);
    });

    test('a project without a cover stores NULL and restores null', () {
      final Project project = Project.create(id: 'p1', name: 'Plain', now: now);
      final Map<String, Object?> row = project.toRow();
      expect(row.containsKey(ProjectColumns.coverImage), isTrue);
      expect(row[ProjectColumns.coverImage], isNull);
      expect(Project.fromRow(row).coverImage, isNull);
    });

    test('a List<int> BLOB from the factory is normalized to Uint8List', () {
      final Map<String, Object?> row =
          Project.create(id: 'p1', name: 'x', now: now).toRow()
            ..[ProjectColumns.coverImage] = <int>[1, 2, 3];
      final Project restored = Project.fromRow(row);
      expect(restored.coverImage, isA<Uint8List>());
      expect(restored.coverImage, <int>[1, 2, 3]);
    });

    test('a pre-v7 row without the column reads as no cover', () {
      final Map<String, Object?> row =
          Project.create(id: 'p1', name: 'Old', now: now).toRow()
            ..remove(ProjectColumns.coverImage);
      expect(Project.fromRow(row).coverImage, isNull);
    });

    test('equality distinguishes different cover bytes', () {
      final Project a =
          Project.create(id: 'p1', name: 'n', now: now, coverImage: cover);
      final Project b = a.copyWith(
        coverImage: Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 9, 8, 6]),
      );
      expect(a == b, isFalse);
      expect(a == a.copyWith(), isTrue);
    });
  });

  group('Project.copyWith cover', () {
    final Project withCover =
        Project.create(id: 'p1', name: 'n', now: now, coverImage: cover);

    test('keeps the cover when not specified (e.g. a rename)', () {
      expect(withCover.copyWith(name: 'renamed').coverImage, cover);
    });

    test('replaces the cover', () {
      final Uint8List next = Uint8List.fromList(<int>[4, 5, 6]);
      expect(withCover.copyWith(coverImage: next).coverImage, next);
    });

    test('clears the cover with clearCoverImage', () {
      expect(withCover.copyWith(clearCoverImage: true).coverImage, isNull);
    });
  });
}
