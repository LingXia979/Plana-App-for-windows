import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/gen_abort.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/generate/gen_jobs.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/img2img_card.dart';
import 'package:plana_app/features/inpaint/inpaint_comparison.dart';
import 'package:plana_app/features/inpaint/inpaint_ops.dart';
import 'package:plana_app/features/inpaint/inpaint_overlay.dart';

const _sourceId = 'focused-original-not-in-gallery';
const _outer = (x: 64, y: 96, w: 384, h: 576);
const _context = 64;

Uint8List _solid(int width, int height, int r, int g, int b) =>
    Uint8List.fromList(
      img.encodePng(
        img.fill(
          img.Image(width: width, height: height),
          color: img.ColorRgb8(r, g, b),
        ),
      ),
    );

List<int> _pixel(img.Image image, int x, int y) {
  final pixel = image.getPixel(x, y);
  return [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
}

Future<({InpaintJob job, int width, int height})> _prepared() {
  final grid = MaskGrid(512, 768)
    ..paintDot(200, 248, 16) // Inside the effective repaint region.
    ..paintDot(80, 120, 8) // Context must remain editable but never be sent.
    ..paintDot(16, 16, 8); // Preserve strokes outside the focused rectangle.
  return prepareFocusedInpaint(
    original: _solid(512, 768, 255, 0, 0),
    grid: grid,
    outer: _outer,
    context: _context,
    strength: .7,
    sourceId: _sourceId,
  );
}

Future<void> _until(bool Function() predicate, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue, reason: reason);
}

Future<void> _workspaceWritten(Directory root, double strength) async {
  final file = File('${root.path}/workspace/state.json');
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (await file.exists()) {
      final json = jsonDecode(await file.readAsString()) as Map;
      if ((json['state'] as Map)['inpaint']?['strength'] == strength) return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Focused workspace was not persisted');
}

void _expectOriginalGeometry(InpaintJob job) {
  final focus = job.paste!.focus!;
  expect((focus.x, focus.y, focus.width, focus.height), (64, 96, 384, 576));
  expect(focus.context, _context);
  expect(job.sourceId, _sourceId);
  final raw = MaskGrid(512, 768);
  final effective = MaskGrid(512, 768);
  expect(raw.decodeInto(job.grid!), isTrue);
  expect(effective.decodeInto(job.paste!.focusMask!), isTrue);
  expect(raw.hasCellsIn((x: 0, y: 0, w: 32, h: 32)), isTrue);
  expect(raw.hasCellsIn((x: 64, y: 96, w: 32, h: 32)), isTrue);
  expect(effective.hasCellsIn((x: 0, y: 0, w: 32, h: 32)), isFalse);
  expect(effective.hasCellsIn((x: 64, y: 96, w: 32, h: 32)), isFalse);
  expect(maskBounds(effective), (x: 192, y: 240, w: 16, h: 16));
}

void _expectComposed(Uint8List bytes, List<int> selectedColor) {
  final image = img.decodePng(bytes)!;
  expect((image.width, image.height), (512, 768));
  expect(_pixel(image, 200, 248), selectedColor);
  for (final (x, y) in [(16, 16), (80, 120), (300, 350), (500, 750)]) {
    expect(_pixel(image, x, y), [255, 0, 0], reason: 'unselected $x,$y');
  }
}

class _Auth extends AuthModeNotifier {
  @override
  Future<AuthMode?> build() async => AuthMode.token;
}

class _Keys extends NaiKeysNotifier {
  @override
  Future<List<NaiKey>> build() async => [
    const NaiKey(id: 'test', token: 'local-test-only', primary: true),
  ];
}

class _Frames extends NaiClient {
  final started = Completer<void>();
  final frames = StreamController<NaiFrame>();
  Map<String, dynamic>? request;

  @override
  Stream<NaiFrame> generateImageStream({
    required String token,
    required Map<String, dynamic> body,
    GenAbort? abort,
  }) {
    request = body;
    started.complete();
    return frames.stream;
  }

  @override
  Future<NaiSubscription> subscription(String token) async => (
    anlas: 10000,
    fixedAnlas: 10000,
    purchasedAnlas: 0,
    isOpus: true,
    tier: 3,
    usage: null,
  );
}

class _HeldAlbums extends AlbumsNotifier {
  final saving = Completer<void>();
  final release = Completer<void>();

  @override
  Future<AlbumChange> organize(
    Set<String> images,
    Set<String> targets, {
    Set<String>? sources,
  }) async {
    if (!saving.isCompleted) saving.complete();
    await release.future;
    return super.organize(images, targets, sources: sources);
  }
}

class _ReopenEditor extends ConsumerWidget {
  const _ReopenEditor();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(inpaintSessionProvider);
    return Scaffold(
      body: session == null
          ? const Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 520, child: Img2ImgCard()),
            )
          : InpaintOverlay(session: session),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'persisted focused job reopens with its outer frame, context, raw strokes and edited strength',
    (tester) async {
      late Directory root;
      late AppStores stores;
      late ProviderContainer container;
      late InpaintJob saved;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('plana_focus_flow_');
        final first = await AppStores.open(rootOverride: root);
        final initial = ProviderContainer(
          overrides: [appStoresProvider.overrideWithValue(first)],
        );
        final prepared = await _prepared();
        initial
            .read(generateProvider.notifier)
            .setInpaint(
              prepared.job,
              width: prepared.width,
              height: prepared.height,
            );
        initial.read(generateProvider.notifier).updateInpaintStrength(.83);
        await initial
            .read(inpaintPrefsProvider.notifier)
            .save(const InpaintPrefs(mode: 'expand', strength: .7));
        _expectOriginalGeometry(initial.read(generateProvider).inpaint!);
        first.flushNow();
        await _workspaceWritten(root, .83);
        initial.dispose();
        stores = await AppStores.open(rootOverride: root);
        container = ProviderContainer(
          overrides: [
            appStoresProvider.overrideWithValue(stores),
            desktopModeProvider.overrideWithValue(true),
          ],
        );
        container.read(desktopLibraryProvider);
        saved = container.read(generateProvider).inpaint!;
      });
      addTearDown(() {
        container.dispose();
        stores.flushNow();
      });
      _expectOriginalGeometry(saved);
      expect(saved.strength, .83);
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const _ReopenEditor(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.brush));
      final canvas = find.byKey(const ValueKey('inpaint-editor-canvas'));
      for (var i = 0; i < 200 && canvas.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(canvas, findsOneWidget);
      final dynamic painter = tester.widget<CustomPaint>(canvas).painter;
      expect(painter.crop, _outer);
      expect(painter.focusContext, _context);
      expect(painter.expandUi, isFalse);
      final originalGrid = MaskGrid(512, 768)..decodeInto(saved.grid!);
      expect(painter.rects, originalGrid.displayRects());
      expect((painter.image.width, painter.image.height), (512, 768));
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('inpaint-focus-context')),
      );
      expect(slider.value, 64);
      await tester.tap(find.text('保存遮罩'));
      await tester.pump();
      for (
        var i = 0;
        i < 250 && identical(container.read(generateProvider).inpaint, saved);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      final resaved = container.read(generateProvider).inpaint!;
      expect(identical(resaved, saved), isFalse);
      _expectOriginalGeometry(resaved);
      expect(resaved.grid, saved.grid);
      expect(resaved.strength, .83);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        stores.flushNow();
        await _workspaceWritten(root, .83);
      });
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'focused stream and final use source coordinates and persisted old comparison uses only the effective mask',
    () async {
      final root = await Directory.systemTemp.createTemp('plana_focus_flow_');
      final stores = await AppStores.open(rootOverride: root);
      final client = _Frames();
      final albums = _HeldAlbums();
      final container = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          desktopModeProvider.overrideWithValue(true),
          authModeProvider.overrideWith(_Auth.new),
          naiKeysStoreProvider.overrideWith(_Keys.new),
          naiClientProvider.overrideWith((ref, base) => client),
          albumsProvider.overrideWith(() => albums),
        ],
      );
      addTearDown(() async {
        if (!albums.release.isCompleted) albums.release.complete();
        if (client.frames.hasListener) {
          await client.frames.close();
        } else {
          unawaited(client.frames.close());
        }
        stores.flushNow();
        await stores.gallery.idle;
        await stores.albums.idle;
        container.dispose();
      });
      await container.read(authModeProvider.future);
      await container.read(naiKeysStoreProvider.future);
      container.read(albumsProvider);
      final albumId = await albums.create('Focused flow');
      final prepared = await _prepared();
      final state = GenerateState.initial().copyWith(
        inpaint: prepared.job,
        params: GenerateState.initial().params.copyWith(
          width: prepared.width,
          height: prepared.height,
        ),
      );
      final generation = container
          .read(generationProvider.notifier)
          .generate(
            using: state,
            galleryTarget: GallerySaveTarget.album(albumId),
          );
      await client.started.future.timeout(const Duration(seconds: 10));
      final started = container.read(generationProvider).jobs.single;
      expect((started.width, started.height), (512, 768));
      expect(started.pasteUnder, isNull);
      expect(started.pasteAt, isNull);
      expect(started.preview, prepared.job.paste!.original);
      final parameters = client.request!['parameters'] as Map;
      expect((parameters['width'], parameters['height']), (832, 1216));
      final sentMask = img.decodePng(
        base64Decode(parameters['mask'] as String),
      )!;
      expect((sentMask.width, sentMask.height), (832, 1216));
      client.frames.add((
        step: 10,
        isFinal: false,
        bytes: _solid(104, 152, 0, 255, 0),
      ));
      await _until(
        () => !identical(
          container.read(generationProvider).jobs.single.preview,
          started.preview,
        ),
        'The low-resolution focused stream frame must be composed onto the original',
      );
      _expectComposed(container.read(generationProvider).jobs.single.preview!, [
        0,
        255,
        0,
      ]);
      client.frames.add((
        step: 28,
        isFinal: true,
        bytes: _solid(prepared.width, prepared.height, 0, 0, 255),
      ));
      await albums.saving.future.timeout(const Duration(seconds: 10));
      final saving = container.read(generationProvider).jobs.single;
      expect(saving.stage, GenJobStage.saving);
      _expectComposed(saving.preview!, [0, 0, 255]);
      albums.release.complete();
      expect(await generation, GenOutcome.ok);
      final result = container.read(galleryProvider).results.single;
      expect((result.width, result.height), (512, 768));
      expect(result.bytes, saving.preview);
      expect(container.read(generationProvider).jobs, isEmpty);
      stores.flushNow();
      await stores.gallery.idle;
      await stores.albums.idle;

      final reopened = await AppStores.open(rootOverride: root);
      final restoredResult = reopened.gallery.initialResults.single;
      expect(restoredResult.hasInpaintComparison, isTrue);
      final savedState = (await reopened.gallery.readInput(restoredResult.id))!;
      final finalBytes = (await reopened.gallery.readImage(restoredResult.id))!;
      _expectOriginalGeometry(savedState.inpaint!);
      _expectComposed(finalBytes, [0, 0, 255]);
      final comparison = await buildInpaintComparison(
        result: finalBytes,
        job: savedState.inpaint!,
      );
      _expectComposed(comparison, [255, 89, 89]);
      expect(await reopened.gallery.readImage(restoredResult.id), finalBytes);
      expect(
        reopened.gallery.initialResults.any((r) => r.id == _sourceId),
        isFalse,
      );
    },
  );
}
