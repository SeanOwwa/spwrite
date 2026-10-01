import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiri_check/kiri_check.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spwrite/data/database_provider.dart';
import 'package:spwrite/data/sqlite_app_settings_repository.dart';
import 'package:spwrite/presentation/export/export_location_service.dart';
import 'package:spwrite/presentation/export/export_platform_io.dart' as io;

/// Records every Save As request and answers with a scripted path.
class _ScriptedSavePicker {
  _ScriptedSavePicker(this.answer);

  String? answer;
  final List<({String suggestedName, String? initialDirectory})> calls =
      <({String suggestedName, String? initialDirectory})>[];

  Future<String?> call({
    required String suggestedName,
    String? initialDirectory,
  }) async {
    calls.add(
        (suggestedName: suggestedName, initialDirectory: initialDirectory));
    return answer;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late Directory fallbackDir;
  late Database db;
  late SqliteAppSettingsRepository settings;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spwrite_export_loc_');
    fallbackDir = await Directory('${tempDir.path}/Downloads').create();
    db = await DatabaseProvider.openAppDatabase(
      overridePath: '${tempDir.path}/settings.db',
    );
    settings = SqliteAppSettingsRepository(db);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ExportLocationService service(
    _ScriptedSavePicker picker, {
    DirectoryPicker? pickDirectory,
  }) {
    return ExportLocationService(
      settings: settings,
      directoryExists: io.directoryExists,
      writeBytes: io.writeBytesToFile,
      fallbackDirectory: () async => fallbackDir.path,
      pickSaveLocation: picker.call,
      pickDirectory:
          pickDirectory ?? ({String? initialDirectory}) async => null,
    );
  }

  test('cancelling Save As writes nothing and remembers nothing', () async {
    final _ScriptedSavePicker picker = _ScriptedSavePicker(null);
    final String? result =
        await service(picker).saveDocx(<int>[1, 2, 3], 'Novel.docx');

    expect(result, isNull);
    expect(picker.calls.single.suggestedName, 'Novel.docx');
    final List<FileSystemEntity> written = tempDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.docx'))
        .toList();
    expect(written, isEmpty);
    expect(
        await settings.getString(ExportLocationService.lastFolderKey), isNull);
  });

  test('writes to the chosen path, appending .docx when removed', () async {
    final Directory out = await Directory('${tempDir.path}/Out').create();
    final _ScriptedSavePicker picker =
        _ScriptedSavePicker('${out.path}/My Draft');
    final String? result =
        await service(picker).saveDocx(<int>[9, 8, 7], 'Novel.docx');

    expect(result, '${out.path}/My Draft.docx');
    expect(await File(result!).readAsBytes(), <int>[9, 8, 7]);
    // An existing extension (any case) is not doubled.
    picker.answer = '${out.path}/Upper.DOCX';
    expect(await service(picker).saveDocx(<int>[1], 'x.docx'),
        '${out.path}/Upper.DOCX');
  });

  test('remembered folder is persisted and used as initialDirectory', () async {
    final Directory chosen = await Directory('${tempDir.path}/Chosen').create();
    final _ScriptedSavePicker picker =
        _ScriptedSavePicker('${chosen.path}/a.docx');
    await service(picker).saveDocx(<int>[1], 'a.docx');

    expect(await settings.getString(ExportLocationService.lastFolderKey),
        chosen.path);

    // A fresh service over the same database (a "new launch") starts there.
    final _ScriptedSavePicker next = _ScriptedSavePicker(null);
    final ExportLocationService relaunched = service(next);
    expect(await relaunched.resolveDefaultFolder(), chosen.path);
    await relaunched.saveDocx(<int>[1], 'b.docx');
    expect(next.calls.single.initialDirectory, chosen.path);
  });

  test('a missing remembered folder falls back', () async {
    await settings.setString(
      ExportLocationService.lastFolderKey,
      '${tempDir.path}/deleted-folder',
    );
    final _ScriptedSavePicker picker = _ScriptedSavePicker(null);
    await service(picker).saveDocx(<int>[1], 'a.docx');
    expect(picker.calls.single.initialDirectory, fallbackDir.path);
  });

  test('chooseDefaultFolder persists the pick; cancel keeps the old one',
      () async {
    final Directory picked = await Directory('${tempDir.path}/Pick').create();
    String? answer = picked.path;
    String? seenInitial;
    final ExportLocationService s = service(
      _ScriptedSavePicker(null),
      pickDirectory: ({String? initialDirectory}) async {
        seenInitial = initialDirectory;
        return answer;
      },
    );
    expect(await s.chooseDefaultFolder(), picked.path);
    expect(seenInitial, fallbackDir.path);
    expect(await s.resolveDefaultFolder(), picked.path);

    answer = null;
    expect(await s.chooseDefaultFolder(), isNull);
    expect(await s.resolveDefaultFolder(), picked.path);
  });

  test('parentDirectory handles POSIX and Windows paths', () {
    expect(ExportLocationService.parentDirectory('/a/b/c.docx'), '/a/b');
    expect(ExportLocationService.parentDirectory('/c.docx'), '/');
    expect(ExportLocationService.parentDirectory(r'C:\Users\me\c.docx'),
        r'C:\Users\me');
    expect(ExportLocationService.parentDirectory(r'C:\c.docx'), r'C:\');
    expect(ExportLocationService.parentDirectory('c.docx'), isNull);
  });

  test('revealCommand uses argument lists per platform', () {
    const String p = '/Users/me/My Docs/a.docx';
    final mac = io.revealCommand(p, operatingSystem: 'macos')!;
    expect(mac.executable, 'open');
    expect(mac.arguments, <String>['-R', p]);
    final win = io.revealCommand(r'C:\x\a.docx', operatingSystem: 'windows')!;
    expect(win.executable, 'explorer');
    expect(win.arguments, <String>[r'/select,C:\x\a.docx']);
    final linux = io.revealCommand(p, operatingSystem: 'linux')!;
    expect(linux.executable, 'xdg-open');
    expect(linux.arguments, <String>['/Users/me/My Docs']);
  });

  // **Validates: Requirements 1 (".docx extension is appended if removed")**
  property('ensureDocxExtension always ends in .docx and is idempotent', () {
    forAll(
      string(maxLength: 40),
      (String name) {
        final String once = ExportLocationService.ensureDocxExtension(name);
        expect(once.toLowerCase().endsWith('.docx'), isTrue);
        expect(once.startsWith(name), isTrue);
        expect(ExportLocationService.ensureDocxExtension(once), once);
      },
      maxExamples: 200,
    );
  });
}
