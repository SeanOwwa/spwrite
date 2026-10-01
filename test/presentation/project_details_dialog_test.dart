/// Widget tests for the create / edit project dialog with the cover upload:
/// the 1600 × 2560 hint, the live preview (fallback vs cover), the cropped
/// note, remove / replace, the friendly inline error for unreadable files,
/// and name validation.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:spwrite/data/cover_image_normalizer.dart';
import 'package:spwrite/domain/project.dart';
import 'package:spwrite/presentation/project_details_dialog.dart';
import 'package:spwrite/theme/app_theme.dart';

Uint8List _png(int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 80, 40));
  return img.encodePng(image);
}

/// Runs the normalizer synchronously (no isolate) so it completes inside the
/// widget test's fake-async zone.
Future<NormalizedCover> _syncNormalize(Uint8List bytes) async =>
    normalizeCoverImageSync(bytes);

/// Pumps an app with a button that opens the dialog and records its result.
Future<List<ProjectDetailsResult?>> _pumpLauncher(
  WidgetTester tester, {
  required CoverBytesPicker picker,
  Project? project,
}) async {
  final List<ProjectDetailsResult?> results = <ProjectDetailsResult?>[];
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              results.add(await ProjectDetailsDialog.show(
                context,
                project: project,
                pickCoverBytes: picker,
                normalizeCover: _syncNormalize,
              ));
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  testWidgets('shows the cover hint and the initial fallback preview',
      (WidgetTester tester) async {
    await _pumpLauncher(tester, picker: () async => null);

    expect(find.text('New project'), findsOneWidget);
    expect(find.text(CoverImageSpec.recommendation), findsOneWidget);
    expect(find.text('Recommended: 1600 × 2560 px (1.6:1)'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('project-cover-fallback')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('project-cover-image')),
        findsNothing);
    expect(find.text('Upload cover'), findsOneWidget);
    expect(find.text('Remove cover'), findsNothing);
  });

  testWidgets('uploading a wide image previews it, notes the crop, and '
      'returns the normalized cover', (WidgetTester tester) async {
    final List<ProjectDetailsResult?> results =
        await _pumpLauncher(tester, picker: () async => _png(300, 100));

    await tester.tap(find.text('Upload cover'));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('project-cover-image')),
        findsOneWidget);
    expect(find.textContaining('Cropped to 1.6:1'), findsOneWidget);
    expect(find.text('Replace'), findsOneWidget);
    expect(find.text('Remove cover'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '  My Book ');
    await tester.tap(find.text('Create project'));
    await tester.pumpAndSettle();

    final ProjectDetailsResult result = results.single!;
    expect(result.name, 'My Book');
    expect(result.coverChanged, isTrue);
    final img.Image stored = img.decodeJpg(result.coverImage!)!;
    expect(stored.width, 1600);
    expect(stored.height, 2560);
  });

  testWidgets('an unreadable file shows a friendly inline error',
      (WidgetTester tester) async {
    await _pumpLauncher(
      tester,
      picker: () async => Uint8List.fromList('hello'.codeUnits),
    );

    await tester.tap(find.text('Upload cover'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('isn\'t a supported image'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('project-cover-image')),
        findsNothing);
  });

  testWidgets('editing a project with a cover can remove it',
      (WidgetTester tester) async {
    final Project project = Project.create(
      id: 'p1',
      name: 'Existing',
      now: DateTime.utc(2026),
      coverImage: _png(16, 26),
    );
    final List<ProjectDetailsResult?> results =
        await _pumpLauncher(tester, picker: () async => null, project: project);

    expect(find.text('Edit project'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('project-cover-image')),
        findsOneWidget);

    await tester.tap(find.text('Remove cover'));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('project-cover-fallback')),
        findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final ProjectDetailsResult result = results.single!;
    expect(result.name, 'Existing');
    expect(result.coverChanged, isTrue);
    expect(result.coverImage, isNull);
  });

  testWidgets('an empty name is rejected inline and Escape cancels',
      (WidgetTester tester) async {
    final List<ProjectDetailsResult?> results =
        await _pumpLauncher(tester, picker: () async => null);

    await tester.tap(find.text('Create project'));
    await tester.pump();
    expect(find.text('A name is required.'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('New project'), findsNothing);
    expect(results.single, isNull);
  });
}
