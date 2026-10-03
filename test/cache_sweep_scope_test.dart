import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plana_app/core/store/cache_sweep.dart';

void main() {
  late Directory fixture;
  late Directory temporary;
  final links = <String>[];

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('plana_cache_scope_');
    temporary = Directory(p.join(fixture.path, 'shared_temp'))..createSync();
    links.clear();
  });

  tearDown(() {
    // Remove only the links themselves before recursively removing fixtures.
    for (final path in links.reversed) {
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.link) {
        Link(path).deleteSync();
      }
    }
    fixture.deleteSync(recursive: true);
  });

  File write(String path, {bool old = false}) {
    final file = File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync('test cache data');
    if (old) {
      file.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
    }
    return file;
  }

  Future<void> linkDirectory(String path, Directory target) async {
    if (Platform.isWindows) {
      // Junction creation does not require Developer Mode or administrator
      // rights. Both paths are private test fixtures; no shell deletion occurs.
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'New-Item -ItemType Junction -Path $env:PLANA_TEST_LINK '
              r'-Target $env:PLANA_TEST_TARGET -ErrorAction Stop | Out-Null',
        ],
        environment: {
          'PLANA_TEST_LINK': path,
          'PLANA_TEST_TARGET': target.path,
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
    } else {
      await Link(path).create(target.path);
    }
    links.add(path);
    expect(
      FileSystemEntity.typeSync(path, followLinks: false),
      FileSystemEntityType.link,
    );
  }

  test('Windows counts and clears only the exact Plana cache root', () async {
    final foreign = [
      write(
        p.join(
          temporary.path,
          '12345678-1234-1234-1234-123456789abc',
          'keep.txt',
        ),
        old: true,
      ),
      for (final name in [
        '12345678-1234-1234-1234-123456789abc.png',
        'foreign.onnx',
        'image_picker_other.png',
        'scaled_other.jpg',
        'plana_share_backup/keep.txt',
      ])
        write(p.join(temporary.path, name), old: true),
    ];
    final owned = write(p.join(temporary.path, kShareCacheDir, 'image.png'));

    expect(
      (await temporaryStorageRoots(
        temporary,
        windows: true,
      )).map((e) => e.path),
      [p.join(temporary.path, kShareCacheDir)],
    );
    await sweepPickerCache(
      temporaryDirectory: temporary,
      windows: true,
      minAge: Duration.zero,
    );

    expect(owned.existsSync(), isFalse);
    expect(
      Directory(p.join(temporary.path, kShareCacheDir)).existsSync(),
      isFalse,
    );
    for (final file in foreign) {
      expect(file.readAsStringSync(), 'test cache data');
    }
    expect(await temporaryStorageRoots(temporary, windows: true), isEmpty);
  });

  test(
    'startup age protection includes newly written nested cache files',
    () async {
      final root = p.join(temporary.path, kShareCacheDir);
      final old = write(p.join(root, 'old.png'), old: true);
      final fresh = write(p.join(root, 'current.png'));
      final oldNested = write(p.join(root, 'nested', 'old.zip'), old: true);
      final freshNested = write(p.join(root, 'nested', 'active.zip'));

      await sweepPickerCache(temporaryDirectory: temporary, windows: true);

      expect(old.existsSync(), isFalse);
      expect(oldNested.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(freshNested.existsSync(), isTrue);

      await sweepPickerCache(
        temporaryDirectory: temporary,
        windows: true,
        minAge: Duration.zero,
      );
      expect(Directory(root).existsSync(), isFalse);
    },
  );

  test('an app-named root junction is neither counted nor cleaned', () async {
    final outside = Directory(p.join(fixture.path, 'other_app'))..createSync();
    final foreign = write(p.join(outside.path, 'keep.png'), old: true);
    final link = p.join(temporary.path, kShareCacheDir);
    await linkDirectory(link, outside);

    expect(await temporaryStorageRoots(temporary, windows: true), isEmpty);
    await sweepPickerCache(
      temporaryDirectory: temporary,
      windows: true,
      minAge: Duration.zero,
    );

    expect(foreign.readAsStringSync(), 'test cache data');
    expect(Link(link).existsSync(), isTrue);
  });

  test(
    'a nested junction never allows cleanup to leave the owned root',
    () async {
      final outside = Directory(p.join(fixture.path, 'other_app'))
        ..createSync();
      final foreign = write(p.join(outside.path, 'keep.png'), old: true);
      final owned = write(
        p.join(temporary.path, kShareCacheDir, 'old.png'),
        old: true,
      );
      final link = p.join(temporary.path, kShareCacheDir, 'foreign_link');
      await linkDirectory(link, outside);

      await sweepPickerCache(
        temporaryDirectory: temporary,
        windows: true,
        minAge: Duration.zero,
      );

      expect(owned.existsSync(), isFalse);
      expect(foreign.readAsStringSync(), 'test cache data');
      expect(Link(link).existsSync(), isTrue);
    },
  );

  test(
    'mobile retains app-local picker cleanup and minimum age behavior',
    () async {
      final old = write(
        p.join(temporary.path, 'image_picker_old.png'),
        old: true,
      );
      final fresh = write(p.join(temporary.path, 'scaled_current.png'));
      final unrelated = write(p.join(temporary.path, 'keep.dat'), old: true);
      expect(
        (await temporaryStorageRoots(temporary, windows: false)).single.path,
        temporary.path,
      );

      await sweepPickerCache(temporaryDirectory: temporary, windows: false);
      expect(old.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(unrelated.existsSync(), isTrue);

      await sweepPickerCache(
        temporaryDirectory: temporary,
        windows: false,
        minAge: Duration.zero,
      );
      expect(fresh.existsSync(), isFalse);
      expect(unrelated.existsSync(), isTrue);
    },
  );
}
