import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
import 'package:plana_app/features/gallery/gallery_page.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/widgets/film_strip.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/generation_controller.dart';

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

  @override
  Stream<NaiFrame> generateImageStream({
    required String token,
    required Map<String, dynamic> body,
    GenAbort? abort,
  }) {
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

class _Gallery extends GalleryNotifier {
  void unload() => state = state.copyWith(
    results: [for (final image in state.results) image.stripped()],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer c;
  late _Frames client;
  late String album;
  late List<String> old;
  late Uint8List resultBytes;
  late _Gallery gallery;
  final capture = GlobalKey();
  var disposed = false;

  setUp(() async {
    disposed = false;
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('plana_desktop_selection_');
    stores = await AppStores.open(rootOverride: root);
    for (final hint in ['hint_save_longpress', 'hint_strip_swipe']) {
      await stores.prefs.write(key: hint, value: '1');
    }
    client = _Frames();
    gallery = _Gallery();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        authModeProvider.overrideWith(_Auth.new),
        naiKeysStoreProvider.overrideWith(_Keys.new),
        naiClientProvider.overrideWith((ref, base) => client),
        galleryProvider.overrideWith(() => gallery),
      ],
    );
    await c.read(authModeProvider.future);
    await c.read(naiKeysStoreProvider.future);
    c.read(desktopLibraryProvider.notifier).choose(null);
    album = await c.read(albumsProvider.notifier).create('test');
    old = [];
    for (var i = 0; i < 4; i++) {
      final bytes = Uint8List.fromList(
        img.encodePng(
          img.Image(width: 1024, height: 1024)
            ..clear(img.ColorRgb8(50 + i * 50, 0, 0)),
        ),
      );
      old.add(
        (await c
                .read(galleryProvider.notifier)
                .addResultToGallery(
                  bytes: bytes,
                  width: 1024,
                  height: 1024,
                  seed: i,
                  input: c.read(generateProvider),
                  target: GallerySaveTarget.album(album),
                ))
            .id,
      );
    }
    resultBytes = Uint8List.fromList(
      img.encodePng(
        img.Image(width: 1024, height: 1024)..clear(img.ColorRgb8(0, 0, 255)),
      ),
    );
  });

  tearDown(() async {
    if (client.frames.hasListener) {
      await client.frames.close();
    } else {
      unawaited(client.frames.close());
    }
    if (!disposed) c.dispose();
    stores.flushNow();
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: GalleryPage(desktop: true)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final scope in ['all', 'album']) {
    for (final selected in [3, 1]) {
      for (final hydrated in [false, true]) {
        for (final wait in [Duration.zero, const Duration(seconds: 30)]) {
          testWidgets(
            '$scope generation from $selected cold=$hydrated after ${wait.inSeconds}s keeps the new image selected',
            (tester) async {
              c
                  .read(desktopLibraryProvider.notifier)
                  .choose(scope == 'all' ? null : album);
              // Start the controller on page 2, then browse the newest image.
              // In a named album, the generated result replaces that image at
              // index 0 only after membership is saved: the selected identity
              // changes without the index changing. Rebuilt pages must not
              // return to the controller's original page 2.
              c.read(galleryProvider.notifier).select(old[1]);
              if (hydrated) gallery.unload();
              await mount(tester);
              c.read(galleryProvider.notifier).select(old[selected]);
              await tester.pumpAndSettle();
              expect(c.read(galleryViewProvider).selectedId, old[selected]);
              late Future<GenOutcome> generation;
              await tester.runAsync(() async {
                generation = c
                    .read(generationProvider.notifier)
                    .generate(
                      // Replay the stored snapshot for the disk-loaded cases.
                      using: hydrated
                          ? await stores.gallery.readInput(old[selected])
                          : null,
                    );
                await client.started.future.timeout(const Duration(seconds: 5));
              });
              await tester.pump(wait);
              client.frames.add((step: 27, isFinal: false, bytes: resultBytes));
              await tester.pump(const Duration(milliseconds: 50));
              client.frames.add((step: 28, isFinal: true, bytes: resultBytes));
              GenOutcome? outcome;
              unawaited(generation.then((value) => outcome = value));
              for (var i = 0; i < 200 && outcome == null; i++) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 10)),
                );
                await tester.pump(const Duration(milliseconds: 16));
              }
              expect(outcome, GenOutcome.ok);
              await tester.pumpAndSettle(
                const Duration(milliseconds: 100),
                EnginePhase.sendSemanticsUpdate,
                const Duration(seconds: 5),
              );
              final result = c.read(galleryProvider).results.first;
              expect(c.read(galleryProvider).selectedId, result.id);
              expect(
                tester
                    .widget<ResultChrome>(find.byType(ResultChrome))
                    .result
                    .id,
                result.id,
              );
              expect(
                tester.widget<FilmStrip>(find.byType(FilmStrip)).selectedId,
                result.id,
              );
              final center = tester.getCenter(find.byType(PageView));
              final pixel = await tester.runAsync(() async {
                await Future<void>.delayed(const Duration(milliseconds: 30));
                await tester.pump();
                final boundary =
                    capture.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final image = await boundary.toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                );
                final offset =
                    (center.dy.round() * image.width + center.dx.round()) * 4;
                final pixel = bytes!.buffer.asUint8List().sublist(
                  offset,
                  offset + 3,
                );
                final captureDir =
                    Platform.environment['PLANA_GALLERY_CAPTURE_DIR'];
                if (captureDir != null &&
                    scope == 'album' &&
                    selected == 3 &&
                    !hydrated) {
                  final png = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  final file = File(
                    '$captureDir/album-after-${wait.inSeconds}s.png',
                  );
                  await file.parent.create(recursive: true);
                  await file.writeAsBytes(png!.buffer.asUint8List());
                }
                image.dispose();
                return pixel;
              });
              expect(pixel, [
                0,
                0,
                255,
              ], reason: 'canvas pixels must match the selected new image');
              expect(
                tester.widget<PageView>(find.byType(PageView)).controller!.page,
                0,
              );
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox());
              await tester.pumpAndSettle();
              // The search cache has a 400 ms debounce. Generation did real IO
              // in runAsync, so drain both clocks before removing its fixture.
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 450)),
              );
              await tester.pump(const Duration(milliseconds: 450));
              c.dispose();
              disposed = true;
              var flushed = false;
              unawaited(stores.flushForExit().then((_) => flushed = true));
              for (var i = 0; i < 200 && !flushed; i++) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 10)),
                );
                await tester.pump();
              }
              expect(flushed, isTrue);
              await tester.runAsync(() async {
                for (var attempt = 0; ; attempt++) {
                  try {
                    await root.delete(recursive: true);
                    break;
                  } on FileSystemException {
                    if (attempt == 9) rethrow;
                    await Future<void>.delayed(
                      const Duration(milliseconds: 30),
                    );
                  }
                }
              });
            },
          );
        }
      }
    }
  }
}
