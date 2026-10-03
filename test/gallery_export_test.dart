import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:plana_app/core/store/blob_store.dart';
import 'package:plana_app/features/gallery/gallery_export.dart';
import 'package:plana_app/features/gallery/gallery_store.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/save_settings.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/state_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory output;
  late BlobStore blobs;
  late GalleryStore store;
  late Map<String, dynamic> template;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_gallery_export_');
    output = await Directory(p.join(root.path, 'exports')).create();
    blobs = BlobStore(root);
    store = GalleryStore(blobs, root);
    template = (await encodeGenerateState(
      GenerateState.initial().copyWith(prompt: 'cat', negativePrompt: 'bad'),
      blobs,
    )).json;
  });

  tearDown(() async {
    await store.idle;
    await root.delete(recursive: true);
  });

  Map<String, dynamic> state([void Function(Map<String, dynamic>)? change]) {
    final snapshot = jsonDecode(jsonEncode(template)) as Map<String, dynamic>;
    change?.call(snapshot);
    return snapshot;
  }

  Future<ResultImage> item(
    String id, {
    int timestamp = 100,
    int seed = 1,
    Map<String, dynamic>? snapshot,
    Map<String, dynamic>? comment,
    Uint8List? bytes,
    bool withoutImage = false,
    bool cache = true,
    ResultBadge badge = ResultBadge.none,
    bool historyCleared = false,
  }) async {
    final png = withoutImage
        ? null
        : bytes ?? _png(comment ?? _comment(seed: seed));
    if (png != null) {
      final file = store.imageFileForPreview(id);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png, flush: true);
    }
    if (snapshot != null) {
      final file = File(p.join(root.path, 'gallery', 'inputs', '$id.json'));
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'v': 1, 'state': snapshot}));
    }
    return ResultImage(
      id: id,
      width: 8,
      height: 12,
      seed: seed,
      createdAt: timestamp,
      bytes: cache ? png : null,
      hasInput: snapshot != null,
      badge: badge,
      inpaintHistoryCleared: historyCleared,
    );
  }

  Future<GalleryExportPlan> plan(
    List<ResultImage> selected,
    List<ResultImage> scope, {
    GalleryExportCleanup cleanup = GalleryExportCleanup.none,
    GalleryExportFolder folder = GalleryExportFolder.none,
    String? albumId = 'album-1',
    String name = '喵喵',
    String? directory,
  }) => prepareGalleryExport(
    selected: selected,
    albumImages: scope,
    albumId: albumId,
    albumName: name,
    options: GalleryExportOptions(
      directory: directory ?? output.path,
      folder: folder,
      cleanup: cleanup,
    ),
    store: store,
    now: DateTime(2026, 10, 2, 23, 30),
  );

  Future<GalleryExportReport> export(GalleryExportPlan value) =>
      exportGalleryImages(value, store: store, settings: const SaveSettings());

  test(
    'snapshot exports only deduplicated selected IDs inside this album',
    () async {
      final a = await item('gen1');
      final b = await item('gen2');
      final elsewhere = await item('gen3');
      final selected = [a, a, elsewhere];
      final scope = [a, b, a];
      final prepared = await plan(selected, scope);
      selected.clear();
      scope.clear();
      expect(prepared.items.map((i) => i.id), ['gen1']);
      expect(prepared.scopeIds, {'gen1', 'gen2'});
      expect(prepared.deleteIds, isEmpty);
      expect(prepared.retainedCount, 2);
      expect(() => prepared.items.clear(), throwsUnsupportedError);
      expect(() => prepared.scopeIds.clear(), throwsUnsupportedError);
      expect(() => prepared.deleteIds.clear(), throwsUnsupportedError);

      final report = await export(prepared);
      expect(report.savedIds, {'gen1'});
      expect(report.failedIds, isEmpty);
      expect(report.cleanupIds, isEmpty);
      expect(await File(report.savedPaths['gen1']!).readAsBytes(), a.bytes);
      expect((await output.list().toList()).length, 1);
      expect(await store.imageFileForPreview('gen1').exists(), isTrue);
    },
  );

  test(
    'existing exports are never overwritten and disk bytes are lazy-read',
    () async {
      final a = await item('gen1', cache: false);
      final existing = File(p.join(output.path, 'plana_gen1_1.png'));
      await existing.writeAsString('previous export');
      final prepared = await plan([a], [a]);
      final first = await export(prepared);
      final second = await export(prepared);
      expect(await existing.readAsString(), 'previous export');
      expect(p.basename(first.savedPaths[a.id]!), 'plana_gen1_1_2.png');
      expect(p.basename(second.savedPaths[a.id]!), 'plana_gen1_1_3.png');
      expect(await File(first.savedPaths[a.id]!).length(), greaterThan(0));
      expect(await File(second.savedPaths[a.id]!).length(), greaterThan(0));
      expect(
        (await output.list().toList()).where((f) => f.path.endsWith('.part')),
        isEmpty,
      );
    },
  );

  test(
    'date and album folders are children, created only when exporting',
    () async {
      final a = await item('gen1');
      final dated = await plan([a], [a], folder: GalleryExportFolder.date);
      expect(dated.directory, p.join(output.path, '2026-10-02'));
      expect(await Directory(dated.directory).exists(), isFalse);
      expect((await export(dated)).savedIds, {a.id});
      final named = await plan(
        [a],
        [a],
        folder: GalleryExportFolder.album,
        name: '喵喵 图库',
      );
      expect(named.directory, p.join(output.path, '喵喵 图库'));
      expect((await export(named)).savedIds, {a.id});
      expect((await Directory(named.directory).list().toList()).length, 1);
    },
  );

  test(
    'Windows album names cannot traverse paths or use reserved device names',
    () async {
      final a = await item('gen1');
      for (final name in [
        '../..',
        r'..\..\CON',
        'CON.txt',
        'CON .txt',
        'nul',
        'LPT1',
        ' . ',
        'a:*?"<>|b. ',
      ]) {
        final prepared = await plan(
          [a],
          [a],
          folder: GalleryExportFolder.album,
          name: name,
        );
        final child = p.basename(prepared.directory);
        expect(p.dirname(prepared.directory), output.path);
        expect(child, isNot(anyOf('', '.', '..')));
        expect(child.contains(RegExp(r'[<>:"/\\|?*]')), isFalse);
        expect(child.endsWith('.'), isFalse);
        expect(child.endsWith(' '), isFalse);
        expect(
          RegExp(
            r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
            caseSensitive: false,
          ).hasMatch(child),
          isFalse,
        );
        expect((await export(prepared)).savedIds, {a.id});
      }
    },
  );

  test(
    'system all-artworks cleanup includes unselected images but has no album to delete',
    () async {
      final a = await item('gen1');
      final b = await item('gen2');
      final prepared = await plan(
        [a],
        [a, b],
        cleanup: GalleryExportCleanup.deleteAlbum,
        albumId: null,
      );
      expect(prepared.albumId, isNull);
      expect(prepared.items.map((image) => image.id), [a.id]);
      expect(prepared.deleteIds, {a.id, b.id});
      final report = await export(prepared);
      expect(report.savedIds, {a.id});
      expect(report.cleanupIds, {a.id, b.id});
    },
  );

  test(
    'keepSamples ignores seed and UI state, retaining newest in entire scope',
    () async {
      final older = await item(
        'gen8',
        timestamp: 100,
        snapshot: state((s) {
          s['params']['seed'] = '11';
          s['params']['loop'] = 'x8';
          s['params']['modalMem'] = {
            'unrelated': {'steps': 50},
          };
          s['promptRaw'] = 'old editor draft';
          s['anlas'] = 200;
          s['openPanels'] = ['img2img'];
        }),
        seed: 11,
      );
      final newest = await item(
        'gen7',
        timestamp: 200,
        snapshot: state((s) {
          s['params']['seed'] = '22';
          s['params']['loop'] = 'x1';
          s['negativePromptRaw'] = 'other draft';
          s['openPanels'] = ['vibe'];
        }),
        seed: 22,
      );
      final earlier = await item(
        'gen9',
        timestamp: 50,
        snapshot: state(),
        seed: 33,
      );
      final revision = blobs.referenceRevision;
      final prepared = await plan(
        [older],
        [older, newest, earlier],
        cleanup: GalleryExportCleanup.keepSamples,
      );
      expect(prepared.deleteIds, {older.id, earlier.id});
      expect(prepared.retainedCount, 1);
      expect(prepared.unknownCount, 0);
      expect(blobs.referenceRevision, revision);
      expect(await Directory(p.join(root.path, 'blobs')).exists(), isFalse);
      final report = await export(prepared);
      expect(report.savedIds, {older.id});
      expect(report.cleanupIds, {older.id, earlier.id});
      // The service only returns a plan; it must never delete gallery files.
      for (final image in [older, newest, earlier]) {
        expect(await store.imageFileForPreview(image.id).exists(), isTrue);
      }
    },
  );

  test('equal timestamps use generation sequence as the tie-breaker', () async {
    final low = await item('gen9', snapshot: state());
    final high = await item('gen10', snapshot: state());
    final prepared = await plan(
      [low],
      [low, high],
      cleanup: GalleryExportCleanup.keepSamples,
    );
    expect(prepared.deleteIds, {low.id});
  });

  test(
    'effective presets, negatives, order, weights, model and dimensions stay distinct',
    () async {
      final images = <ResultImage>[
        await item('gen0', snapshot: state()),
        await item(
          'gen1',
          snapshot: state(),
          comment: _comment(prompt: 'cat, masterpiece'),
        ),
        await item(
          'gen2',
          snapshot: state(),
          comment: _comment(negative: 'bad, blurry'),
        ),
        await item(
          'gen3',
          snapshot: state((s) => s['prompt'] = 'cat, dog'),
          comment: _comment(prompt: 'cat, dog'),
        ),
        await item(
          'gen4',
          snapshot: state((s) => s['prompt'] = 'dog, cat'),
          comment: _comment(prompt: 'dog, cat'),
        ),
        await item(
          'gen5',
          snapshot: state((s) => s['prompt'] = '1.2::cat::'),
          comment: _comment(prompt: '1.2::cat::'),
        ),
        await item(
          'gen6',
          snapshot: state((s) => s['params']['model'] = 'NAI 4.5 Curated'),
        ),
        await item('gen7', snapshot: state((s) => s['params']['width'] = 1024)),
        await item('gen8', snapshot: state((s) => s['params']['steps'] = 32)),
        await item(
          'gen9',
          snapshot: state((s) => s['negativePrompt'] = '2::bad::'),
        ),
      ];
      final prepared = await plan(
        [images.first],
        images,
        cleanup: GalleryExportCleanup.keepSamples,
      );
      expect(prepared.deleteIds, isEmpty);
      expect(prepared.retainedCount, images.length);
      expect(prepared.unknownCount, 0);
    },
  );

  test(
    'reference hashes and weights matter while list IDs, names and caches do not',
    () async {
      Map<String, dynamic> reference(
        String hash,
        double weight,
        String nickname,
      ) => state((s) {
        s['vibes'] = [
          {
            'id': nickname,
            'name': nickname,
            'sourceId': nickname,
            'enabled': true,
            'image': hash,
            'strength': weight,
            'infoExtracted': 1.0,
            'encodedByModel': {'NAI 4.5 Full': nickname},
          },
        ];
      });
      final hashA = List.filled(64, 'a').join();
      final hashB = List.filled(64, 'b').join();
      final old = await item(
        'gen0',
        snapshot: reference(hashA, .6, '旧名'),
        timestamp: 10,
      );
      final same = await item(
        'gen1',
        snapshot: reference(hashA, .6, '新名'),
        timestamp: 20,
      );
      final differentHash = await item(
        'gen2',
        snapshot: reference(hashB, .6, '新名'),
      );
      final differentWeight = await item(
        'gen3',
        snapshot: reference(hashA, .8, '新名'),
      );
      final prepared = await plan(
        [old],
        [old, same, differentHash, differentWeight],
        cleanup: GalleryExportCleanup.keepSamples,
      );
      expect(prepared.deleteIds, {old.id});
      expect(prepared.retainedCount, 3);
      expect(prepared.unknownCount, 0);
    },
  );

  test(
    'character content and position and img2img/inpaint masks remain distinct',
    () async {
      final hashA = List.filled(64, 'a').join();
      final hashB = List.filled(64, 'b').join();
      final images = <ResultImage>[
        for (final position in ['A1', 'C3'])
          await item(
            'character-$position',
            snapshot: state((s) {
              s['characters'] = [
                {
                  'id': position,
                  'name': '人物',
                  'enabled': true,
                  'positive': 'girl',
                  'negative': 'hat',
                  'position': position,
                  'activeTab': 'positive',
                },
              ];
            }),
          ),
        for (final hash in [hashA, hashB])
          await item(
            'img2img-${hash[0]}',
            snapshot: state((s) {
              s['img2img'] = {'image': hash, 'strength': .7, 'noise': .1};
            }),
          ),
        for (final hash in [hashA, hashB])
          await item(
            'mask-${hash[0]}',
            badge: ResultBadge.inpaint,
            snapshot: state((s) {
              s['inpaint'] = {'image': hashA, 'mask': hash, 'strength': .7};
            }),
          ),
      ];
      final prepared = await plan(
        [images.first],
        images,
        cleanup: GalleryExportCleanup.keepSamples,
      );
      expect(prepared.deleteIds, isEmpty);
      expect(prepared.unknownCount, 0);
    },
  );

  test(
    'missing snapshots, incomplete metadata and cleared history are each retained',
    () async {
      final incomplete = state()..remove('negativePrompt');
      final images = <ResultImage>[
        await item('known-old', snapshot: state(), timestamp: 10),
        await item('known-new', snapshot: state(), timestamp: 20),
        await item('no-snapshot-1'),
        await item('no-snapshot-2'),
        await item('incomplete-1', snapshot: incomplete),
        await item('incomplete-2', snapshot: incomplete),
        await item('no-comment-1', snapshot: state(), bytes: _png(null)),
        await item('no-comment-2', snapshot: state(), bytes: _png(null)),
        await item(
          'no-negative',
          snapshot: state(),
          comment: _comment()..remove('uc'),
        ),
        await item(
          'cleared-1',
          snapshot: state(),
          badge: ResultBadge.inpaint,
          historyCleared: true,
        ),
        await item(
          'cleared-2',
          snapshot: state(),
          badge: ResultBadge.inpaint,
          historyCleared: true,
        ),
        await item(
          'missing-mask',
          snapshot: state(),
          badge: ResultBadge.inpaint,
        ),
        await item(
          'missing-paste',
          snapshot: state((s) {
            s['inpaint'] = {
              'image': List.filled(64, 'a').join(),
              'mask': List.filled(64, 'b').join(),
              'strength': .7,
              'paste': {'sendX': 0},
            };
          }),
        ),
      ];
      final prepared = await plan(
        [images.first],
        images,
        cleanup: GalleryExportCleanup.keepSamples,
      );
      expect(prepared.deleteIds, {'known-old'});
      expect(prepared.unknownCount, 11);
      expect(prepared.retainedCount, 12);
    },
  );

  test('raw cleared-history marker protects a stale result copy', () async {
    final a = await item('gen1', snapshot: state());
    final b = await item('gen2', snapshot: state());
    final file = File(p.join(root.path, 'gallery', 'inputs', '${a.id}.json'));
    await file.writeAsString(
      jsonEncode({'v': 1, 'state': state(), 'inpaintHistoryCleared': true}),
    );
    final prepared = await plan(
      [a],
      [a, b],
      cleanup: GalleryExportCleanup.keepSamples,
    );
    expect(prepared.unknownCount, 1);
    expect(prepared.deleteIds, isEmpty);
    expect(prepared.retainedCount, 2);
  });

  test(
    'v4 captions and compressed PNG text are read without decoding pixels',
    () async {
      final comment = _comment()
        ..remove('prompt')
        ..remove('uc')
        ..['v4_prompt'] = {
          'caption': {'base_caption': 'cat', 'char_captions': []},
        }
        ..['v4_negative_prompt'] = {
          'caption': {'base_caption': 'bad', 'char_captions': []},
        };
      final a = await item(
        'gen1',
        snapshot: state(),
        bytes: _png(comment),
        timestamp: 10,
      );
      final b = await item(
        'gen2',
        snapshot: state(),
        bytes: _png(comment, compressed: true),
        timestamp: 20,
      );
      final prepared = await plan(
        [a],
        [a, b],
        cleanup: GalleryExportCleanup.keepSamples,
      );
      expect(prepared.deleteIds, {a.id});
      expect(prepared.unknownCount, 0);
    },
  );

  test(
    'deleteAlbum cleanup covers unselected scope only after all selected exports succeed',
    () async {
      final selected = await item('gen1');
      final unselected = await item('gen2');
      final elsewhere = await item('gen3');
      final prepared = await plan(
        [selected],
        [selected, unselected],
        cleanup: GalleryExportCleanup.deleteAlbum,
      );
      expect(prepared.deleteIds, {selected.id, unselected.id});
      final report = await export(prepared);
      expect(report.savedIds, {selected.id});
      expect(report.cleanupIds, {selected.id, unselected.id});
      expect(report.cleanupIds, isNot(contains(elsewhere.id)));
      expect((await output.list().toList()).length, 1);
      expect(await store.imageFileForPreview(unselected.id).exists(), isTrue);
    },
  );

  test(
    'partial failure only permits successful selected cleanup, never whole-scope cleanup',
    () async {
      final success = await item('gen1', snapshot: state(), timestamp: 10);
      final missing = await item('gen2', withoutImage: true);
      final latest = await item('gen3', snapshot: state(), timestamp: 20);
      for (final cleanup in [
        GalleryExportCleanup.selected,
        GalleryExportCleanup.keepSamples,
        GalleryExportCleanup.deleteAlbum,
      ]) {
        final prepared = await plan(
          [success, missing],
          [success, missing, latest],
          cleanup: cleanup,
        );
        final report = await export(prepared);
        expect(report.savedIds, {success.id});
        expect(report.failedIds, {missing.id});
        expect(report.errors[missing.id], contains('缺失'));
        expect(report.canceled, isFalse);
        expect(
          report.cleanupIds,
          cleanup == GalleryExportCleanup.selected ? {success.id} : isEmpty,
        );
      }
    },
  );

  test(
    'empty image files and missing destinations cannot authorize cleanup',
    () async {
      final empty = await item('gen1', bytes: Uint8List(0));
      final prepared = await plan(
        [empty],
        [empty],
        cleanup: GalleryExportCleanup.deleteAlbum,
      );
      final report = await export(prepared);
      expect(report.savedIds, isEmpty);
      expect(report.failedIds, {empty.id});
      expect(report.cleanupIds, isEmpty);
      final valid = await item('gen2');
      final invalidDestination = await plan(
        [valid],
        [valid],
        directory: p.join(root.path, 'does-not-exist'),
        cleanup: GalleryExportCleanup.selected,
      );
      final failed = await export(invalidDestination);
      expect(failed.failedIds, {valid.id});
      expect(failed.cleanupIds, isEmpty);
      expect(await Directory(invalidDestination.directory).exists(), isFalse);
    },
  );

  test('cancel after saving one image suppresses every cleanup mode', () async {
    final a = await item('gen1', snapshot: state(), timestamp: 10);
    final b = await item('gen2', snapshot: state(), timestamp: 20);
    for (final cleanup in GalleryExportCleanup.values) {
      final prepared = await plan([a, b], [a, b], cleanup: cleanup);
      var stop = false;
      final progress = <(int, int)>[];
      final report = await exportGalleryImages(
        prepared,
        store: store,
        settings: const SaveSettings(),
        canceled: () => stop,
        onProgress: (done, total) {
          progress.add((done, total));
          stop = true;
        },
      );
      expect(report.canceled, isTrue);
      expect(report.savedIds, {a.id});
      expect(report.failedIds, isEmpty);
      expect(report.cleanupIds, isEmpty);
      expect(progress, [(1, 2)]);
    }
  });

  test(
    'cancel on the last success still suppresses cleanup and empty selection does not delete',
    () async {
      final a = await item('gen1');
      final prepared = await plan(
        [a],
        [a],
        cleanup: GalleryExportCleanup.deleteAlbum,
      );
      var stop = false;
      final report = await exportGalleryImages(
        prepared,
        store: store,
        settings: const SaveSettings(),
        canceled: () => stop,
        onProgress: (_, _) => stop = true,
      );
      expect(report.savedIds, {a.id});
      expect(report.canceled, isTrue);
      expect(report.cleanupIds, isEmpty);
      final empty = await plan([], [
        a,
      ], cleanup: GalleryExportCleanup.deleteAlbum);
      expect((await export(empty)).cleanupIds, isEmpty);
    },
  );

  test(
    'cancel before export creates no dated folder and writes nothing',
    () async {
      final a = await item('gen1');
      final prepared = await plan(
        [a],
        [a],
        folder: GalleryExportFolder.date,
        cleanup: GalleryExportCleanup.deleteAlbum,
      );
      final report = await exportGalleryImages(
        prepared,
        store: store,
        settings: const SaveSettings(),
        canceled: () => true,
      );
      expect(report.canceled, isTrue);
      expect(report.savedIds, isEmpty);
      expect(report.failedIds, isEmpty);
      expect(report.cleanupIds, isEmpty);
      expect(await Directory(prepared.directory).exists(), isFalse);
    },
  );

  test(
    'cancel during preparation stops before reading more image data',
    () async {
      final a = await item('gen1', snapshot: state(), cache: false);
      final b = await item('gen2', snapshot: state(), cache: false);
      var stop = false;
      final watched = _WatchingGalleryStore(blobs, root, () => stop = true);
      await expectLater(
        prepareGalleryExport(
          selected: [a],
          albumImages: [a, b],
          albumId: 'album-1',
          albumName: '喵喵',
          options: GalleryExportOptions(
            directory: output.path,
            cleanup: GalleryExportCleanup.keepSamples,
          ),
          store: watched,
          canceled: () => stop,
        ),
        throwsA(isA<GalleryExportCanceled>()),
      );
      expect(watched.snapshotReads, 1);
      expect(watched.imageReads, 0);
      expect(await output.list().toList(), isEmpty);
      expect(await store.imageFileForPreview(a.id).exists(), isTrue);
      expect(await store.imageFileForPreview(b.id).exists(), isTrue);
    },
  );
}

class _WatchingGalleryStore extends GalleryStore {
  _WatchingGalleryStore(super.blobs, super.root, this.onSnapshotRead);

  final void Function() onSnapshotRead;
  int snapshotReads = 0;
  int imageReads = 0;

  @override
  Future<Map<String, dynamic>?> readInputRaw(String id) async {
    snapshotReads++;
    final value = await super.readInputRaw(id);
    onSnapshotRead();
    return value;
  }

  @override
  Future<Uint8List?> readImage(String id) {
    imageReads++;
    return super.readImage(id);
  }
}

Map<String, dynamic> _comment({
  int seed = 1,
  String prompt = 'cat',
  String negative = 'bad',
}) => {
  'prompt': prompt,
  'uc': negative,
  'seed': seed,
  'extra_noise_seed': seed,
  'width': 8,
  'height': 12,
  'steps': 28,
  'scale': 5.0,
  'sampler': 'k_euler_ancestral',
  'noise_schedule': 'karras',
};

Uint8List _png(Map<String, dynamic>? comment, {bool compressed = false}) {
  final png = Uint8List.fromList(
    img.encodePng(img.Image(width: 8, height: 12)),
  );
  if (comment == null) return png;
  final text = utf8.encode(jsonEncode(comment));
  final body = <int>[
    ...ascii.encode('Comment'),
    0,
    compressed ? 1 : 0,
    0,
    0,
    0,
    ...(compressed ? ZLibEncoder().convert(text) : text),
  ];
  final typeAndData = Uint8List.fromList([...ascii.encode('iTXt'), ...body]);
  return (BytesBuilder(copy: false)
        ..add(png.sublist(0, png.length - 12))
        ..add((ByteData(4)..setUint32(0, body.length)).buffer.asUint8List())
        ..add(typeAndData)
        ..add(
          (ByteData(
            4,
          )..setUint32(0, getCrc32(typeAndData))).buffer.asUint8List(),
        )
        ..add(png.sublist(png.length - 12)))
      .takeBytes();
}
