import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/inpaint_history_cleanup.dart';
import 'package:plana_app/features/generate/canvas_models.dart';
import 'package:plana_app/features/generate/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('plana_history_safety_');
    stores = await AppStores.open(rootOverride: root);
  });
  tearDown(() async {
    try {
      await stores.flushForExit();
    } catch (_) {}
    await root.delete(recursive: true);
  });
  CanvasPrompts content(String text) => CanvasPrompts.of(
    GenerateState.initial().copyWith(
      prompt: text,
      vibes: [
        VibeItem(id: 'v1', image: Uint8List.fromList([1, 2, 3])),
      ],
      params: const GenParams(model: 'NAI 5.0 Full', naiEffort: NaiEffort.high),
    ),
  );

  test(
    'one damaged history does not stop another canvas from being saved',
    () async {
      final file = File('${root.path}/workspace/history/broken.json');
      await file.parent.create(recursive: true);
      await file.writeAsString('{broken');
      await expectLater(
        stores.history.record('broken', content('recover later'), ['r1']),
        throwsFormatException,
      );
      try {
        await stores.history.record('healthy', content('safe'), ['r2']);
      } catch (_) {}
      final again = await AppStores.open(rootOverride: root);
      expect(
        (await again.history.load('healthy')).single.preview.prompt,
        'safe',
      );
      await file.writeAsString('{"v":1,"entries":[]}');
      await stores.flushForExit();
    },
  );

  test(
    'history write failure retains newest snapshot and protects image until exit retry',
    () async {
      final dir = Directory('${root.path}/workspace/history');
      await dir.create(recursive: true);
      final blocker = Directory('${dir.path}/canvas1.json');
      await blocker.create();
      await expectLater(
        stores.history.record('canvas1', content('rain'), ['r1']),
        throwsA(isA<FileSystemException>()),
      );
      expect(stores.saveError.value, contains('画布历史'));
      expect(
        (await stores.history.load('canvas1')).single.preview.prompt,
        'rain',
      );
      final refs = await stores.history.liveRefs();
      expect(refs, hasLength(1));
      await expectLater(
        stores.flushForExit(),
        throwsA(isA<FileSystemException>()),
      );
      await blocker.delete();
      await stores.flushForExit();
      final again = await AppStores.open(rootOverride: root);
      final entry = (await again.history.load('canvas1')).single;
      expect(entry.preview.prompt, 'rain');
      final decoded = await again.workspace.decodeCanvas(
        entry.json,
        requiredRefs: entry.refs,
      );
      expect(decoded.vibes.single.image, [1, 2, 3]);
      expect(decoded.sampling!.naiEffort, NaiEffort.high);
    },
  );

  test(
    'failed blob encode keeps pending content for retry without duplicate results',
    () async {
      final blobs = Directory('${root.path}/blobs');
      await blobs.delete();
      final blocker = File(blobs.path);
      await blocker.writeAsString('blocked');
      await expectLater(
        stores.history.record('a', content('first'), ['r1']),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        stores.history.liveRefs(),
        throwsA(isA<FileSystemException>()),
      );
      await blocker.delete();
      await stores.flushForExit();
      await stores.history.record('a', content('first'), ['r2']);
      final list = await stores.history.load('a');
      expect(list, hasLength(1));
      expect(list.single.resultIds, ['r2', 'r1']);
    },
  );

  test(
    'unreadable history blocks cleanup and is never replaced by an empty file',
    () async {
      final file = File('${root.path}/workspace/history/a.json');
      await file.parent.create(recursive: true);
      await file.writeAsString('{broken');
      await expectLater(stores.history.load('a'), throwsFormatException);
      await expectLater(
        stores.history.record('a', content('new'), ['r']),
        throwsFormatException,
      );
      await expectLater(
        InpaintHistoryCleanup.forStores(stores).clear(),
        throwsFormatException,
      );
      expect(await file.readAsString(), '{broken');
      await file.writeAsString('{"v":1,"entries":[]}');
      await stores.flushForExit();
      expect((await stores.history.load('a')).single.preview.prompt, 'new');
    },
  );

  test(
    'unknown future content hashes are protected even if absent from refs',
    () async {
      final hash = await stores.blobs.put(Uint8List.fromList([7, 8]));
      final file = File('${root.path}/workspace/history/a.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'v': 1,
          'entries': [
            {
              'id': 'h1',
              'content': {
                'futureModule': {'image': hash},
              },
              'refs': [],
            },
          ],
        }),
      );
      expect(await stores.history.liveRefs(), contains(hash));
      expect((await stores.history.load('a')).single.refs, contains(hash));
    },
  );

  test(
    'canvas ids cannot escape the history directory and round trip safely',
    () async {
      const id = '../other\\canvas:1';
      await stores.history.record(id, content('safe'), ['r']);
      final again = await AppStores.open(rootOverride: root);
      expect((await again.history.load(id)).single.preview.prompt, 'safe');
      expect(await File('${root.path}/workspace/other.json').exists(), isFalse);
      expect(
        await Directory('${root.path}/workspace/history').list().length,
        1,
      );
    },
  );

  test(
    'missing history asset refuses restoration rather than dropping the reference',
    () async {
      await stores.history.record('a', content('asset'), ['r']);
      final entry = (await stores.history.load('a')).single;
      await File('${root.path}/blobs/${entry.refs.single}.bin').delete();
      await expectLater(
        stores.workspace.decodeCanvas(entry.json, requiredRefs: entry.refs),
        throwsStateError,
      );
    },
  );
}
