import 'package:flutter_test/flutter_test.dart';
import 'package:writing_app/domain/document.dart';

void main() {
  group('Document.newDocument', () {
    test('defaults for a root-level document (folderId null)', () {
      final now = DateTime.utc(2024, 1, 2, 3, 4, 5);
      final doc = Document.newDocument(
        id: 'doc-1',
        projectId: 'proj-1',
        folderId: null,
        now: now,
      );

      expect(doc.id, 'doc-1');
      expect(doc.title, 'Untitled Document');
      expect(doc.content, '');
      expect(doc.projectId, 'proj-1');
      expect(doc.folderId, isNull);
      expect(doc.createdAt, now);
      expect(doc.modifiedAt, now);
      expect(doc.modifiedAt, doc.createdAt);
    });

    test('sets folderId when provided', () {
      final now = DateTime.utc(2024, 5, 6, 7, 8, 9);
      final doc = Document.newDocument(
        id: 'doc-2',
        projectId: 'proj-1',
        folderId: 'folder-42',
        now: now,
      );

      expect(doc.folderId, 'folder-42');
      expect(doc.projectId, 'proj-1');
      expect(doc.title, 'Untitled Document');
      expect(doc.content, '');
      expect(doc.modifiedAt, doc.createdAt);
    });
  });

  group('toRow / fromRow round-trip', () {
    test('root-level document (folderId null) maps folder_id to null and round-trips', () {
      final created = DateTime.utc(2023, 11, 12, 13, 14, 15);
      final modified = DateTime.utc(2023, 11, 13, 9, 0, 0);
      final original = Document(
        id: 'doc-root',
        title: 'Root Doc',
        content: 'Some **markdown** body',
        projectId: 'proj-9',
        folderId: null,
        createdAt: created,
        modifiedAt: modified,
      );

      final row = original.toRow();
      expect(row[DocumentColumns.folderId], isNull);
      expect(row[DocumentColumns.projectId], 'proj-9');

      final restored = Document.fromRow(row);
      expect(restored, original);
      expect(restored.folderId, isNull);
      expect(restored.projectId, 'proj-9');
    });

    test('in-folder document preserves folderId through the round-trip', () {
      final created = DateTime.utc(2022, 3, 4, 5, 6, 7);
      final modified = DateTime.utc(2022, 3, 5, 8, 9, 10);
      final original = Document(
        id: 'doc-in-folder',
        title: 'Nested Doc',
        content: 'content',
        projectId: 'proj-3',
        folderId: 'some-folder',
        createdAt: created,
        modifiedAt: modified,
      );

      final row = original.toRow();
      expect(row[DocumentColumns.folderId], 'some-folder');

      final restored = Document.fromRow(row);
      expect(restored, original);
      expect(restored.folderId, 'some-folder');
      expect(restored.projectId, 'proj-3');
    });
  });

  group('equality includes projectId and folderId', () {
    final created = DateTime.utc(2024, 6, 6, 6, 6, 6);
    final modified = DateTime.utc(2024, 6, 7, 6, 6, 6);

    Document base({String projectId = 'proj-1', String? folderId}) => Document(
          id: 'same-id',
          title: 'Same Title',
          content: 'same content',
          projectId: projectId,
          folderId: folderId,
          createdAt: created,
          modifiedAt: modified,
        );

    test('two documents differing only in folderId are not equal', () {
      final a = base(folderId: null);
      final b = base(folderId: 'folder-x');

      expect(a == b, isFalse);
      expect(a.hashCode == b.hashCode, isFalse);
    });

    test('two documents differing only in projectId are not equal', () {
      final a = base(projectId: 'proj-1');
      final b = base(projectId: 'proj-2');

      expect(a == b, isFalse);
      expect(a.hashCode == b.hashCode, isFalse);
    });

    test('identical field values are equal', () {
      final a = base(folderId: 'folder-x');
      final b = base(folderId: 'folder-x');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
