import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/film_strip.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'FilmStrip renders the repaired disk thumbnail without changing selection',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('plana_film_thumb_'),
      ))!;
      final red = Uint8List.fromList(
        img.encodePng(
          img.Image(width: 8, height: 12)..clear(img.ColorRgb8(255, 0, 0)),
        ),
      );
      final green = Uint8List.fromList(
        img.encodePng(
          img.Image(width: 8, height: 12)..clear(img.ColorRgb8(0, 255, 0)),
        ),
      );
      final stores = (await tester.runAsync(() async {
        final stores = await AppStores.open(rootOverride: root);
        final images = [
          ResultImage(
            id: 'gen1',
            width: 8,
            height: 12,
            seed: 1,
            createdAt: 1,
            bytes: red,
          ),
          ResultImage(
            id: 'gen2',
            width: 8,
            height: 12,
            seed: 2,
            createdAt: 2,
            bytes: green,
          ),
        ];
        for (final image in images) {
          await stores.gallery.persistResult(image);
        }
        stores.gallery.scheduleIndex(
          results: images,
          selectedId: 'gen2',
          seq: 3,
        );
        await stores.gallery.flushIndex();
        final source = await stores.gallery.imageFileForPreview('gen1').stat();
        await File('${root.path}/gallery/thumbs/gen1.json').writeAsString(
          jsonEncode({
            'v': 1,
            'size': source.size,
            'modified': source.modified.microsecondsSinceEpoch,
          }),
        );
        // Reproduce the reported state: the original and its v1 signature are
        // unchanged, but a different image overwrote the cached thumbnail.
        await File('${root.path}/gallery/thumbs/gen1.png').writeAsBytes(
          img.encodePng(
            img.Image(width: 256, height: 256)..clear(img.ColorRgb8(0, 0, 255)),
          ),
        );
        await stores.gallery.load();
        return stores;
      }))!;
      final container = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          desktopModeProvider.overrideWithValue(true),
        ],
      );
      addTearDown(() async {
        container.dispose();
        stores.flushNow();
        await stores.gallery.idle;
        await stores.workspace.idle;
        await stores.assistant.idle;
        await stores.desktopOutput.idle;
        await stores.albums.idle;
        expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
        expect(
          root.uri.pathSegments.where((s) => s.isNotEmpty).last,
          startsWith('plana_film_thumb_'),
        );
        await root.delete(recursive: true);
      });
      expect(
        stores.gallery.initialResults.every((image) => image.bytes == null),
        isTrue,
      );
      final before = container.read(galleryProvider);
      final selected = <String>[];
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  final gallery = ref.watch(galleryProvider);
                  return Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 400,
                      child: FilmStrip(
                        results: gallery.results,
                        selectedId: gallery.selectedId,
                        desktop: true,
                        showMore: false,
                        onSelect: (id) {
                          selected.add(id);
                          ref.read(galleryProvider.notifier).select(id);
                        },
                        onShare: (_) {},
                        onDelete: (_) {},
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      // Let real file/isolate work and the widget test clock both advance. The
      // provider is first read by FilmStrip, with no canned preview override.
      final rawImage = find.descendant(
        of: find.byKey(const ValueKey('history-thumb-gen1')),
        matching: find.byType(RawImage),
      );
      ui.Image? decoded;
      for (var attempt = 0; attempt < 200 && decoded == null; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (rawImage.evaluate().isNotEmpty) {
          decoded = tester.widget<RawImage>(rawImage).image;
        }
      }
      expect(
        decoded,
        isNotNull,
        reason: 'FilmStrip must decode its disk image',
      );
      final pixels = (await tester.runAsync(
        () => decoded!.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      final center =
          ((decoded!.height ~/ 2) * decoded.width + decoded.width ~/ 2) * 4;
      expect(
        pixels.buffer.asUint8List(pixels.offsetInBytes + center, 4),
        [255, 0, 0, 255],
        reason:
            'The rendered thumbnail must be the red original, not blue cache',
      );
      expect(selected, isEmpty);
      expect(container.read(galleryProvider), same(before));
      expect(container.read(galleryProvider).selectedId, 'gen2');
      expect(
        await tester.runAsync(() => stores.gallery.readImage('gen1')),
        red,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
