// Unit tests for Project/Folder defaults and row round-trip.
//
// Covers task 2.5 of the writing-app-v2 spec:
// - Project.create / Folder.create defaults (modifiedAt == createdAt).
// - Field-for-field toRow()/fromRow() round-trip, including Folder.projectId.
// - Timestamps stored as ms-epoch-UTC and reconstructed as UTC.
//
// _Requirements: 2.2, 7.2, 17.1, 17.2_

import 'package:flutter_test/flutter_test.dart';
import 'package:spwrite/domain/folder.dart';
import 'package:spwrite/domain/project.dart';

void main() {
  group('Project.create defaults', () {
    test('sets modifiedAt equal to createdAt (by ms, both UTC)', () {
      final DateTime now = DateTime.now();
      final Project project = Project.create(
        id: 'p1',
        name: 'My Project',
        now: now,
      );

      expect(
        project.modifiedAt.toUtc().millisecondsSinceEpoch,
        project.createdAt.toUtc().millisecondsSinceEpoch,
      );
      expect(project.id, 'p1');
      expect(project.name, 'My Project');
    });
  });

  group('Folder.create defaults', () {
    test('sets modifiedAt equal to createdAt and stores projectId', () {
      final DateTime now = DateTime.now();
      final Folder folder = Folder.create(
        id: 'f1',
        projectId: 'p1',
        name: 'My Folder',
        now: now,
      );

      expect(
        folder.modifiedAt.toUtc().millisecondsSinceEpoch,
        folder.createdAt.toUtc().millisecondsSinceEpoch,
      );
      expect(folder.projectId, 'p1');
      expect(folder.id, 'f1');
      expect(folder.name, 'My Folder');
    });
  });

  group('Project round-trip via toRow()/fromRow()', () {
    test('reconstructs an equal Project (id, name, timestamps by ms)', () {
      final Project original = Project(
        id: 'p1',
        name: 'Round Trip',
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
        modifiedAt:
            DateTime.fromMillisecondsSinceEpoch(1700000500000, isUtc: true),
      );

      final Project restored = Project.fromRow(original.toRow());

      expect(restored, original);
      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(
        restored.createdAt.toUtc().millisecondsSinceEpoch,
        original.createdAt.toUtc().millisecondsSinceEpoch,
      );
      expect(
        restored.modifiedAt.toUtc().millisecondsSinceEpoch,
        original.modifiedAt.toUtc().millisecondsSinceEpoch,
      );
    });
  });

  group('Folder round-trip via toRow()/fromRow()', () {
    test('reconstructs an equal Folder with projectId preserved', () {
      final Folder original = Folder(
        id: 'f1',
        name: 'Round Trip Folder',
        projectId: 'p42',
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
        modifiedAt:
            DateTime.fromMillisecondsSinceEpoch(1700000900000, isUtc: true),
      );

      final Folder restored = Folder.fromRow(original.toRow());

      expect(restored, original);
      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.projectId, 'p42');
      expect(
        restored.createdAt.toUtc().millisecondsSinceEpoch,
        original.createdAt.toUtc().millisecondsSinceEpoch,
      );
      expect(
        restored.modifiedAt.toUtc().millisecondsSinceEpoch,
        original.modifiedAt.toUtc().millisecondsSinceEpoch,
      );
    });
  });

  group('Timestamps round-trip from a local DateTime as UTC', () {
    test('Project built with a local DateTime yields UTC equal in ms', () {
      final DateTime local = DateTime(2023, 11, 14, 22, 13, 20); // local time
      final Project project = Project.create(
        id: 'p1',
        name: 'Local Time',
        now: local,
      );

      final Project restored = Project.fromRow(project.toRow());

      expect(restored.createdAt.isUtc, isTrue);
      expect(restored.modifiedAt.isUtc, isTrue);
      expect(
        restored.createdAt.millisecondsSinceEpoch,
        local.toUtc().millisecondsSinceEpoch,
      );
      expect(
        restored.modifiedAt.millisecondsSinceEpoch,
        local.toUtc().millisecondsSinceEpoch,
      );
    });

    test('Folder built with a local DateTime yields UTC equal in ms', () {
      final DateTime local = DateTime(2023, 11, 14, 22, 13, 20); // local time
      final Folder folder = Folder.create(
        id: 'f1',
        projectId: 'p1',
        name: 'Local Time Folder',
        now: local,
      );

      final Folder restored = Folder.fromRow(folder.toRow());

      expect(restored.createdAt.isUtc, isTrue);
      expect(restored.modifiedAt.isUtc, isTrue);
      expect(
        restored.createdAt.millisecondsSinceEpoch,
        local.toUtc().millisecondsSinceEpoch,
      );
      expect(
        restored.modifiedAt.millisecondsSinceEpoch,
        local.toUtc().millisecondsSinceEpoch,
      );
      expect(restored.projectId, 'p1');
    });
  });
}
