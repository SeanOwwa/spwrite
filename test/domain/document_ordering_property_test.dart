// Feature: writing-app-v2, Property 6: For any set of Documents within a single Container, the ordered list is sorted by last-modified timestamp descending, and every pair sharing an identical last-modified timestamp is ordered by Title ascending (case-insensitive).
//
// Validates: Requirements 6.3
//
// The container is a single (project_id, folder_id) pair. This test generates
// lists of Documents that all share the same projectId and the same folderId
// (either all root-level with folderId == null, or all in one folder with the
// same folder id), with distinct document ids, titles drawn from a pool that
// includes case variants and duplicates, and timestamps drawn from a pool that
// deliberately produces both ties and distinct values. It sorts the list with
// `compareDocuments` and asserts the pairwise ordering invariant on every
// adjacent pair.

import 'package:kiri_check/kiri_check.dart';
import 'package:test/test.dart';

import 'package:writing_app/domain/document.dart';

/// A single generated document, described by its title and last-modified
/// timestamp (in ms since epoch). The container (projectId/folderId) and the
/// unique id are assigned when the list is materialized so ids stay distinct
/// and the whole list stays within one container.
typedef _DocSpec = (String title, int modifiedMillis);

/// Titles chosen to exercise the case-insensitive tie-breaker: mixed case,
/// duplicates, and case variants of the same word ("Alpha"/"alpha"/"ALPHA").
const List<String> _titlePool = <String>[
  'Alpha',
  'alpha',
  'ALPHA',
  'Beta',
  'beta',
  'gamma',
  'Gamma',
  '',
  'zeta',
  'Delta',
];

/// A small pool of timestamps so that many generated documents collide on
/// modified_at (forcing the title tie-breaker to matter), while still spanning
/// several distinct values.
const List<int> _millisPool = <int>[
  1000,
  1000,
  1000,
  2000,
  2000,
  3000,
  4000,
  5000,
];

Arbitrary<_DocSpec> _docSpecArbitrary() {
  return combine2(
    constantFrom(_titlePool),
    constantFrom(_millisPool),
  ).map((pair) => (pair.$1, pair.$2));
}

/// Builds the documents for one container from the generated specs. All
/// documents share [projectId] and [folderId]; ids are made distinct by index.
List<Document> _materialize(
  List<_DocSpec> specs, {
  required String projectId,
  required String? folderId,
}) {
  final docs = <Document>[];
  for (var i = 0; i < specs.length; i++) {
    final (title, millis) = specs[i];
    final ts = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    docs.add(
      Document(
        id: 'doc-$i',
        title: title,
        content: '',
        projectId: projectId,
        folderId: folderId,
        createdAt: ts,
        modifiedAt: ts,
      ),
    );
  }
  return docs;
}

void main() {
  property('Property 6: container-scoped document ordering invariant', () {
    forAll(
      combine2(
        list(_docSpecArbitrary(), maxLength: 12),
        // The whole list lives in ONE container: either the project root
        // (folderId == null) or a single folder with a fixed id.
        boolean(),
      ),
      (input) {
        final (specs, inFolder) = input;
        const projectId = 'project-1';
        final folderId = inFolder ? 'folder-1' : null;

        final docs = _materialize(
          specs,
          projectId: projectId,
          folderId: folderId,
        );

        docs.sort(compareDocuments);

        // Sanity: sorting preserves the multiset of documents (nothing added
        // or lost) and keeps everything within the single container.
        expect(docs.length, specs.length);
        for (final d in docs) {
          expect(d.projectId, projectId);
          expect(d.folderId, folderId);
        }

        // Every adjacent pair must satisfy the ordering rule:
        //   modified_at descending, then title ascending case-insensitive.
        for (var i = 0; i + 1 < docs.length; i++) {
          final a = docs[i];
          final b = docs[i + 1];

          final aMillis = a.modifiedAt.toUtc().millisecondsSinceEpoch;
          final bMillis = b.modifiedAt.toUtc().millisecondsSinceEpoch;

          // modified_at is non-increasing (descending) across the list.
          expect(
            aMillis >= bMillis,
            isTrue,
            reason: 'modified_at must be descending: '
                '$aMillis should be >= $bMillis at index $i',
          );

          // On a tie, title must be ascending (case-insensitive).
          if (aMillis == bMillis) {
            final cmp = a.title.toLowerCase().compareTo(b.title.toLowerCase());
            expect(
              cmp <= 0,
              isTrue,
              reason: 'on equal modified_at, titles must be ascending '
                  'case-insensitive: "${a.title}" should sort before or equal '
                  '"${b.title}" at index $i',
            );
          }
        }
      },
      maxExamples: 200,
    );
  });
}
