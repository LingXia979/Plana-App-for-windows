import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/gallery_image_tile.dart';

void main() {
  late ScrollController scroll;
  var taps = 0;
  var holds = 0;
  var secondary = 0;
  final tile = find.byKey(const ValueKey('selection-tile'));

  Future<void> mount(WidgetTester tester) async {
    taps = holds = secondary = 0;
    scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 300,
                child: ListView(
                  controller: scroll,
                  children: [
                    Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox.square(
                        dimension: 128,
                        child: GalleryImageTile(
                          key: const ValueKey('selection-tile'),
                          result: ResultImage(
                            id: 'gesture-image',
                            width: 128,
                            height: 128,
                            seed: 1,
                            bytes: File(
                              'assets/app_icon.png',
                            ).readAsBytesSync(),
                          ),
                          longPressDuration: gallerySelectionHold,
                          onTap: () => taps++,
                          onLongPress: (_) => holds++,
                          onSecondaryTap: (_) => secondary++,
                        ),
                      ),
                    ),
                    const SizedBox(height: 1000),
                  ],
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
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('a short primary click taps; a held right click never selects', (
    tester,
  ) async {
    await mount(tester);
    var mouse = await tester.startGesture(
      tester.getCenter(tile),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 199));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(holds, 0);
    mouse = await tester.startGesture(
      tester.getCenter(tile),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(holds, 0);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(secondary, 1);
    expect(taps, 1);
    expect(holds, 0);
    await finish(tester);
  });

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      '${kind.name} movement or cancellation prevents a hold and tap',
      (tester) async {
        await mount(tester);
        final start = tester.getCenter(tile);
        var press = await tester.startGesture(start, kind: kind);
        await tester.pump(const Duration(milliseconds: 80));
        await press.moveBy(const Offset(60, 0));
        await tester.pump(const Duration(milliseconds: 250));
        await press.up();
        await tester.pumpAndSettle();
        expect(holds, 0);
        expect(taps, 0);
        press = await tester.startGesture(start, kind: kind);
        await tester.pump(const Duration(milliseconds: 80));
        await press.cancel();
        await tester.pump(const Duration(milliseconds: 250));
        expect(holds, 0);
        expect(taps, 0);
        await finish(tester);
      },
    );
  }

  testWidgets('scroll position changes cancel a stationary pressed image', (
    tester,
  ) async {
    await mount(tester);
    final mouse = await tester.startGesture(
      tester.getCenter(tile),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 80));
    scroll.jumpTo(24);
    await tester.pump(const Duration(milliseconds: 250));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(scroll.offset, 24);
    expect(holds, 0);
    expect(taps, 0);
    await finish(tester);
  });

  testWidgets('a wheel event cancels a hold even at a scroll boundary', (
    tester,
  ) async {
    await mount(tester);
    final point = tester.getCenter(tile);
    final mouse = await tester.startGesture(
      point,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 80));
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: point,
        scrollDelta: const Offset(0, -80),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(holds, 0);
    expect(taps, 0);
    await finish(tester);
  });

  testWidgets('a second touch cancels selection while beginning a pinch', (
    tester,
  ) async {
    await mount(tester);
    final point = tester.getCenter(tile);
    final first = await tester.startGesture(
      point,
      pointer: 1,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 80));
    // The second contact is outside the card: global pointer tracking still
    // cancels the first card's deadline before a gallery pinch begins.
    final second = await tester.startGesture(
      point + const Offset(180, 0),
      pointer: 2,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 250));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(holds, 0);
    expect(taps, 0);
    await finish(tester);
  });
}
