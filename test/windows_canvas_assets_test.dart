import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/state_codec.dart';
import 'package:plana_app/features/inpaint/inpaint_ops.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer container;
  GenerateNotifier gen() => container.read(generateProvider.notifier);
  GenerateState state() => container.read(generateProvider);
  CanvasWorkspaceNotifier canvases() =>
      container.read(canvasWorkspaceProvider.notifier);
  String active() => container.read(canvasWorkspaceProvider).activeId;
  CanvasPrompts at(String id) =>
      container.read(canvasWorkspaceProvider).find(id)!.prompts;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('plana_canvas_assets_');
    stores = await AppStores.open(rootOverride: root);
    container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
  });
  tearDown(() async {
    container.dispose();
    await stores.flushForExit();
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    root.deleteSync(recursive: true);
  });

  test(
    'asynchronous base image targets its source canvas and its own settings',
    () {
      final a = active();
      final first = Uint8List.fromList([1, 2, 3]);
      final replacement = Uint8List.fromList([4, 5, 6]);
      gen().setImg2ImgImage(image: first, width: 832, height: 1216);
      gen().updateImg2Img(strength: .45, noise: .2);
      canvases().create();
      gen().setSize(1024, 1024);
      final other = state();

      gen().setImg2ImgImage(
        image: replacement,
        width: 640,
        height: 768,
        canvasId: a,
      );

      expect(state().img2img, same(other.img2img));
      expect((state().params.width, state().params.height), (1024, 1024));
      expect(at(a).img2img!.image, same(replacement));
      expect(at(a).img2img!.strength, .45);
      expect(at(a).img2img!.noise, .2);
      canvases().select(a);
      expect((state().params.width, state().params.height), (640, 768));
    },
  );

  test(
    'unsaved inactive canvas references survive detached-history cleanup',
    () async {
      final bytes = Uint8List.fromList([31, 32, 33]);
      final hash = await stores.blobs.put(bytes);
      gen().addVibe(image: bytes, name: 'inactive', imageHash: hash);
      final a = active();
      canvases().create();
      expect(state().vibes, isEmpty);
      expect(at(a).vibes.single.image, same(bytes));

      // The debounce has not written the workspace yet. The blob already exists
      // because a gallery snapshot used it before that snapshot was detached.
      final revision = stores.blobs.referenceRevision;
      final live = await stores.workspace.liveRefs(strict: true);
      expect(live, contains(hash));
      expect(
        await stores.blobs.removeDetachedHashes(
          {hash},
          live,
          expectedRevision: revision,
        ),
        0,
      );
      expect(await stores.blobs.get(hash), bytes);
    },
  );

  test(
    'all canvas assets survive restart, including inactive focus masks and ID sequence',
    () async {
      final a = active();
      Uint8List bytes(int n) => Uint8List.fromList([n, n + 1]);
      final shared = bytes(20);
      final focusMask = (MaskGrid(128, 128)..cells[30] = 1).encode();
      final job = InpaintJob(
        image: bytes(40),
        mask: bytes(50),
        strength: .55,
        grid: bytes(60),
        paste: InpaintPaste(
          original: shared,
          sendX: 0,
          sendY: 0,
          tightX: 32,
          tightY: 32,
          tightW: 64,
          tightH: 64,
          outW: 128,
          outH: 128,
          focus: const InpaintFocus(
            x: 0,
            y: 0,
            width: 128,
            height: 128,
            context: 32,
          ),
          focusMask: focusMask,
        ),
      );
      gen().applyCanvas(
        CanvasPrompts.of(
          state().copyWith(
            vibes: [
              VibeItem(id: 'id901', name: 'v', image: shared, enabled: false),
            ],
            charRefs: [CharRefItem(id: 'id902', name: 'c', image: shared)],
            kreaStyleRefs: [
              KreaStyleRefItem(id: 'id903', name: 'k', image: bytes(30)),
            ],
            kreaStyleRefWeight: .35,
            inpaint: job,
            loras: const [ActiveLora(name: 'a', displayName: 'A', weight: .6)],
            loraMem: const {
              'krea': [ActiveLora(name: 'b', displayName: 'B', weight: .2)],
            },
            params: state().params.copyWith(
              naiEffort: NaiEffort.medium,
              normalizeVibe: false,
              hires: const HiresConfig(enabled: true, scale: 1.7, denoise: .4),
            ),
          ),
        ),
      );
      final copy = canvases().create(duplicate: true);
      final blank = canvases().create();
      gen().setImg2ImgImage(image: bytes(80), width: 640, height: 768);
      gen().setNaiEffort(NaiEffort.high);
      gen().updateHires(scale: 1.3);
      final expectedRefs = <String>{};
      for (final p in [at(a), at(copy), at(blank)]) {
        expectedRefs.addAll(
          await generateStateBlobRefs(p.applyTo(state()), stores.blobs),
        );
      }
      await stores.flushForExit();
      final json =
          jsonDecode(
                await File('${root.path}/workspace/state.json').readAsString(),
              )
              as Map;
      expect((json['refs'] as List).toSet(), expectedRefs);
      // An explicit empty list distinguishes a new blank canvas from a legacy
      // canvas whose formerly global references must be filled during migration.
      expect((json['canvases'] as List).last['prompts']['vibes'], isEmpty);
      container.dispose();
      stores = await AppStores.open(rootOverride: root);
      container = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      expect(active(), blank);
      expect(state().vibes, isEmpty);
      expect(state().charRefs, isEmpty);
      expect(state().kreaStyleRefs, isEmpty);
      expect(state().loras, isEmpty);
      expect(state().loraMem, isEmpty);
      expect(state().inpaint, isNull);
      expect(state().img2img!.image, bytes(80));
      expect(state().params.hires.scale, 1.3);
      final saved = at(a);
      expect(saved.vibes.single.enabled, isFalse);
      expect(saved.normalizeVibe, isFalse);
      expect(saved.kreaStyleRefs.single.image, bytes(30));
      expect(saved.kreaStyleRefWeight, .35);
      expect(saved.loras.single.weight, .6);
      expect(saved.loraMem['krea']!.single.weight, .2);
      expect(saved.sampling!.naiEffort, NaiEffort.medium);
      expect(saved.sampling!.hires.scale, 1.7);
      expect(saved.inpaint!.mask, bytes(50));
      expect(saved.inpaint!.grid, bytes(60));
      expect(saved.inpaint!.paste!.focusMask, focusMask);
      expect(saved.inpaint!.paste!.focus!.context, 32);
      expect(saved.vibes.single.image, same(saved.charRefs.single.image));
      expect(saved.vibes.single.image, same(saved.inpaint!.paste!.original));
      expect(saved.vibes.single.image, same(at(copy).vibes.single.image));
      expect(stores.workspace.idSeq, greaterThan(903));
      expect(gen().addVibe(image: bytes(90), name: 'new'), 'id904');
      expect(
        await stores.workspace.liveRefs(strict: true),
        containsAll(expectedRefs),
      );
    },
  );

  test(
    'failed workspace save retains every canvas and retries newest content',
    () async {
      final a = active();
      final one = Uint8List.fromList([91, 92]);
      final two = Uint8List.fromList([93, 94]);
      gen().addVibe(image: one, name: 'first');
      final b = canvases().create();
      gen().setImg2ImgImage(image: two, width: 832, height: 1216);
      final obstruction = Directory('${root.path}/workspace/state.json.tmp');
      await obstruction.create(recursive: true);
      try {
        await expectLater(
          stores.flushForExit(),
          throwsA(isA<FileSystemException>()),
        );
        expect(stores.saveError.value, contains('工作台保存失败'));
        final expected = {
          await stores.blobs.hashOf(one),
          await stores.blobs.hashOf(two),
        };
        expect(
          await stores.workspace.liveRefs(strict: true),
          containsAll(expected),
        );
        canvases().select(a);
        gen().setPrompts(positive: 'newest draft');
      } finally {
        await obstruction.delete();
      }
      await stores.flushForExit();
      final loaded = await AppStores.open(rootOverride: root);
      expect(
        loaded.workspace.initialCanvases!.find(a)!.prompts.prompt,
        'newest draft',
      );
      expect(
        loaded.workspace.initialCanvases!.find(a)!.prompts.vibes.single.image,
        one,
      );
      expect(
        loaded.workspace.initialCanvases!.find(b)!.prompts.img2img!.image,
        two,
      );
    },
  );

  test(
    'inpaint completion and undo target the source; deleted source stays deleted',
    () {
      final a = active();
      gen().setImg2ImgImage(
        image: Uint8List.fromList([1]),
        width: 832,
        height: 1216,
      );
      final before = state();
      final b = canvases().create();
      gen().setPrompts(positive: 'other draft');
      final other = state();
      final job = InpaintJob(
        image: Uint8List.fromList([2]),
        mask: Uint8List.fromList([3]),
        strength: .6,
      );
      gen().setInpaint(job, width: 64, height: 128, canvasId: a);
      expect(state(), same(other));
      expect(at(a).inpaint, same(job));
      expect(at(a).img2img, isNull);
      canvases().undoWrite(before, a);
      expect(state().prompt, 'other draft');
      expect(state().inpaint, isNull);
      expect(state().img2img, isNull);
      expect(at(a).img2img, same(before.img2img));
      expect(at(a).inpaint, isNull);
      canvases().select(a);
      canvases().remove(b);
      final current = state();
      gen().setInpaint(job, width: 64, height: 128, canvasId: b);
      gen().setImg2ImgImage(
        image: job.image,
        width: 64,
        height: 128,
        canvasId: b,
      );
      expect(state(), same(current));
      canvases().undoWrite(other, b);
      expect(state().img2img, same(before.img2img));
      expect(container.read(canvasWorkspaceProvider).find(b), isNull);
    },
  );

  test(
    'LoRA failures reach inactive and stashed copies without reviving removals',
    () {
      const pending = ActiveLora(
        name: 'pending',
        displayName: 'P',
        pending: LoraPending(versionId: 5),
      );
      gen().setModel('Anima Turbo');
      gen().applyLoraSelection([pending]);
      final a = active();
      final b = canvases().create(duplicate: true);
      gen().setModel('Krea 2 Turbo');
      final removed = canvases().create(duplicate: true);
      canvases().remove(removed);
      canvases().create();
      gen().markLoraFailed('pending', 'test failure');
      expect(state().loras, isEmpty);
      expect(state().loraMem, isEmpty);
      expect(at(a).loras.single.enabled, isFalse);
      expect(at(a).loras.single.pending!.failed, 'test failure');
      expect(at(b).loraMem['anima']!.single.pending!.failed, 'test failure');
      canvases().select(a);
      gen().removeLora('pending');
      gen().promotePendingLora(
        'pending',
        const ActiveLora(name: 'ready', displayName: 'R'),
      );
      expect(at(a).loras, isEmpty);
      expect(at(b).loraMem['anima']!.single.name, 'ready');
      expect(container.read(canvasWorkspaceProvider).find(removed), isNull);
    },
  );
}
