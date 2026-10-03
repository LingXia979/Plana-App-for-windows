import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plana_app/core/store/desktop_output_location.dart';
import 'package:plana_app/core/store/storage_stats.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory fixture;
  late Directory support;
  late Directory documents;
  late Directory temporary;
  late Directory installation;
  var missingDocuments = false;
  final links = <String>[];

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('plana_storage_scope_');
    support = Directory(p.join(fixture.path, 'support'));
    documents = Directory(p.join(fixture.path, 'documents'));
    temporary = Directory(p.join(fixture.path, 'shared_temp'));
    installation = Directory(p.join(fixture.path, 'program'));
    missingDocuments = false;
    links.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, (
      call,
    ) async {
      return switch (call.method) {
        'getApplicationSupportDirectory' => support.path,
        'getApplicationDocumentsDirectory' =>
          missingDocuments ? null : documents.path,
        'getTemporaryDirectory' => temporary.path,
        _ => null,
      };
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    for (final path in links.reversed) {
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.link) {
        Link(path).deleteSync();
      }
    }
    fixture.deleteSync(recursive: true);
  });

  File write(Directory root, String name, int length) {
    return File(p.join(root.path, name))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(length, 0));
  }

  Future<StorageReport> windowsReport() => scanStorage(
    windows: true,
    executablePath: p.join(installation.path, 'Plana.exe'),
  );

  Future<void> linkDirectory(String path, Directory target) async {
    Directory(p.dirname(path)).createSync(recursive: true);
    if (Platform.isWindows) {
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

  void expectConsistent(StorageReport report) {
    expect(
      report.categories.fold<int>(0, (sum, category) => sum + category.bytes) +
          report.otherBytes,
      report.totalBytes,
    );
  }

  test(
    'Windows counts app data, owned temp and works, not global roots',
    () async {
      write(support, 'gallery/images/image.png', 10);
      write(support, 'gallery/index.json', 3);
      write(support, 'prefs.json', 7);
      write(support, 'img_cache/image.jpg', 11);
      write(support, 'outputs/fallback.png', 5);
      write(support, 'outputs/fallback.json', 2);
      write(documents, 'Plana app for windows/作品/2026-10-03/image.png', 13);
      write(documents, 'Plana app for windows/作品/2026-10-03/image.json', 3);
      final foreignDocument = write(documents, 'other-app/important.dat', 1000);
      write(documents, 'Plana app for windows/other-folder.txt', 1000);
      write(temporary, 'plana_share/image.png', 17);
      write(temporary, 'plana_share/nested/image.png', 19);
      final foreignTemp = write(temporary, 'image_picker_foreign.png', 1000);
      write(temporary, 'foreign.onnx', 1000);
      write(temporary, 'plana_share_backup/image.png', 1000);

      final report = await windowsReport();

      expect(report.totalBytes, 90);
      expect(report.otherBytes, 7);
      expect(report['gallery']!.bytes, 13);
      expect(report['gallery']!.count, 1);
      expect(report['outputs']!.bytes, 23);
      expect(report['outputs']!.count, 2);
      expect(report['temp']!.bytes, 36);
      expect(report['imgCache']!.bytes, 11);
      expect(foreignDocument.lengthSync(), 1000);
      expect(foreignTemp.lengthSync(), 1000);
      expectConsistent(report);
    },
  );

  test('missing directories and unavailable Documents remain usable', () async {
    final empty = await windowsReport();
    expect(empty.totalBytes, 0);
    expect(empty['outputs']!.count, 0);
    expectConsistent(empty);

    missingDocuments = true;
    write(support, 'outputs/fallback.png', 12);
    final fallback = await windowsReport();
    expect(fallback.totalBytes, 12);
    expect(fallback['outputs']!.bytes, 12);
    expect(fallback['outputs']!.count, 1);
    expectConsistent(fallback);
  });

  test(
    'overlapping owned roots count every file and output only once',
    () async {
      documents = Directory(p.join(support.path, 'outputs'));
      temporary = support;
      write(support, 'outputs/root.png', 5);
      write(documents, 'Plana app for windows/作品/nested.png', 7);
      write(temporary, 'plana_share/image.png', 3);
      write(support, 'prefs.json', 2);

      final report = await windowsReport();
      expect(report.totalBytes, 17);
      expect(report['outputs']!.bytes, 12);
      expect(report['outputs']!.count, 2);
      expect(report['temp']!.bytes, 3);
      expect(report.otherBytes, 2);
      expectConsistent(report);
    },
  );

  test('app-private mobile Documents and temp remain included', () async {
    write(support, 'prefs.json', 1);
    write(documents, 'private-document.dat', 2);
    write(temporary, 'picker-image.png', 3);

    final report = await scanStorage(windows: false);
    expect(report.totalBytes, 6);
    expect(report['temp']!.bytes, 3);
    expect(report.otherBytes, 3);
    expectConsistent(report);

    documents = support;
    temporary = support;
    final overlapping = await scanStorage(windows: false);
    expect(overlapping.totalBytes, 1);
    expectConsistent(overlapping);
  });

  test('a linked support root cannot expose its outputs descendant', () async {
    final outside = Directory(p.join(fixture.path, 'other_app'));
    final foreign = write(outside, 'outputs/private.png', 1000);
    await linkDirectory(support.path, outside);
    write(temporary, 'plana_share/owned.png', 7);

    final report = await windowsReport();
    expect(report.totalBytes, 7);
    expect(report['outputs']!.bytes, 0);
    expect(foreign.lengthSync(), 1000);
    expectConsistent(report);
  });

  test(
    'nested links and a linked Documents app folder stay outside scope',
    () async {
      final outside = Directory(p.join(fixture.path, 'other_app'));
      final foreign = write(outside, '作品/private.png', 1000);
      write(support, 'gallery/images/owned.png', 9);
      await linkDirectory(p.join(support.path, 'gallery', 'foreign'), outside);
      await linkDirectory(
        p.join(documents.path, 'Plana app for windows'),
        outside,
      );

      final report = await windowsReport();
      expect(report.totalBytes, 9);
      expect(report['gallery']!.bytes, 9);
      expect(report['outputs']!.bytes, 0);
      expect(foreign.lengthSync(), 1000);
      expectConsistent(report);
    },
  );

  test(
    'counts program works and legacy leaves without counting the installation',
    () async {
      write(installation, 'Plana.exe', 1000);
      write(installation, 'data/app.so', 2000);
      write(installation, 'other-app/private.png', 1000);
      write(installation, 'output/2026-10-03/new.png', 11);
      write(installation, 'output/2026-10-03/new.json', 7);
      write(installation, '作品/2026-10-03/windows33.png', 5);
      write(documents, 'Plana app for windows/作品/2026-10-03/old.png', 13);
      write(support, 'outputs/2026-10-03/older.png', 17);
      final report = await windowsReport();
      expect(report.totalBytes, 53);
      expect(report['outputs']!.bytes, 53);
      expect(report['outputs']!.count, 4);
      expectConsistent(report);
    },
  );

  test(
    'linked installation ancestor and linked works leaf stay outside scope',
    () async {
      final foreign = Directory(p.join(fixture.path, 'foreign-program'));
      write(foreign, 'output/private.png', 1000);
      write(foreign, '作品/private.png', 1000);
      await linkDirectory(installation.path, foreign);
      expect((await windowsReport()).totalBytes, 0);
      installation = Directory(p.join(fixture.path, 'another-program'));
      await linkDirectory(p.join(installation.path, '作品'), foreign);
      await linkDirectory(p.join(installation.path, 'output'), foreign);
      expect((await windowsReport()).totalBytes, 0);
    },
  );

  test(
    'source project output is counted without scanning project or build',
    () async {
      write(
        installation,
        'pubspec.yaml',
        0,
      ).writeAsStringSync('name: plana_app\n');
      write(installation, 'lib/main.dart', 1000);
      Directory(
        p.join(installation.path, 'windows', 'runner'),
      ).createSync(recursive: true);
      final executable = write(
        installation,
        'build/windows/x64/runner/Release/Plana.exe',
        2000,
      );
      write(installation, 'output/2026-10-03/new.png', 11);
      write(
        installation,
        'build/windows/x64/runner/Release/作品/2026-10-03/old.png',
        7,
      );
      write(installation, 'unrelated/personal.png', 3000);
      final report = await scanStorage(
        windows: true,
        executablePath: executable.path,
      );
      expect(report.totalBytes, 18);
      expect(report['outputs']!.bytes, 18);
      expect(report['outputs']!.count, 2);
      expectConsistent(report);
    },
  );

  test('program works overlapping support are counted once', () async {
    installation = support;
    write(support, 'output/2026-10-03/same.png', 12);
    final report = await windowsReport();
    expect(report.totalBytes, 12);
    expect(report['outputs']!.bytes, 12);
    expect(report['outputs']!.count, 1);
    expectConsistent(report);
  });

  test(
    'registered prior program works remain counted after a location change',
    () async {
      final previous = Directory(
        p.join(fixture.path, 'old-installation', 'output'),
      );
      write(previous, '2026-10-03/prior.png', 13);
      write(installation, 'output/2026-10-03/current.png', 9);
      write(previous.parent, 'foreign.dll', 1000);
      await registerDesktopWorksRoot(support, previous);
      await registerDesktopWorksRoot(
        support,
        Directory(p.join(installation.path, 'output')),
      );
      final report = await windowsReport();
      expect(report['outputs']!.bytes, 22);
      expect(report['outputs']!.count, 2);
      expect(
        report.totalBytes,
        22 +
            await File(
              p.join(support.path, 'desktop_output_roots.json'),
            ).length(),
      );
      expectConsistent(report);
    },
  );
}
