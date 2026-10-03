import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/blob_store.dart';
import 'package:plana_app/core/store/inpaint_history_cleanup.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/gallery_store.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';
import 'package:plana_app/features/generate/gen_jobs.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/inpaint/inpaint_ops.dart';
import 'package:plana_app/features/profile/storage_page.dart';

Uint8List _png(int side, int red, int green, int blue) => Uint8List.fromList(
  img.encodePng(
    img.fill(
      img.Image(width: side, height: side),
      color: img.ColorRgb8(red, green, blue),
    ),
  ),
);

class _PausedGallery extends GalleryStore {
  _PausedGallery(super.blobs, super.root);
  final detached = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<InpaintHistoryRemoval> clearInpaintHistory() async {
    final result = await super.clearInpaintHistory();
    detached.complete();
    await resume.future;
    return result;
  }
}

class _SavingGeneration extends GenerationNotifier {
  @override
  GenPool build() => const GenPool(
    jobs: [
      GenJob(
        id: 'saving',
        kind: GenJobKind.inpaint,
        stage: GenJobStage.saving,
        width: 128,
        height: 128,
        seq: 0,
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late InpaintHistoryCleanup cleanup;
  late InpaintJob job;
  late Uint8List finished;
  late GenerateState input;
  var widgetOwnsStoreCleanup = false;

  setUp(() async {
    widgetOwnsStoreCleanup = false;
    root = await Directory.systemTemp.createTemp('plana_inpaint_cleanup_');
    stores = await AppStores.open(rootOverride: root);
    cleanup = InpaintHistoryCleanup.forStores(stores);
    final grid = MaskGrid(128, 128)..paintDot(44, 44, 8);
    final effective = MaskGrid(128, 128)
      ..fillRegion((x: 32, y: 32, w: 64, h: 64));
    job = InpaintJob(
      image: _png(64, 255, 80, 0),
      mask: _png(64, 255, 255, 255),
      strength: .83,
      sourceId: 'original-result',
      grid: grid.encode(),
      paste: InpaintPaste(
        original: _png(128, 255, 0, 0),
        sendX: 0,
        sendY: 0,
        tightX: 32,
        tightY: 32,
        tightW: 64,
        tightH: 64,
        outW: 128,
        outH: 128,
        focus: const InpaintFocus(x: 0, y: 0, width: 128, height: 128),
        focusMask: effective.encode(),
      ),
    );
    finished = _png(128, 0, 0, 255);
    input = GenerateState.initial().copyWith(
      prompt: '1girl, cat ears',
      negativePrompt: 'bad hands',
      characters: const [
        CharacterPrompt(id: 'cat', name: 'Cat', positive: 'pink hair'),
      ],
      params: GenerateState.initial().params.copyWith(
        seed: '4321',
        steps: 31,
        width: 1024,
        height: 1024,
      ),
      inpaint: job,
    );
  });

  tearDown(() async {
    // Futures created by a widget's FakeAsync zone dispatch late listeners in
    // that same zone, even after completion. Drain those inside the widget body.
    if (!widgetOwnsStoreCleanup) {
      stores.flushNow();
      await Future.wait([
        stores.gallery.idle,
        stores.workspace.idle,
        stores.assistant.idle,
      ]);
    }
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<ResultImage> save(
    String id, {
    GenerateState? state,
    ResultBadge badge = ResultBadge.inpaint,
  }) async {
    final result = ResultImage(
      id: id,
      width: 128,
      height: 128,
      seed: 4321,
      createdAt: 1000,
      badge: badge,
      bytes: finished,
      input: state ?? input,
      inpaintFrom: badge == ResultBadge.inpaint ? 'original-result' : null,
    );
    await stores.gallery.persistResult(result);
    stores.gallery.scheduleIndex(
      results: [result, ...stores.gallery.initialResults],
      selectedId: id,
      seq: 10,
    );
    await stores.gallery.flushIndex();
    return result;
  }

  Future<Set<String>> jobRefs() async => {
    for (final bytes in [
      job.image,
      job.mask,
      job.grid!,
      job.paste!.original,
      job.paste!.focusMask!,
    ])
      await stores.blobs.hashOf(bytes),
  };

  test(
    'counts shared history blobs once and retains finished images and ordinary parameters',
    () async {
      await save('gen1');
      await save('gen2');
      final originalFile = File(
        '${root.path}/gallery/images/original-result.png',
      );
      await originalFile.writeAsBytes(job.paste!.original);
      final unrelated = await stores.blobs.put(
        Uint8List.fromList([9, 8, 7, 6]),
      );
      final refs = await jobRefs();
      final expectedBytes = [
        job.image,
        job.mask,
        job.grid!,
        job.paste!.original,
        job.paste!.focusMask!,
      ].fold<int>(0, (sum, bytes) => sum + bytes.length);
      final before = await stores.gallery.readInputRaw('gen1');
      final usage = await cleanup.scan();
      expect(usage.count, 2);
      expect(usage.releasableBytes, expectedBytes);

      final result = await cleanup.clear();
      expect(result.clearedIds, {'gen1', 'gen2'});
      expect(result.releasedBytes, expectedBytes);
      expect(result.failedIds, isEmpty);
      for (final hash in refs) {
        expect(await stores.blobs.get(hash), isNull);
      }
      expect(await stores.blobs.get(unrelated), [9, 8, 7, 6]);
      expect(await stores.gallery.readImage('gen1'), finished);
      expect(await stores.gallery.readThumb('gen1'), isNotNull);
      expect(await originalFile.readAsBytes(), job.paste!.original);
      final after = (await stores.gallery.readInputRaw('gen1'))!;
      final ordinary = Map<String, dynamic>.from(before!['state'] as Map)
        ..remove('inpaint');
      expect(after['state'], ordinary);
      expect(after['refs'], isEmpty);
      expect(after['inpaintHistoryCleared'], isTrue);
      final restored = (await stores.gallery.readInput('gen1'))!;
      expect(restored.inpaint, isNull);
      expect(restored.prompt, input.prompt);
      expect(restored.negativePrompt, input.negativePrompt);
      expect(restored.params.seed, '4321');
      expect(restored.params.steps, 31);
      expect(restored.characters.single.positive, 'pink hair');
      final reopened = await AppStores.open(rootOverride: root);
      expect(
        reopened.gallery.initialResults
            .where((r) => r.id.startsWith('gen'))
            .every(
              (r) =>
                  r.badge == ResultBadge.inpaint &&
                  r.inpaintHistoryCleared &&
                  !r.hasInpaintComparison &&
                  r.hasInput,
            ),
        isTrue,
      );
      expect((await cleanup.scan()).count, 0);
      expect((await cleanup.clear()).releasedBytes, 0);
      reopened.flushNow();
      await reopened.gallery.idle;
    },
  );

  test(
    'pending workspace keeps its original, editable grid, mask and focus metadata intact',
    () async {
      await save('gen1');
      stores.workspace.schedule(input, idSeq: 123);
      final usage = await cleanup.scan();
      expect(usage.count, 1);
      expect(usage.releasableBytes, 0);
      final result = await cleanup.clear();
      expect(result.releasedBytes, 0);
      for (final hash in await jobRefs()) {
        expect(await stores.blobs.get(hash), isNotNull);
      }
      final reopened = await AppStores.open(rootOverride: root);
      expect(reopened.workspace.initial!.inpaint!.grid, job.grid);
      expect(
        reopened.workspace.initial!.inpaint!.paste!.original,
        job.paste!.original,
      );
      expect(reopened.workspace.initial!.inpaint!.paste!.focus!.context, 32);
      expect(reopened.workspace.initial!.inpaint!.strength, .83);
      expect((await reopened.gallery.readInput('gen1'))!.inpaint, isNull);
    },
  );

  test(
    'same snapshot, other history, workspace and assistant sharing protect their blobs',
    () async {
      await save(
        'gen1',
        state: input.copyWith(
          vibes: [VibeItem(id: 'v', image: job.mask)],
        ),
      );
      await save(
        'gen2',
        badge: ResultBadge.none,
        state: input.copyWith(
          inpaint: null,
          img2img: Img2ImgConfig(image: job.paste!.original),
        ),
      );
      stores.workspace.schedule(
        GenerateState.initial().copyWith(
          img2img: Img2ImgConfig(image: job.image),
        ),
        idSeq: 1,
      );
      final assistantImage = await stores.assistant.putImage(job.mask);
      stores.assistant.schedule([
        AssistantMsg(
          id: 'a',
          role: MsgRole.user,
          text: 'keep',
          at: 1,
          imageHash: assistantImage,
        ),
      ], []);
      final expected = job.grid!.length + job.paste!.focusMask!.length;
      expect((await cleanup.scan()).releasableBytes, expected);
      expect((await cleanup.clear()).releasedBytes, expected);
      expect(
        (await stores.gallery.readInput('gen1'))!.vibes.single.image,
        job.mask,
      );
      expect(
        (await stores.gallery.readInput('gen2'))!.img2img!.image,
        job.paste!.original,
      );
      expect(await stores.assistant.image(assistantImage), job.mask);
      expect(
        await stores.blobs.get(await stores.blobs.hashOf(job.image)),
        job.image,
      );
      expect(
        BlobStore.referencedHashes(await stores.gallery.readInputRaw('gen1')),
        contains(await stores.blobs.hashOf(job.mask)),
      );
    },
  );

  test(
    'legacy comparison links with no inpaint blobs can be cleared at zero bytes',
    () async {
      await save('gen1', state: input.copyWith(inpaint: null));
      expect((await cleanup.scan()).releasableBytes, 0);
      expect((await cleanup.scan()).count, 1);
      await cleanup.clear();
      final reopened = await AppStores.open(rootOverride: root);
      final result = reopened.gallery.initialResults.single;
      expect(result.inpaintFrom, isNull);
      expect(result.inpaintHistoryCleared, isTrue);
      expect(result.hasInpaintComparison, isFalse);
      expect((await reopened.gallery.readInput('gen1'))!.prompt, input.prompt);
    },
  );

  for (final malformedPath in [
    'workspace/state.json',
    'gallery/inputs/broken.json',
  ]) {
    test('unreadable $malformedPath stops before removing data', () async {
      await save('gen1');
      final file = File('${root.path}/$malformedPath');
      await file.parent.create(recursive: true);
      await file.writeAsString('{not valid json');
      await expectLater(cleanup.scan(), throwsFormatException);
      await expectLater(cleanup.clear(), throwsFormatException);
      expect(
        (await stores.gallery.readInputRaw('gen1'))!['state']['inpaint'],
        isNotNull,
      );
      for (final hash in await jobRefs()) {
        expect(await stores.blobs.get(hash), isNotNull);
      }
    });
  }

  test(
    'a workspace reference added during cleanup prevents reclamation and survives flush',
    () async {
      await save('gen1');
      final paused = _PausedGallery(stores.blobs, root);
      await paused.load();
      final service = InpaintHistoryCleanup(
        blobs: stores.blobs,
        gallery: paused,
        workspace: stores.workspace,
        assistant: stores.assistant,
      );
      final pending = service.clear();
      await paused.detached.future;
      stores.workspace.schedule(input, idSeq: 3);
      paused.resume.complete();
      final result = await pending;
      expect(result.reclamationDeferred, isTrue);
      expect(result.releasedBytes, 0);
      for (final hash in await jobRefs()) {
        expect(await stores.blobs.get(hash), isNotNull);
      }
      stores.workspace.flush();
      await stores.workspace.idle;
      final reopened = await AppStores.open(rootOverride: root);
      expect(
        reopened.workspace.initial!.inpaint!.paste!.focusMask,
        job.paste!.focusMask,
      );
    },
  );

  test(
    'a concurrent shared blob put invalidates a detached-file deletion plan',
    () async {
      final hash = await stores.blobs.put(job.image);
      final revision = stores.blobs.referenceRevision;
      final pending = stores.blobs.put(job.image);
      expect(
        await stores.blobs.removeDetachedHashes(
          {hash},
          {},
          expectedRevision: revision,
        ),
        0,
      );
      await pending;
      expect(await stores.blobs.get(hash), job.image);
    },
  );

  test(
    'queued result persistence finishes before history cleanup is planned',
    () async {
      final result = ResultImage(
        id: 'gen1',
        width: 128,
        height: 128,
        seed: 4321,
        badge: ResultBadge.inpaint,
        bytes: finished,
        input: input,
      );
      final write = stores.gallery.persistResult(result);
      stores.gallery.scheduleIndex(
        results: [result],
        selectedId: result.id,
        seq: 2,
      );
      final cleared = await cleanup.clear();
      await write;
      expect(cleared.clearedIds, {'gen1'});
      expect(await stores.gallery.readImage('gen1'), finished);
      expect((await stores.gallery.readInput('gen1'))!.inpaint, isNull);
    },
  );

  test(
    'notifier clears resident and loaded inputs, preserving selection and prompts',
    () async {
      await save('gen1');
      final container = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        galleryInputProvider('gen1'),
        (_, _) {},
      );
      addTearDown(subscription.close);
      expect(
        (await container.read(galleryInputProvider('gen1').future))!.inpaint,
        isNotNull,
      );
      final before = container.read(galleryProvider);
      await container.read(galleryProvider.notifier).clearInpaintHistory();
      final after = container.read(galleryProvider);
      expect(after.selectedId, before.selectedId);
      expect(after.results.single.input!.inpaint, isNull);
      expect(after.results.single.hasInpaintComparison, isFalse);
      expect(after.results.single.input!.prompt, input.prompt);
      expect(
        (await container.read(galleryInputProvider('gen1').future))!.inpaint,
        isNull,
      );
    },
  );

  test('running or saving generation blocks user cleanup', () async {
    await save('gen1');
    final container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        generationProvider.overrideWith(_SavingGeneration.new),
      ],
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(galleryProvider.notifier).clearInpaintHistory(),
      throwsStateError,
    );
    expect((await stores.gallery.readInput('gen1'))!.inpaint, isNotNull);
    expect((await cleanup.scan()).count, 1);
  });

  testWidgets(
    'clearing the same result removes old button and any held comparison',
    (tester) async {
      final container = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      addTearDown(container.dispose);
      final result = ResultImage(
        id: 'gen1',
        width: 128,
        height: 128,
        seed: 4321,
        badge: ResultBadge.inpaint,
        bytes: finished,
        input: input,
      );
      Future<void> mount(ResultImage image) => tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: ResultActions(
                key: const ValueKey('same-result'),
                result: image,
                canvasBar: CanvasActionBar.comparison,
              ),
            ),
          ),
        ),
      );
      await mount(result);
      await tester.pumpAndSettle();
      expect(find.text('旧的'), findsOneWidget);
      final owner = tester.state(find.byType(ResultActions));
      container
          .read(comparePreviewProvider.notifier)
          .show(result.id, finished, owner);
      await mount(result.withoutInpaintHistory());
      await tester.pumpAndSettle();
      expect(find.text('旧的'), findsNothing);
      expect(container.read(comparePreviewProvider), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  group('storage page', () {
    // Finish the store's real I/O and image encoding before testWidgets enters
    // FakeAsync. A runAsync callback cannot drain a pre-existing fake-zone chain.
    setUp(() async {
      await save('gen1').timeout(const Duration(seconds: 15));
    });

    testWidgets(
      'storage cleanup explains consequences and cancellation preserves history',
      (tester) async {
        const paths = MethodChannel('plugins.flutter.io/path_provider');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, (
          call,
        ) async {
          if (call.method == 'getTemporaryDirectory') {
            return '${root.path}/cache';
          }
          if (call.method == 'getApplicationDocumentsDirectory') {
            return '${root.path}/documents';
          }
          return root.path;
        });
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            paths,
            null,
          ),
        );
        final container = ProviderContainer(
          overrides: [appStoresProvider.overrideWithValue(stores)],
        );
        widgetOwnsStoreCleanup = true;
        try {
          tester.view.physicalSize = const Size(420, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: AppTheme.light(),
                home: const StoragePage(),
              ),
            ),
          );
          final label = find.text('历史重绘原图与蒙版');
          for (var i = 0; i < 300 && label.evaluate().isEmpty; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(label, findsOneWidget);
          await tester.ensureVisible(label);
          final row = find
              .ancestor(of: label, matching: find.byType(Row))
              .first;
          final clean = find.descendant(
            of: row,
            matching: find.widgetWithText(TextButton, '清理'),
          );
          await tester.tap(clean);
          await tester.pumpAndSettle();
          expect(find.text('清理历史重绘原图与蒙版'), findsOneWidget);
          expect(find.textContaining('生成成品、提示词和普通生成设置会保留'), findsOneWidget);
          expect(find.textContaining('此操作不可恢复'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          final retained = await tester.runAsync(
            () => stores.gallery.readInput('gen1'),
          );
          expect(retained!.inpaint, isNotNull);
          await tester.tap(clean);
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, '清理'));
          await tester.pump();
          for (
            var i = 0;
            i < 300 &&
                !container
                    .read(galleryProvider)
                    .results
                    .single
                    .inpaintHistoryCleared;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(
            container.read(galleryProvider).results.single.hasInpaintComparison,
            isFalse,
          );
          final completed = find.textContaining('已清理 1 条重绘历史，释放');
          for (var i = 0; i < 300 && completed.evaluate().isEmpty; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(completed, findsOneWidget);
          await tester.pump(const Duration(seconds: 5));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          container.dispose();
          stores.flushNow();
          var storesIdle = false;
          Object? storeError;
          unawaited(
            Future.wait([
              stores.gallery.idle,
              stores.workspace.idle,
              stores.assistant.idle,
            ]).then<void>(
              (_) => storesIdle = true,
              onError: (Object error, StackTrace stack) {
                storeError = error;
                storesIdle = true;
              },
            ),
          );
          // Do not await the store chain from runAsync: its continuations need
          // fake microtasks pumped while the file system progresses in real time.
          for (var i = 0; i < 300 && !storesIdle; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          await tester.pump();
          expect(
            storesIdle,
            isTrue,
            reason: 'store writes must finish in FakeAsync',
          );
          expect(storeError, isNull);
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
