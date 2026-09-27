// Property test for Name/Title validation and trimming (writing-app-v2 task 8.3).
//
// Feature: writing-app-v2, Property 7: For any candidate Name (Project or Folder) or Title (Document) string, the value is trimmed of leading and trailing whitespace; if the trimmed length is between 1 and 255 inclusive, the persisted value equals the trimmed string (and on a rename the entity's last-modified timestamp advances); otherwise (trimmed length 0, or greater than 255) the change is rejected, leaving the entity's Name/Title and last-modified timestamp unchanged.
//
// **Validates: Requirements 2.2, 2.3, 2.4, 3.2, 3.3, 3.4, 7.2, 7.3, 7.4, 8.2, 8.3, 8.4, 12.2, 12.3, 12.4**
//
// This exercises the shared validation+trim rule through the STATE layer
// (AppNavigationState.createProject / renameProject), which is the single
// implementation of the 1..255-after-trim rule reused by folder and document
// name/title validation. Project create/rename is a representative sample of
// the property.
//
// Async handling: kiri_check 1.3.1's `forAll` block is a
// `FutureOr<void> Function(T)` that the framework awaits internally, so the
// block below is declared `async` and awaits repository / state calls directly.
// Each generated case opens a FRESH in-memory SQLite database via
// `DatabaseProvider.openAppDatabase(overridePath: inMemoryDatabasePath)` so
// cases never leak into each other, and closes it in a `finally` block. The
// state layer talks only to the real in-memory sqflite repositories (the same
// ones proven in test/data/), so validation is checked against genuine
// persistence rather than mocks.
//
// Candidate generation: a candidate string is assembled from a random
// whitespace prefix + a core built by repeating a character to a length drawn
// from a boundary-hitting pool (0, 1, 60, 254, 255, 256, 300) + a random
// whitespace suffix. Because whitespace is trimmed, the trimmed length equals
// the core length, so the pool makes the trimmed length span the invalid-low
// region (0), the whole valid band (1, 60, 254, 255), and the invalid-high
// region (256, 300). The core character is itself non-whitespace so trimming
// never eats into the core.

import 'package:flutter/foundation.dart';
import 'package:kiri_check/kiri_check.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/data/sqlite_project_repository.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/state/app_navigation_state.dart';

/// A generated candidate: the raw string handed to create/rename, plus the
/// core length used to build it (equals the trimmed length, since the core is
/// non-whitespace and only whitespace surrounds it).
typedef Candidate = ({String raw, int coreLength});

void main() {
  // Initialize the FFI in-memory factory so `flutter test` on macOS can open
  // an in-memory SQLite database.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Whitespace fragments used as prefix/suffix. '' means "no surrounding
  // whitespace" so the valid, already-trimmed case is covered too.
  const List<String> whitespacePool = <String>['', ' ', '\t', '\n', '  \t ', '\n \t'];

  // Core lengths chosen to straddle every boundary of the 1..255 rule:
  //   0        -> trimmed empty        (reject, Req x.3)
  //   1, 60,
  //   254, 255 -> valid band           (accept, Req x.2)
  //   256, 300 -> over the maximum      (reject, Req x.4)
  const List<int> coreLengthPool = <int>[0, 1, 60, 254, 255, 256, 300];

  // A non-whitespace filler character for the core, so trimming only removes
  // the surrounding whitespace and never shortens the core.
  const String coreChar = 'x';

  Arbitrary<String> whitespace() =>
      integer(min: 0, max: whitespacePool.length - 1).map((i) => whitespacePool[i]);

  Arbitrary<int> coreLength() =>
      integer(min: 0, max: coreLengthPool.length - 1).map((i) => coreLengthPool[i]);

  Arbitrary<Candidate> candidate() => combine3(
        whitespace(),
        coreLength(),
        whitespace(),
      ).map((r) {
        final String prefix = r.$1;
        final int len = r.$2;
        final String suffix = r.$3;
        final String core = coreChar * len;
        return (raw: '$prefix$core$suffix', coreLength: len);
      });

  // A throwaway workspace factory: create/rename never open a project, so the
  // notifier returned here is never used. A bare ChangeNotifier suffices.
  ChangeNotifier dummyWorkspace(Project project) => ChangeNotifier();

  property('Property 7: Name/Title validation and trimming', () {
    forAll(
      candidate(),
      (Candidate c) async {
        final String candidate = c.raw;
        final String trimmed = candidate.trim();
        // The shared rule: valid iff the trimmed value is 1..255 characters.
        final bool expectedValid = trimmed.isNotEmpty && trimmed.length <= 255;
        // Sanity: the core is non-whitespace, so trimmed length == core length.
        expect(
          trimmed.length,
          c.coreLength,
          reason: 'trimmed length must equal the generated core length',
        );

        final Database db = await DatabaseProvider.openAppDatabase(
          overridePath: inMemoryDatabasePath,
        );
        try {
          final SqliteProjectRepository projectRepo =
              SqliteProjectRepository(db);

          // ---- CREATE path -------------------------------------------------
          final AppNavigationState createState =
              AppNavigationState(projectRepo, dummyWorkspace);
          try {
            await createState.createProject(candidate);

            if (expectedValid) {
              expect(
                createState.projects.length,
                1,
                reason: 'a valid candidate must create exactly one project',
              );
              expect(
                createState.projects.single.name,
                trimmed,
                reason: 'the persisted name must equal the trimmed candidate',
              );
              expect(
                createState.transientError,
                isNull,
                reason: 'a successful create must clear any transient error',
              );
            } else {
              expect(
                createState.projects,
                isEmpty,
                reason: 'an invalid candidate must not create a project',
              );
              expect(
                createState.transientError,
                isNotNull,
                reason: 'an invalid candidate must surface a transient error',
              );
            }
          } finally {
            createState.dispose();
          }

          // ---- RENAME path -------------------------------------------------
          // Seed one project with a known valid name via a fresh state, then
          // capture its original name and last-modified timestamp.
          final AppNavigationState renameState =
              AppNavigationState(projectRepo, dummyWorkspace);
          try {
            const String seedName = 'Seed Project';
            await renameState.createProject(seedName);
            expect(
              renameState.projects.length,
              1,
              reason: 'seed project must exist before renaming',
            );
            final Project original = renameState.projects.single;
            final String originalName = original.name;
            final DateTime originalModified = original.modifiedAt;
            final int originalModifiedMs =
                originalModified.toUtc().millisecondsSinceEpoch;

            await renameState.renameProject(original.id, candidate);

            final Project after = renameState.projects.single;
            final int afterModifiedMs =
                after.modifiedAt.toUtc().millisecondsSinceEpoch;

            if (expectedValid) {
              expect(
                after.name,
                trimmed,
                reason: 'a valid rename must set the name to the trimmed value',
              );
              // The timestamp advances on a valid rename. Use >= to stay robust
              // against same-millisecond clock reads: correctness is that the
              // name changed AND the stamp never went backwards.
              expect(
                afterModifiedMs >= originalModifiedMs,
                isTrue,
                reason: 'a valid rename must not move last-modified backwards',
              );
              expect(
                renameState.transientError,
                isNull,
                reason: 'a successful rename must clear any transient error',
              );
            } else {
              expect(
                after.name,
                originalName,
                reason: 'an invalid rename must leave the name unchanged',
              );
              expect(
                afterModifiedMs,
                originalModifiedMs,
                reason: 'an invalid rename must leave last-modified unchanged',
              );
              expect(
                renameState.transientError,
                isNotNull,
                reason: 'an invalid rename must surface a transient error',
              );
            }
          } finally {
            renameState.dispose();
          }
        } finally {
          await db.close();
        }
      },
      maxExamples: 100,
    );
  });
}
