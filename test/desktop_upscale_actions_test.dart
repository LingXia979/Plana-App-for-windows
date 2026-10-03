import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/net/anlas_provider.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/upscale_model.dart';
import 'package:plana_app/features/gallery/upscale_nai.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';
import 'package:plana_app/features/generate/gen_jobs.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/models.dart';

class _Canvas extends GenerateNotifier {
  @override
  GenerateState build() => GenerateState.initial();
  void model(String model) =>
      state = state.copyWith(params: state.params.copyWith(model: model));
}

class _Balance extends AnlasNotifier {
  int refreshes = 0;
  @override
  Future<NaiSubscription?> build() async => null;
  @override
  Future<void> refresh() async => refreshes++;
}

class _Library extends DesktopLibraryNotifier {
  @override
  DesktopLibrarySelection build() =>
      const DesktopLibrarySelection(choice: '', day: '2026-10-03');
}

class _Generation extends GenerationNotifier {
  final calls = <({GenerateState? input, GallerySaveTarget? target})>[];
  @override
  GenPool build() => const GenPool();
  @override
  Future<GenOutcome> generate({
    GallerySaveTarget? galleryTarget,
    GenerateState? using,
    bool stay = false,
    void Function(String jobId)? onJob,
  }) async {
    calls.add((input: using, target: galleryTarget));
    return GenOutcome.ok;
  }
}

class _Upscaler {
  _Upscaler(this.png);
  final Uint8List png;
  final calls = <({Uint8List bytes, int width, int height})>[];
  Completer<NaiUpscaleResult>? pending;
  Future<NaiUpscaleResult> call(
    Uint8List bytes, {
    required int width,
    required int height,
    void Function(String stage)? onStage,
  }) async {
    calls.add((bytes: bytes, width: width, height: height));
    onStage?.call('模拟超分处理中');
    if (pending != null) return pending!.future;
    return (png: png, width: width * 2, height: height * 2);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late GalleryNotifier gallery;
  late _Generation generation;
  late _Balance balance;
  late _Upscaler upscale;
  late ResultImage source;
  late ResultImage other;
  late String albumA;
  late String albumB;
  late ValueNotifier<ResultImage> displayed;
  var disposed = false;
  final red = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 128, height: 128)..clear(img.ColorRgb8(255, 0, 0)),
    ),
  );
  final blue = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 128, height: 128)..clear(img.ColorRgb8(0, 0, 255)),
    ),
  );
  final output = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 256, height: 256)..clear(img.ColorRgb8(255, 80, 0)),
    ),
  );
  final largeOutput = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 1664, height: 2432)..clear(img.ColorRgb8(255, 80, 0)),
    ),
  );

  Future<void> prepare(WidgetTester tester) async {
    await tester.runAsync(() async {
      stores = AppStores.ephemeral();
      await stores.prefs.write(
        key: 'upscale_settings',
        value: jsonEncode(
          const UpscaleSettings(
            method: UpscaleMethod.naiV5,
            enhanceScale: EnhanceScale.x15,
            strength: .35,
            noise: .12,
          ).toJson(),
        ),
      );
      generation = _Generation();
      balance = _Balance();
      upscale = _Upscaler(output);
      container = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          desktopModeProvider.overrideWithValue(true),
          desktopLibraryProvider.overrideWith(_Library.new),
          generateProvider.overrideWith(_Canvas.new),
          generationProvider.overrideWith(() => generation),
          anlasProvider.overrideWith(() => balance),
          v5ChargedProvider.overrideWithValue(false),
          naiUpscaleRunnerProvider.overrideWithValue(upscale.call),
        ],
      );
      gallery = container.read(galleryProvider.notifier);
      final albums = container.read(albumsProvider.notifier);
      albumA = await albums.create('开始时的图库');
      albumB = await albums.create('切换后的图库');
      final input = GenerateState.initial();
      source = await gallery.addResultToGallery(
        bytes: red,
        width: 128,
        height: 128,
        seed: 111,
        input: input.copyWith(
          prompt: 'source red image',
          negativePrompt: 'source negative',
          params: input.params.copyWith(seed: '111', width: 128, height: 128),
        ),
        target: GallerySaveTarget.album(albumA),
      );
      other = await gallery.addResultToGallery(
        bytes: blue,
        width: 128,
        height: 128,
        seed: 222,
        input: input.copyWith(
          prompt: 'other blue image',
          params: input.params.copyWith(seed: '222', width: 128, height: 128),
        ),
        target: GallerySaveTarget.album(albumB),
      );
      gallery.select(source.id);
      container.read(desktopLibraryProvider.notifier).choose(albumA);
      displayed = ValueNotifier(source);
      disposed = false;
    });
  }

  tearDown(() {
    if (!disposed) container.dispose();
    displayed.dispose();
    final root = stores.desktopOutput.root.parent;
    expect(
      root.path.startsWith(
        '${Directory.systemTemp.path}${Platform.pathSeparator}plana_stores',
      ),
      isTrue,
    );
    root.deleteSync(recursive: true);
  });

  Finder key(String value) => find.byKey(ValueKey(value));
  Finder button(String label) => find
      .ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton,
        ),
      )
      .first;
  Finder getPanel() => key('upscale-parameters');

  Future<void> spinUntil(WidgetTester tester, bool Function() done) async {
    await tester.pump();
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  Future<void> mount(WidgetTester tester, {bool details = false}) async {
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: details ? 380 : 960,
                child: ValueListenableBuilder<ResultImage>(
                  valueListenable: displayed,
                  builder: (_, image, _) => ResultActions(
                    result: image,
                    detailsPanel: details,
                    canvasBar: details ? null : CanvasActionBar.top,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    disposed = true;
    stores.flushNow();
    var done = false;
    unawaited(
      Future.wait([
        stores.gallery.idle,
        stores.desktopOutput.idle,
        stores.albums.idle,
        stores.workspace.idle,
        stores.assistant.idle,
        stores.ledger.idle,
        stores.prefs.delete(key: '__test_drain'),
      ]).then((_) => done = true),
    );
    await spinUntil(tester, () => done);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  for (final details in [false, true]) {
    testWidgets(
      'oversized 2x result keeps editable parameters and restores them on a supported image, details=$details',
      (tester) async {
        await prepare(tester);
        displayed.value = ResultImage(
          id: 'oversized-2x-result',
          width: 1664,
          height: 2432,
          seed: source.seed,
          bytes: largeOutput,
          badge: ResultBadge.upscaled2x,
          input: source.input!.copyWith(
            params: source.input!.params.copyWith(width: 832, height: 1216),
          ),
        );
        await mount(tester, details: details);
        await tester.tap(button('图生图放大'));
        await spinUntil(tester, () => getPanel().evaluate().isNotEmpty);
        await tester.pumpAndSettle();
        final scale = tester.widget<DropdownButton<EnhanceScale>>(
          find.byType(DropdownButton<EnhanceScale>),
        );
        expect(scale.value, isNull);
        expect(scale.onChanged, isNull);
        expect(find.text('无可用倍率'), findsOneWidget);
        expect(find.byType(DropdownButton<int>), findsOneWidget);
        expect(find.byType(Slider), findsNWidgets(2));
        expect(find.textContaining('超分前'), findsOneWidget);
        expect(find.textContaining('2496×3648'), findsNothing);
        expect(find.text('当前图片不可放大'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(key('upscale-confirm')).onPressed,
          isNull,
        );

        await tester.tap(find.byType(DropdownButton<int>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('档 5').last);
        await tester.pumpAndSettle();
        expect(
          tester.widgetList<Slider>(find.byType(Slider)).map((s) => s.value),
          [.7, .1],
        );
        await tester.drag(find.byType(Slider).first, const Offset(40, 0));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(Slider).last, const Offset(25, 0));
        await tester.pumpAndSettle();
        final edited = tester
            .widgetList<Slider>(find.byType(Slider))
            .map((s) => s.value)
            .toList();
        expect(edited[0], isNot(.7));
        expect(edited[1], isNot(.1));
        final saved = UpscaleSettings.fromJson(
          jsonDecode(stores.prefs.get('upscale_settings')!)
              as Map<String, dynamic>,
        );
        expect(saved.strength, edited[0]);
        expect(saved.noise, edited[1]);
        if (details) {
          await tester.enterText(find.byType(TextField).last, '0.23');
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          edited[1] = .23;
          expect(
            tester.widgetList<Slider>(find.byType(Slider)).last.value,
            .23,
          );
          expect(
            (jsonDecode(stores.prefs.get('upscale_settings')!) as Map)['noise'],
            .23,
          );
        }
        await tester.tap(key('upscale-confirm'));
        expect(generation.calls, isEmpty);
        expect(upscale.calls, isEmpty);
        Navigator.of(tester.element(getPanel())).pop();
        await tester.pumpAndSettle();

        displayed.value = source;
        await tester.pump();
        await tester.tap(button('图生图放大'));
        await spinUntil(tester, () => getPanel().evaluate().isNotEmpty);
        await tester.pumpAndSettle();
        expect(find.text('无可用倍率'), findsNothing);
        expect(
          tester
              .widget<DropdownButton<EnhanceScale>>(
                find.byType(DropdownButton<EnhanceScale>),
              )
              .onChanged,
          isNotNull,
        );
        expect(
          tester.widgetList<Slider>(find.byType(Slider)).map((s) => s.value),
          edited,
        );
        expect(
          tester.widget<FilledButton>(key('upscale-confirm')).onPressed,
          isNotNull,
        );
        await tester.tap(key('upscale-confirm'));
        await spinUntil(tester, () => generation.calls.isNotEmpty);
        expect(generation.calls.single.input!.img2img!.strength, edited[0]);
        expect(generation.calls.single.input!.img2img!.noise, edited[1]);
        expect(upscale.calls, isEmpty);
        await finish(tester);
      },
    );

    testWidgets(
      'desktop redraw opens only remembered parameters and cancellation never executes, details=$details',
      (tester) async {
        await prepare(tester);
        await mount(tester, details: details);
        expect(find.text('图生图放大'), findsOneWidget);
        expect(find.text('超分辨率'), findsOneWidget);
        await tester.tap(button('图生图放大'));
        await spinUntil(tester, () => getPanel().evaluate().isNotEmpty);
        await tester.pumpAndSettle();
        expect(find.byType(SegmentedButton<bool>), findsNothing);
        final scales = find.byType(DropdownButton<EnhanceScale>);
        expect(
          tester.widget<DropdownButton<EnhanceScale>>(scales).value,
          EnhanceScale.x15,
        );
        final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
        expect(sliders.map((slider) => slider.value), [.35, .12]);
        await tester.tap(scales);
        await tester.pumpAndSettle();
        await tester.tap(find.text('2×').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButton<int>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('档 5').last);
        await tester.pumpAndSettle();
        Navigator.of(tester.element(getPanel())).pop();
        await tester.pumpAndSettle();
        expect(upscale.calls, isEmpty);
        expect(generation.calls, isEmpty);
        await tester.tap(button('图生图放大'));
        await spinUntil(tester, () => getPanel().evaluate().isNotEmpty);
        await tester.pumpAndSettle();
        expect(
          tester.widget<DropdownButton<EnhanceScale>>(scales).value,
          EnhanceScale.x2,
        );
        expect(
          tester.widgetList<Slider>(find.byType(Slider)).map((s) => s.value),
          [.7, .1],
        );
        expect(upscale.calls, isEmpty);
        expect(generation.calls, isEmpty);
        Navigator.of(tester.element(getPanel())).pop();
        await tester.pumpAndSettle();
        await finish(tester);
      },
    );

    testWidgets(
      'desktop redraw sends the finished picture with chosen parameters and clears an old mask, details=$details',
      (tester) async {
        await prepare(tester);
        final snapshot = source.input!.copyWith(
          inpaint: InpaintJob(image: blue, mask: blue, strength: .92),
          img2img: Img2ImgConfig(image: blue, strength: .95, noise: .83),
        );
        displayed.value = ResultImage(
          id: source.id,
          width: source.width,
          height: source.height,
          seed: source.seed,
          bytes: red,
          input: snapshot,
          badge: ResultBadge.inpaint,
        );
        await mount(tester, details: details);
        await tester.tap(button('图生图放大'));
        await spinUntil(tester, () => getPanel().evaluate().isNotEmpty);
        await tester.pumpAndSettle();
        expect(upscale.calls, isEmpty);
        expect(generation.calls, isEmpty);
        await tester.tap(key('upscale-confirm'));
        await spinUntil(tester, () => generation.calls.isNotEmpty);
        await tester.pumpAndSettle();
        final call = generation.calls.single;
        final input = call.input!;
        expect(input.inpaint, isNull);
        expect(input.img2img!.image, red);
        expect(input.img2img!.strength, .35);
        expect(input.img2img!.noise, .12);
        expect(input.img2img!.upscaledEnhance, isFalse);
        expect((input.params.width, input.params.height), (192, 192));
        expect(input.params.seed, isEmpty);
        expect(input.prompt, 'source red image');
        expect(input.negativePrompt, 'source negative');
        expect(call.target?.albumId, albumA);
        expect(snapshot.inpaint, isNotNull);
        expect(upscale.calls, isEmpty);
        expect(getPanel(), findsNothing);
        expect(key('upscale-progress'), findsNothing);
        await finish(tester);
      },
    );

    testWidgets(
      'desktop super-resolution executes directly and saves a distinct result with source metadata, details=$details',
      (tester) async {
        await prepare(tester);
        upscale.pending = Completer<NaiUpscaleResult>();
        await mount(tester, details: details);
        await tester.tap(button('超分辨率'));
        await spinUntil(tester, () => upscale.calls.isNotEmpty);
        expect(getPanel(), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byType(SegmentedButton<bool>), findsNothing);
        expect(key('upscale-progress'), findsOneWidget);
        expect(upscale.calls.single, (bytes: red, width: 128, height: 128));
        expect(generation.calls, isEmpty);
        upscale.pending!.complete((png: output, width: 256, height: 256));
        await spinUntil(
          tester,
          () =>
              container.read(galleryProvider).results.length == 3 &&
              key('upscale-progress').evaluate().isEmpty,
        );
        final result = container.read(galleryProvider).results.first;
        expect(result.id, isNot(source.id));
        expect(result.width, 256);
        expect(result.height, 256);
        expect(result.badge, ResultBadge.upscaled2x);
        expect(result.badge.label, '2x');
        expect(ResultBadge.upscaled.label, '4x');
        expect(result.seed, 111);
        expect(result.input?.prompt, 'source red image');
        expect(result.input?.negativePrompt, 'source negative');
        expect(result.input?.params.seed, '111');
        expect(container.read(albumsProvider).ofImage(result.id), {albumA});
        expect(
          await tester.runAsync(() => stores.gallery.readImage(result.id)),
          output,
        );
        expect(
          (await tester.runAsync(
            () => stores.gallery.readInput(result.id),
          ))?.prompt,
          'source red image',
        );
        expect(
          await tester.runAsync(() => stores.gallery.readImage(source.id)),
          red,
        );
        expect(balance.refreshes, 1);
        await tester.runAsync(() async {
          await stores.gallery.flushIndex();
          await stores.gallery.load();
        });
        expect(
          stores.gallery.initialResults
              .singleWhere((image) => image.id == result.id)
              .badge,
          ResultBadge.upscaled2x,
        );
        await finish(tester);
      },
    );
  }

  testWidgets(
    'unsupported redraw stays disabled instead of running super-resolution',
    (tester) async {
      await prepare(tester);
      (container.read(generateProvider.notifier) as _Canvas).model('Anima');
      await mount(tester);
      await tester.tap(button('图生图放大'));
      await spinUntil(tester, () => getPanel().evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.textContaining('不支持图生图'), findsOneWidget);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      expect(
        tester.widget<FilledButton>(key('upscale-confirm')).onPressed,
        isNull,
      );
      expect(upscale.calls, isEmpty);
      expect(generation.calls, isEmpty);
      Navigator.of(tester.element(getPanel())).pop();
      await tester.pumpAndSettle();
      await finish(tester);
    },
  );

  testWidgets('missing redraw snapshot shows its reason and cannot submit', (
    tester,
  ) async {
    await prepare(tester);
    displayed.value = ResultImage(
      id: 'no-snapshot',
      width: 128,
      height: 128,
      seed: 9,
      bytes: red,
    );
    await mount(tester, details: true);
    await tester.tap(button('图生图放大'));
    await spinUntil(tester, () => getPanel().evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.textContaining('没有参数快照'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(key('upscale-confirm')).onPressed,
      isNull,
    );
    expect(upscale.calls, isEmpty);
    expect(generation.calls, isEmpty);
    Navigator.of(tester.element(getPanel())).pop();
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets(
    'super-resolution failure preserves source and allows another attempt',
    (tester) async {
      await prepare(tester);
      upscale.pending = Completer<NaiUpscaleResult>();
      await mount(tester);
      final before = container.read(galleryProvider);
      await tester.tap(button('超分辨率'));
      await spinUntil(tester, () => upscale.calls.isNotEmpty);
      upscale.pending!.completeError(StateError('simulated failure'));
      await spinUntil(tester, () => key('upscale-progress').evaluate().isEmpty);
      await tester.pumpAndSettle();
      expect(find.textContaining('超分失败'), findsOneWidget);
      expect(container.read(galleryProvider), same(before));
      expect(
        await tester.runAsync(() => stores.gallery.readImage(source.id)),
        red,
      );
      expect(
        tester.widget<ButtonStyleButton>(button('超分辨率')).onPressed,
        isNotNull,
      );
      expect(balance.refreshes, 0);
      await finish(tester);
    },
  );

  for (final missing in [false, true]) {
    testWidgets(
      'super-resolution rejects ${missing ? 'missing original' : 'oversized input'} before runner',
      (tester) async {
        await prepare(tester);
        displayed.value = ResultImage(
          id: 'unavailable',
          width: missing ? 128 : 2048,
          height: missing ? 128 : 2048,
          seed: 9,
          bytes: missing ? null : red,
        );
        await mount(tester, details: missing);
        await tester.tap(button('超分辨率'));
        await spinUntil(
          tester,
          () => find
              .textContaining(missing ? '此图无像素数据' : '超过 3,145,728')
              .evaluate()
              .isNotEmpty,
        );
        expect(getPanel(), findsNothing);
        expect(key('upscale-progress'), findsNothing);
        expect(upscale.calls, isEmpty);
        expect(container.read(galleryProvider).results, hasLength(2));
        expect(container.read(galleryProvider).selectedId, source.id);
        await finish(tester);
      },
    );
  }

  testWidgets('same-frame double click submits only one super-resolution job', (
    tester,
  ) async {
    await prepare(tester);
    upscale.pending = Completer<NaiUpscaleResult>();
    await mount(tester);
    final click = tester.widget<ButtonStyleButton>(button('超分辨率')).onPressed!;
    click();
    click();
    await spinUntil(tester, () => upscale.calls.isNotEmpty);
    expect(upscale.calls, hasLength(1));
    expect(tester.widget<ButtonStyleButton>(button('超分辨率')).onPressed, isNull);
    upscale.pending!.complete((png: output, width: 256, height: 256));
    await spinUntil(
      tester,
      () =>
          container.read(galleryProvider).results.length == 3 &&
          key('upscale-progress').evaluate().isEmpty,
    );
    expect(upscale.calls, hasLength(1));
    await finish(tester);
  });

  testWidgets(
    'changing displayed source and album midflight does not mix result metadata',
    (tester) async {
      await prepare(tester);
      // Force lazy loading of the source snapshot, as after restarting the app.
      displayed.value = source.stripped();
      upscale.pending = Completer<NaiUpscaleResult>();
      await mount(tester, details: true);
      await tester.tap(button('超分辨率'));
      await spinUntil(tester, () => upscale.calls.isNotEmpty);
      displayed.value = other;
      gallery.select(other.id);
      container.read(desktopLibraryProvider.notifier).choose(albumB);
      await tester.pump();
      upscale.pending!.complete((png: output, width: 256, height: 256));
      await spinUntil(
        tester,
        () =>
            container.read(galleryProvider).results.length == 3 &&
            key('upscale-progress').evaluate().isEmpty,
      );
      final result = container.read(galleryProvider).results.first;
      expect(result.seed, source.seed);
      expect(result.input?.prompt, 'source red image');
      expect(result.input?.params.seed, '111');
      expect(upscale.calls.single.bytes, red);
      expect(container.read(albumsProvider).ofImage(result.id), {albumA});
      expect(container.read(galleryProvider).selectedId, other.id);
      expect(container.read(desktopLibraryProvider).albumId, albumB);
      await finish(tester);
    },
  );
}
