// Feature: writing-app-v2, Property 5: For any set of Folders of a Project, the ordered list presented in the Project_Sidebar is sorted by last-modified timestamp descending, and every pair sharing an identical last-modified timestamp is ordered by Name ascending (case-insensitive).
//
// Validates: Requirements 6.2
//
// A Folder belongs to exactly one Project (via projectId) and the hierarchy is
// one level deep, so the "container" for folder ordering is a single project.
// This test generates lists of Folders that all share the same projectId, with
// distinct folder ids, names drawn from a pool that includes case variants and
// duplicates, and timestamps drawn from a pool that deliberately produces both
// ties and distinct values. It sorts the list with `compareFolders` and asserts
// the pairwise ordering invariant on every adjacent pair.

import 'package:kiri_check/kiri_check.dart';
import 'package:test/test.dart';

import 'package:writing_app/domain/folder.dart';

/// A single generated folder, described by its name and last-modified
/// timestamp (in ms since epoch). The projectId and the unique id are assigned
/// when the list is materialized so ids stay distinct and the whole list stays
/// within one project.
typedef _FolderSpec = (String name, int modifiedMillis);

/// Names chosen to exercise the case-insensitive tie-breaker: mixed case,
/// duplicates, and case variants of the same word ("Alpha"/"alpha"/"ALPHA").
const List<String> _namePool = <String>[
  'Alpha',
  'alpha',
  'ALPHA',
  'Beta',
  'beta',
  'gamma',
  'Gamma',
  'notes',
  'zeta',
  'Delta',
];

/// A small pool of timestamps so that many generated folders collide on
/// modified_at (forcing the name tie-breaker to matter), while still spanning
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

Arbitrary<_FolderSpec> _folderSpecArbitrary() {
  return combine2(
    constantFrom(_namePool),
    constantFrom(_millisPool),
  ).map((pair) => (pair.$1, pair.$2));
}

/// Builds the folders for one project from the generated specs. All folders
/// share [projectId]; ids are made distinct by index.
List<Folder> _materialize(
  List<_FolderSpec> specs, {
  required String projectId,
}) {
  final folders = <Folder>[];
  for (var i = 0; i < specs.length; i++) {
    final (name, millis) = specs[i];
    final ts = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    folders.add(
      Folder(
        id: 'folder-$i',
        name: name,
        projectId: projectId,
        createdAt: ts,
        modifiedAt: ts,
      ),
    );
  }
  return folders;
}

void main() {
  property('Property 5: project-scoped folder ordering invariant', () {
    forAll(
      list(_folderSpecArbitrary(), maxLength: 12),
      (specs) {
        const projectId = 'project-1';

        final folders = _materialize(specs, projectId: projectId);

        folders.sort(compareFolders);

        // Sanity: sorting preserves the multiset of folders (nothing added or
        // lost) and keeps everything within the single project.
        expect(folders.length, specs.length);
        for (final f in folders) {
          expect(f.projectId, projectId);
        }

        // Every adjacent pair must satisfy the ordering rule:
        //   modified_at descending, then name ascending case-insensitive.
        for (var i = 0; i + 1 < folders.length; i++) {
          final a = folders[i];
          final b = folders[i + 1];

          final aMillis = a.modifiedAt.toUtc().millisecondsSinceEpoch;
          final bMillis = b.modifiedAt.toUtc().millisecondsSinceEpoch;

          // modified_at is non-increasing (descending) across the list.
          expect(
            aMillis >= bMillis,
            isTrue,
            reason: 'modified_at must be descending: '
                '$aMillis should be >= $bMillis at index $i',
          );

          // On a tie, name must be ascending (case-insensitive).
          if (aMillis == bMillis) {
            final cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
            expect(
              cmp <= 0,
              isTrue,
              reason: 'on equal modified_at, names must be ascending '
                  'case-insensitive: "${a.name}" should sort before or equal '
                  '"${b.name}" at index $i',
            );
          }
        }
      },
      maxExamples: 200,
    );
  });
}
