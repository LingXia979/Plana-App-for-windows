import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/desktop_output_location.dart';
import 'package:plana_app/core/store/desktop_output_store.dart';
import 'package:plana_app/features/gallery/models.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late Directory documents;
  late Directory support;
  late Directory program;
  late DesktopOutputStore old;
  late DesktopOutputStore fallback;
  late DesktopOutputStore current;
  final links = <String>[];

  ResultImage result(String id, {List<int> bytes = const [1, 2, 3]}) =>
      ResultImage(
        id: id,
        width: 10,
        height: 20,
        seed: 4,
        createdAt: DateTime(2026, 10, 3, 12).millisecondsSinceEpoch,
        bytes: Uint8List.fromList(bytes),
      );
  File sidecar(File png) => File(p.setExtension(png.path, '.json'));
  Future<List<File>> pngs(Directory root) async {
    if (!await root.exists()) return [];
    return root
        .list(recursive: true, followLinks: false)
        .where((file) => file is File && file.path.endsWith('.png'))
        .cast<File>()
        .toList();
  }

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('plana_output_migration_');
    documents = Directory(p.join(fixture.path, 'Documents'));
    support = Directory(p.join(fixture.path, 'support'));
    program = Directory(p.join(fixture.path, 'another-drive', 'Plana'));
    old = DesktopOutputStore(legacyDesktopWorksDirectory(documents));
    fallback = DesktopOutputStore(Directory(p.join(support.path, 'outputs')));
    current = DesktopOutputStore(
      desktopWorksDirectory(executablePath: p.join(program.path, 'Plana.exe')),
      legacyRoots: [old.root, fallback.root],
    );
    links.clear();
  });
  tearDown(() async {
    await current.idle;
    for (final path in links.reversed) {
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.link) {
        Link(path).deleteSync();
      }
    }
    await fixture.delete(recursive: true);
  });

  Future<void> linkDirectory(String path, Directory target) async {
    await Directory(p.dirname(path)).create(recursive: true);
    if (Platform.isWindows) {
      final process = await Process.run(
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
      expect(process.exitCode, 0, reason: '${process.stderr}');
    } else {
      await Link(path).create(target.path);
    }
    links.add(path);
    expect(
      FileSystemEntity.typeSync(path, followLinks: false),
      FileSystemEntityType.link,
    );
  }

  test(
    'portable output follows executable and opening creates no empty directory',
    () async {
      expect(
        outputPathKey(current.root.path),
        outputPathKey(p.join(program.path, 'output')),
      );
      expect(await current.root.exists(), isFalse);
      final report = await current.migrateLegacy();
      expect(report.migrated, 0);
      expect(report.issues, isEmpty);
      expect(await current.root.exists(), isFalse);
      final file = await current.save(result('new'));
      expect(p.isWithin(program.path, file.path), isTrue);
    },
  );

  Future<void> sourceMarkers(
    Directory root, {
    String name = 'plana_app',
  }) async {
    await root.create(recursive: true);
    await File(
      p.join(root.path, 'pubspec.yaml'),
    ).writeAsString('name: $name\n');
    await File(p.join(root.path, 'lib', 'main.dart')).create(recursive: true);
    await Directory(
      p.join(root.path, 'windows', 'runner'),
    ).create(recursive: true);
  }

  test(
    'source builds put output at project root for every build mode',
    () async {
      await sourceMarkers(program);
      for (final architecture in ['x64', 'arm64']) {
        for (final mode in ['Release', 'Debug', 'Profile']) {
          final executable = p.join(
            program.path,
            'build',
            'windows',
            architecture,
            'runner',
            mode,
            'plana_app_for_windows.exe',
          );
          expect(
            outputPathKey(
              desktopWorksDirectory(executablePath: executable).path,
            ),
            outputPathKey(p.join(program.path, 'output')),
          );
        }
      }
      expect(await Directory(p.join(program.path, 'output')).exists(), isFalse);
    },
  );

  test(
    'portable build-looking folders never escape without Plana markers',
    () async {
      final executable = p.join(
        program.path,
        'build',
        'windows',
        'x64',
        'runner',
        'Release',
        'Plana.exe',
      );
      final expected = p.join(p.dirname(executable), 'output');
      expect(desktopWorksDirectory(executablePath: executable).path, expected);
      await sourceMarkers(program, name: 'another_app');
      expect(desktopWorksDirectory(executablePath: executable).path, expected);
      await File(
        p.join(program.path, 'pubspec.yaml'),
      ).writeAsString('name: plana_app\n');
      expect(
        desktopWorksDirectory(executablePath: executable).path,
        p.join(program.path, 'output'),
      );
    },
  );

  test(
    'date and album pairs migrate from both old roots, manual files remain',
    () async {
      final a = await old.save(result('date'));
      final b = await old.save(result('album'), albumId: 'album_one');
      final c = await fallback.save(result('fallback'));
      final legacyMeta = jsonDecode(await sidecar(a).readAsString()) as Map;
      legacyMeta.remove('managedBy');
      await sidecar(a).writeAsString(jsonEncode(legacyMeta));
      final manual = await File(
        p.join(a.parent.path, 'manual.png'),
      ).writeAsBytes([9]);
      final manualJson = await File(
        p.join(a.parent.path, 'manual.json'),
      ).writeAsString('{}');
      final foreignFolder = await Directory(
        p.join(old.root.path, 'exports'),
      ).create();
      final foreign = await a.copy(
        p.join(foreignFolder.path, p.basename(a.path)),
      );
      await sidecar(a).copy(sidecar(foreign).path);
      final before = {
        for (final file in [a, b, c])
          p.basename(file.path): await file.readAsBytes(),
      };
      final report = await current.migrateLegacy();
      expect(report.migrated, 3);
      expect(report.issues, isEmpty);
      for (final file in [a, b, c]) {
        expect(await file.exists(), isFalse);
        expect(await sidecar(file).exists(), isFalse);
      }
      final migrated = await pngs(current.root);
      expect(migrated, hasLength(3));
      for (final file in migrated) {
        expect(await file.readAsBytes(), before[p.basename(file.path)]);
        expect(await sidecar(file).exists(), isTrue);
      }
      expect(migrated.any((file) => file.path.contains('album_one')), isTrue);
      expect(await manual.exists(), isTrue);
      expect(await manualJson.exists(), isTrue);
      expect(await foreign.exists(), isTrue);
      expect(await sidecar(foreign).exists(), isTrue);
      expect(current.lastMigration, same(report));
      expect(current.migrating, isFalse);
    },
  );

  test(
    'identical completed copy resumes cleanup; different names never overwrite',
    () async {
      final image = result('same');
      final source = await old.save(image);
      final existing = await current.save(image);
      var report = await current.migrateLegacy();
      expect(report.migrated, 1);
      expect(report.issues, isEmpty);
      expect(await source.exists(), isFalse);
      expect(await pngs(current.root), hasLength(1));

      final secondSource = await old.save(result('same', bytes: [4, 5, 6]));
      report = await current.migrateLegacy();
      expect(report.migrated, 1);
      expect(report.issues, isEmpty);
      expect(await secondSource.exists(), isFalse);
      expect(await existing.readAsBytes(), [1, 2, 3]);
      final all = await pngs(current.root);
      expect(all, hasLength(2));
      expect(
        all.any((file) => p.basename(file.path).endsWith('_1.png')),
        isTrue,
      );
      final retried = await current.migrateLegacy();
      expect(retried.migrated, 0);
      expect(retried.issues, isEmpty);
      expect(await pngs(current.root), hasLength(2));
    },
  );

  test(
    'partial or unrelated destination is retained and migration chooses a new name',
    () async {
      final source = await old.save(result('partial'));
      final folder = current.folderFor(null, DateTime(2026, 10, 3));
      await folder.create(recursive: true);
      final partial = await File(
        p.join(folder.path, p.basename(source.path)),
      ).writeAsBytes([99]);
      final report = await current.migrateLegacy();
      expect(report.migrated, 1);
      expect(report.issues, isEmpty);
      expect(await partial.readAsBytes(), [99]);
      expect(await sidecar(partial).exists(), isFalse);
      expect(await pngs(current.root), hasLength(2));
      expect(await source.exists(), isFalse);
    },
  );

  test(
    'unwritable destination retains both source files and retry succeeds',
    () async {
      final source = await old.save(result('blocked'));
      await program.create(recursive: true);
      final blocker = await File(
        current.root.path,
      ).writeAsString('blocks directory creation');
      final failed = await current.migrateLegacy();
      expect(failed.migrated, 0);
      expect(failed.hasErrors, isTrue);
      expect(await source.readAsBytes(), [1, 2, 3]);
      expect(await sidecar(source).exists(), isTrue);
      await expectLater(
        current.save(result('new')),
        throwsA(isA<FileSystemException>()),
      );
      await blocker.delete();
      final retried = await current.migrateLegacy();
      expect(retried.migrated, 1);
      expect(retried.issues, isEmpty);
      expect(await source.exists(), isFalse);
      expect(await pngs(current.root), hasLength(1));
    },
  );

  test(
    'invalid matching metadata is retained and does not block a valid sibling',
    () async {
      final bad = await old.save(result('bad'));
      final good = await old.save(result('good'));
      await sidecar(bad).writeAsString('{broken');
      final report = await current.migrateLegacy();
      expect(report.migrated, 1);
      expect(report.hasErrors, isTrue);
      expect(await bad.exists(), isTrue);
      expect(await sidecar(bad).exists(), isTrue);
      expect(await good.exists(), isFalse);
      expect((await pngs(current.root)).single.path, contains('good_'));
    },
  );

  test(
    'source deletion permission failure retains verified copy and retries without duplication',
    () async {
      final source = await old.save(result('read_only'));
      final protected = await Process.run('attrib.exe', ['+R', source.path]);
      expect(protected.exitCode, 0);
      try {
        final report = await current.migrateLegacy();
        expect(report.migrated, 0);
        expect(report.hasErrors, isTrue);
        expect(await source.exists(), isTrue);
        expect(await sidecar(source).exists(), isTrue);
        expect(await pngs(current.root), hasLength(1));
      } finally {
        final writable = await Process.run('attrib.exe', ['-R', source.path]);
        expect(writable.exitCode, 0);
      }
      final retried = await current.migrateLegacy();
      expect(retried.migrated, 1);
      expect(retried.issues, isEmpty);
      expect(await source.exists(), isFalse);
      expect(await sidecar(source).exists(), isFalse);
      expect(await pngs(current.root), hasLength(1));
    },
    skip: !Platform.isWindows,
  );

  test(
    'deletion removes pending legacy and new copies without requiring migration',
    () async {
      final image = result('delete');
      final files = [
        await old.save(image),
        await fallback.save(image),
        await current.save(image),
      ];
      expect(
        await current.deleteResults([image], canDelete: (_) => false),
        isEmpty,
      );
      expect(await current.deleteResults([image]), {'delete'});
      for (final file in files) {
        expect(await file.exists(), isFalse);
        expect(await sidecar(file).exists(), isFalse);
      }
      final report = await current.migrateLegacy();
      expect(report.migrated, 0);
      expect(report.issues, isEmpty);
      await expectLater(current.save(image), throwsStateError);
    },
  );

  test(
    'migration and queued deletion cannot resurrect a deleted work',
    () async {
      final image = result('queued');
      await old.save(image);
      final migration = current.migrateLegacy();
      final deletion = current.deleteResults([image]);
      expect(await deletion, {'queued'});
      await migration;
      expect(await pngs(current.root), isEmpty);
      expect(await pngs(old.root), isEmpty);
    },
  );

  test('source root and destination links are not followed', () async {
    final outside = DesktopOutputStore(
      Directory(p.join(fixture.path, 'foreign')),
    );
    final image = result('private');
    final foreign = await outside.save(image);
    await Directory(p.dirname(old.root.path)).create(recursive: true);
    await linkDirectory(old.root.path, outside.root);
    final linkedSource = await current.migrateLegacy();
    expect(linkedSource.hasErrors, isTrue);
    expect(await current.root.exists(), isFalse);
    await current.deleteResults([image]);
    expect(await foreign.readAsBytes(), [1, 2, 3]);
    expect(await sidecar(foreign).exists(), isTrue);

    final source = await fallback.save(result('dest-link'));
    await linkDirectory(current.root.path, outside.root);
    final linkedDestination = await current.migrateLegacy();
    expect(linkedDestination.hasErrors, isTrue);
    expect(await source.exists(), isTrue);
    await expectLater(
      current.save(result('new')),
      throwsA(isA<FileSystemException>()),
    );
    expect(await pngs(outside.root), hasLength(1));
  });

  test(
    'linked date folders and linked installation ancestors are not traversed',
    () async {
      final outside = DesktopOutputStore(
        Directory(p.join(fixture.path, 'foreign')),
      );
      final foreign = await outside.save(result('private'));
      await old.root.create(recursive: true);
      await linkDirectory(
        p.join(old.root.path, p.basename(foreign.parent.path)),
        foreign.parent,
      );
      expect((await current.migrateLegacy()).migrated, 0);
      expect(await foreign.exists(), isTrue);
      await linkDirectory(program.path, outside.root);
      await expectLater(
        current.save(result('new')),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await Directory(p.join(outside.root.path, 'output')).exists(),
        isFalse,
      );
    },
  );

  test(
    'rootOverride stays isolated and Windows production keeps gallery in support',
    () async {
      final isolated = await AppStores.open(
        rootOverride: support,
        executablePath: p.join(program.path, 'Plana.exe'),
      );
      expect(
        outputPathKey(isolated.desktopOutput.root.path),
        outputPathKey(fallback.root.path),
      );
      expect(isolated.desktopOutput.legacyRoots, isEmpty);
      await isolated.gallery.idle;
      if (!Platform.isWindows) return;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => switch (call.method) {
          'getApplicationSupportDirectory' => support.path,
          'getApplicationDocumentsDirectory' => documents.path,
          _ => null,
        },
      );
      try {
        final application = await AppStores.open(
          executablePath: p.join(program.path, 'Plana.exe'),
        );
        expect(
          outputPathKey(application.desktopOutput.root.path),
          outputPathKey(current.root.path),
        );
        expect(
          application.desktopOutput.legacyRoots
              .map((root) => outputPathKey(root.path))
              .toSet(),
          {
            outputPathKey(old.root.path),
            outputPathKey(fallback.root.path),
            outputPathKey(p.join(program.path, '作品')),
          },
        );
        expect(
          await Directory(p.join(support.path, 'gallery')).exists(),
          isTrue,
        );
        expect(await current.root.exists(), isFalse);
        await application.gallery.idle;
      } finally {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    },
  );

  test(
    'source upgrade migrates exe works without a previous registry',
    () async {
      if (!Platform.isWindows) return;
      await sourceMarkers(program);
      final executable = p.join(
        program.path,
        'build',
        'windows',
        'x64',
        'runner',
        'Release',
        'Plana.exe',
      );
      final previous = DesktopOutputStore(
        legacyExecutableWorksDirectory(executablePath: executable),
      );
      final source = await previous.save(result('windows33'));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => switch (call.method) {
          'getApplicationSupportDirectory' => support.path,
          'getApplicationDocumentsDirectory' => documents.path,
          _ => null,
        },
      );
      try {
        final application = await AppStores.open(executablePath: executable);
        expect(
          application.desktopOutput.root.path,
          p.join(program.path, 'output'),
        );
        final report = await application.desktopOutput.migrateLegacy();
        expect(report.issues, isEmpty);
        expect(report.migrated, 1);
        expect(await source.exists(), isFalse);
        final migrated = (await pngs(application.desktopOutput.root)).single;
        expect(await migrated.readAsBytes(), [1, 2, 3]);
        expect(await sidecar(migrated).exists(), isTrue);
        expect(
          await application.desktopOutput.deleteResults([result('windows33')]),
          {'windows33'},
        );
        expect(await migrated.exists(), isFalse);
        await application.gallery.idle;
      } finally {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    },
  );

  test(
    'moving the executable remembers prior works and preserves gallery history',
    () async {
      final previousRoot = Directory(
        p.join(fixture.path, 'previous-program', '作品'),
      );
      final previous = DesktopOutputStore(previousRoot);
      final history = result('history');
      final source = await previous.save(history);
      final registration = await registerDesktopWorksRoot(
        support,
        previousRoot,
      );
      expect(registration.issues, isEmpty);
      final initial = await AppStores.open(rootOverride: support);
      await initial.gallery.persistResult(history);
      initial.gallery.scheduleIndex(
        results: [history],
        selectedId: history.id,
        seq: 1,
      );
      await initial.gallery.flushIndex();
      await initial.gallery.idle;
      final nextLocation = await registerDesktopWorksRoot(
        support,
        current.root,
      );
      expect(
        nextLocation.previous.map((root) => outputPathKey(root.path)),
        contains(outputPathKey(previousRoot.path)),
      );
      final moved = DesktopOutputStore(
        current.root,
        legacyRoots: nextLocation.previous,
      );
      final migrated = await moved.migrateLegacy();
      expect(migrated.migrated, 1);
      expect(migrated.issues, isEmpty);
      expect(await source.exists(), isFalse);
      final reopened = await AppStores.open(rootOverride: support);
      expect(reopened.gallery.initialResults.single.id, history.id);
      expect(reopened.gallery.initialSelectedId, history.id);
      expect(await reopened.gallery.readImage(history.id), [1, 2, 3]);
      final again = await registerDesktopWorksRoot(support, current.root);
      expect(again.previous.map((root) => outputPathKey(root.path)).toSet(), {
        outputPathKey(previousRoot.path),
        outputPathKey(current.root.path),
      });
      await reopened.gallery.idle;
      await moved.idle;
    },
  );

  test(
    'location registry rejects foreign leaves and links and retains a corrupt registry',
    () async {
      await support.create(recursive: true);
      final registry = File(p.join(support.path, 'desktop_output_roots.json'));
      final linked = Directory(p.join(fixture.path, 'linked', '作品'));
      final foreign = await Directory(p.join(fixture.path, 'foreign')).create();
      await linkDirectory(linked.path, foreign);
      await registry.writeAsString(
        jsonEncode({
          'managedBy': 'plana-output-locations',
          'version': 1,
          'roots': [
            foreign.path,
            'relative/作品',
            linked.path,
            current.root.path,
          ],
        }),
      );
      final allowed = await readDesktopWorksRoots(support);
      expect(allowed.map((root) => outputPathKey(root.path)), [
        outputPathKey(current.root.path),
      ]);
      await registry.writeAsString('{broken');
      final failed = await registerDesktopWorksRoot(support, current.root);
      expect(failed.issues, isNotEmpty);
      expect(await registry.readAsString(), '{broken');
    },
  );
}
