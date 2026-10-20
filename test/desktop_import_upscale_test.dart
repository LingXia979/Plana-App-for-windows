import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/net/anlas_provider.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/upscale_nai.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/import/import_panel.dart';

import 'support/pump_until.dart';

class _Balance extends AnlasNotifier {
  int refreshes = 0;

  @override
  Future<NaiSubscription?> build() async => null;

  @override
  Future<void> refresh() async => refreshes++;
}

class _Upscaler {
  final calls = <({Uint8List bytes, int width, int height})>[];
  late Completer<NaiUpscaleResult> pending;

  Future<NaiUpscaleResult> call(
    Uint8List bytes, {
    required int width,
    required int height,
    void Function(String stage)? onStage,
  }) {
    calls.add((bytes: bytes, width: width, height: height));
    onStage?.call('上传 NAI…');
    return pending.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late _Upscaler upscale;
  late _Balance balance;
  late String albumA, albumB;
  final pixels = img.Image(width: 64, height: 96, numChannels: 4)
    ..clear(img.ColorRgba8(180, 90, 30, 80));
  final png = Uint8List.fromList(img.encodePng(pixels));
  final jpeg = Uint8List.fromList(img.encodeJpg(pixels));
  final output = Uint8List.fromList(
    img.encodePng(img.Image(width: 128, height: 192)),
  );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    stores = AppStores.ephemeral();
    upscale = _Upscaler();
    balance = _Balance();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        naiUpscaleRunnerProvider.overrideWithValue(upscale.call),
        anlasProvider.overrideWith(() => balance),
      ],
    );
    final albums = container.read(albumsProvider.notifier);
    albumA = await albums.create('初始图库');
    albumB = await albums.create('其他图库');
    container.read(desktopLibraryProvider.notifier).choose(albumA);
    container.read(generateProvider.notifier).setPrompts(positive: '当前草稿');
  });

  tearDown(() {
    container.dispose();
    stores.flushNow();
  });

  Finder key(String value) => find.byKey(ValueKey(value));

  Future<void> drain(WidgetTester tester, bool Function() done) async {
    await pumpUntil(tester, done, reason: 'Import operation must finish');
  }

  Future<void> mount(
    WidgetTester tester,
    Uint8List bytes, {
    GalleryImportOrigin? origin,
    Size size = const Size(1100, 800),
  }) async {
    upscale.pending = Completer();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.macOS),
          home: ImportImagePanel(
            bytes: bytes,
            origin: origin,
            fileName: 'imported-image',
            displayName: 'imported-image',
          ),
        ),
      ),
    );
    await drain(
      tester,
      () =>
          tester
              .widget<OutlinedButton>(key('desktop-import-upscale'))
              .onPressed !=
          null,
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    stores.flushNow();
    var done = false;
    unawaited(
      Future.wait([
        stores.gallery.idle,
        stores.desktopOutput.idle,
        stores.albums.idle,
        stores.workspace.idle,
        stores.prefs.delete(key: '__test_drain'),
      ]).then((_) => done = true),
    );
    await drain(tester, () => done);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'JPEG import submits PNG at its actual size and saves a 2x result',
    (tester) async {
      await mount(tester, jpeg, size: const Size(700, 650));
      final before = container.read(generateProvider);
      final reverse = find.widgetWithText(OutlinedButton, '反推提示词');
      expect(
        tester.getTopLeft(key('desktop-import-upscale')).dx,
        greaterThan(tester.getTopLeft(reverse).dx),
      );
      await tester.tap(key('desktop-import-upscale'));
      await drain(tester, () => upscale.calls.isNotEmpty);
      final submitted = upscale.calls.single;
      expect((submitted.width, submitted.height), (64, 96));
      final decoded = img.decodePng(submitted.bytes)!;
      expect((decoded.width, decoded.height), (64, 96));
      expect(key('upscale-progress'), findsOneWidget);
      expect(key('upscale-parameters'), findsNothing);
      expect(
        tester.widget<OutlinedButton>(key('desktop-import-upscale')).onPressed,
        isNull,
      );
      upscale.pending.complete((png: output, width: 128, height: 192));
      await drain(
        tester,
        () =>
            container.read(galleryProvider).results.isNotEmpty &&
            key('upscale-progress').evaluate().isEmpty,
      );
      final result = container.read(galleryProvider).results.single;
      expect(result.badge, ResultBadge.upscaled2x);
      expect((result.width, result.height), (128, 192));
      expect(result.hasInput, isFalse);
      expect(
        container.read(albumsProvider).contains(albumA, result.id),
        isTrue,
      );
      expect(balance.refreshes, 1);
      expect(container.read(generateProvider), same(before));
      expect(find.byType(ImportImagePanel), findsOneWidget);
      final saved = await tester.runAsync(
        () => stores.gallery.readImage(result.id),
      );
      expect(img.decodePng(saved!)!.width, 128);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'PNG pixels, source snapshot and initial save target survive async changes',
    (tester) async {
      final input = GenerateState.initial().copyWith(prompt: '来源图片参数');
      final source = await tester.runAsync(
        () => container
            .read(galleryProvider.notifier)
            .addResultToGallery(
              bytes: png,
              width: 64,
              height: 96,
              seed: 54321,
              input: input,
              target: GallerySaveTarget.album(albumA),
            ),
      );
      await mount(
        tester,
        png,
        origin: GalleryImportOrigin(imageId: source!.id),
      );
      await tester.tap(key('desktop-import-upscale'));
      await drain(tester, () => upscale.calls.isNotEmpty);
      expect(upscale.calls.single.bytes, same(png));
      container.read(desktopLibraryProvider.notifier).choose(albumB);
      container.read(galleryProvider.notifier).select(source.id);
      upscale.pending.complete((png: output, width: 128, height: 192));
      await drain(tester, () => key('upscale-progress').evaluate().isEmpty);
      final result = container.read(galleryProvider).results.first;
      expect(result.badge, ResultBadge.upscaled2x);
      expect(result.seed, 54321);
      expect(result.input!.prompt, '来源图片参数');
      expect(
        container.read(albumsProvider).contains(albumA, result.id),
        isTrue,
      );
      expect(
        container.read(albumsProvider).contains(albumB, result.id),
        isFalse,
      );
      expect(container.read(galleryProvider).selectedId, source.id);
      expect(container.read(desktopLibraryProvider).choice, albumB);
      expect(container.read(generateProvider).prompt, '当前草稿');
      await finish(tester);
    },
  );

  testWidgets(
    'rapid repeated clicks submit once; failure restores the button for retry',
    (tester) async {
      await mount(tester, png);
      final click = tester
          .widget<OutlinedButton>(key('desktop-import-upscale'))
          .onPressed!;
      click();
      click();
      await drain(tester, () => upscale.calls.isNotEmpty);
      expect(upscale.calls, hasLength(1));
      upscale.pending.completeError(Exception('服务暂不可用'));
      await drain(
        tester,
        () =>
            key('upscale-progress').evaluate().isEmpty &&
            tester
                    .widget<OutlinedButton>(key('desktop-import-upscale'))
                    .onPressed !=
                null,
      );
      expect(find.textContaining('服务暂不可用'), findsOneWidget);
      expect(container.read(galleryProvider).results, isEmpty);
      expect(
        tester.widget<OutlinedButton>(key('desktop-import-upscale')).onPressed,
        isNotNull,
      );
      upscale.pending = Completer();
      await tester.tap(key('desktop-import-upscale'));
      await drain(tester, () => upscale.calls.length == 2);
      upscale.pending.complete((png: output, width: 128, height: 192));
      await drain(tester, () => key('upscale-progress').evaluate().isEmpty);
      expect(container.read(galleryProvider).results, hasLength(1));
      await finish(tester);
    },
  );

  for (final size in [(2048, 2048), (8, 8)]) {
    testWidgets(
      'unsupported ${size.$1}×${size.$2} import makes no paid request',
      (tester) async {
        final bytes = Uint8List.fromList(
          img.encodePng(img.Image(width: size.$1, height: size.$2)),
        );
        await mount(tester, bytes);
        await tester.tap(key('desktop-import-upscale'));
        await drain(
          tester,
          () => find.textContaining('超分失败').evaluate().isNotEmpty,
        );
        expect(upscale.calls, isEmpty);
        expect(container.read(galleryProvider).results, isEmpty);
        expect(key('upscale-progress'), findsNothing);
        expect(
          find.textContaining(size.$1 < 16 ? '不少于 16 像素' : '3,145,728 像素'),
          findsOneWidget,
        );
        await finish(tester);
      },
    );
  }
}
