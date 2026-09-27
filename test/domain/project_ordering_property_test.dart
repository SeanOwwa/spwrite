// Property test for the Project ordering invariant (writing-app-v2 task 2.3).
//
// Feature: writing-app-v2, Property 4: For any set of Projects, the ordered list presented to the Dashboard is sorted by last-modified timestamp descending, and every pair sharing an identical last-modified timestamp is ordered by Name ascending (case-insensitive).
//
// **Validates: Requirements 1.2**
//
// Strategy: generate lists of (name, modified-at-ms) pairs drawn from small
// pools that deliberately include case variants, duplicate names, tied
// timestamps, and distinct timestamps. Build Projects with distinct ids, sort
// a copy with `compareProjects`, and assert every adjacent pair (a, b)
// satisfies:
//   - a.modifiedAt >= b.modifiedAt (compared in ms), and
//   - when the timestamps tie, a.name.toLowerCase() <= b.name.toLowerCase().

import 'package:kiri_check/kiri_check.dart';
import 'package:test/test.dart';
import 'package:spwrite/domain/project.dart';

void main() {
  // A pool of names chosen to force case-insensitive tie-breaking and
  // duplicate-name collisions: mixed case, repeats, and empty string.
  const List<String> namePool = <String>[
    'Alpha',
    'alpha',
    'ALPHA',
    'Beta',
    'beta',
    'Gamma',
    'gamma',
    'gAmMa',
    'Delta',
    '',
    'zeta',
    'Zeta',
  ];

  // A small pool of millisecond timestamps. The small range guarantees many
  // ties across a generated list while still offering distinct values.
  Arbitrary<int> modifiedMs() => integer(min: 1700000000000, max: 1700000000010);

  // One project's raw generated data: a name and a last-modified timestamp.
  Arbitrary<(String, int)> projectSpec() => combine2(
        constantFrom(namePool),
        modifiedMs(),
      );

  property('Property 4: Project ordering invariant', () {
    forAll(
      list(projectSpec(), minLength: 0, maxLength: 30),
      (List<(String, int)> specs) {
        // Build Projects with distinct ids (index-based) from the specs.
        final List<Project> projects = <Project>[];
        for (var i = 0; i < specs.length; i++) {
          final (String name, int ms) = specs[i];
          final DateTime ts =
              DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
          projects.add(
            Project(
              id: 'p$i',
              name: name,
              createdAt: ts,
              modifiedAt: ts,
            ),
          );
        }

        // Sort a copy using the shared ordering rule.
        final List<Project> ordered = List<Project>.from(projects)
          ..sort(compareProjects);

        // Every adjacent pair must satisfy the ordering invariant.
        for (var i = 0; i + 1 < ordered.length; i++) {
          final Project a = ordered[i];
          final Project b = ordered[i + 1];

          final int aMs = a.modifiedAt.toUtc().millisecondsSinceEpoch;
          final int bMs = b.modifiedAt.toUtc().millisecondsSinceEpoch;

          // Descending by last-modified timestamp.
          expect(
            aMs >= bMs,
            isTrue,
            reason: 'Expected modifiedAt descending: '
                '${a.name}@$aMs before ${b.name}@$bMs',
          );

          // On a tie, ascending by name (case-insensitive).
          if (aMs == bMs) {
            expect(
              a.name.toLowerCase().compareTo(b.name.toLowerCase()) <= 0,
              isTrue,
              reason: 'Expected name ascending (case-insensitive) on tie: '
                  '"${a.name}" before "${b.name}" at $aMs',
            );
          }
        }
      },
      maxExamples: 100,
    );
  });
}
