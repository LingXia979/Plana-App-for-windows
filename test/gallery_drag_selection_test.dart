import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/gallery_drag_selection.dart';
import 'package:plana_app/features/gallery/widgets/gallery_image_tile.dart';

void main() {
  late ScrollController scroll;
  late GlobalKey<GalleryDragSelectionState> selectionKey;
  late StateSetter rebuild;
  late List<String> order;
  late Set<String> selected;
  var enabled = true;
  var foreign = false;
  var changes = 0;

  Finder tile(int id) => find.byKey(ValueKey('tile-$id'));

  Future<void> mount(WidgetTester tester) async {
    scroll = ScrollController();
    selectionKey = GlobalKey<GalleryDragSelectionState>();
    order = [for (var i = 0; i < 60; i++) 'image$i'];
    selected = {};
    enabled = true;
    foreign = false;
    changes = 0;
    addTearDown(scroll.dispose);
    final bytes = File('assets/app_icon.png').readAsBytesSync();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return SizedBox(
                    width: 316,
                    height: 300,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: GalleryDragSelection(
                            key: selectionKey,
                            enabled: enabled,
                            scrollController: scroll,
                            order: order,
                            selected: selected,
                            onChanged: (next) => setState(() {
                              selected = next;
                              changes++;
                            }),
                            child: GridView.builder(
                              key: const ValueKey('selection-grid'),
                              controller: scroll,
                              padding: EdgeInsets.zero,
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 3,
                                    mainAxisSpacing: 8,
                                    crossAxisSpacing: 8,
                                  ),
                              itemCount: order.length,
                              itemBuilder: (context, index) {
                                final id = order[index];
                                final number = int.parse(id.substring(5));
                                return MetaData(
                                  metaData: id,
                                  child: GalleryImageTile(
                                    key: ValueKey('tile-$number'),
                                    result: ResultImage(
                                      id: id,
                                      width: 100,
                                      height: 100,
                                      seed: number,
                                      bytes: bytes,
                                    ),
                                    selecting: enabled,
                                    mouseDragSelect: true,
                                    picked: selected.contains(id),
                                    onTap: () => setState(() {
                                      if (!selected.add(id)) {
                                        selected.remove(id);
                                      }
                                    }),
                                    longPressDuration: gallerySelectionHold,
                                    onLongPress: (_) {
                                      setState(() => enabled = true);
                                      selectionKey.currentState!.beginHold(id);
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        if (foreign)
                          const Positioned(
                            left: 216,
                            top: 0,
                            width: 100,
                            height: 100,
                            child: MetaData(
                              // This ID is valid in the current order, but
                              // this render object is outside the selector.
                              metaData: 'image8',
                              behavior: HitTestBehavior.opaque,
                              child: ColoredBox(color: Colors.black),
                            ),
                          ),
                      ],
                    ),
                  );
                },
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

  Future<TestGesture> sweep(WidgetTester tester, int from, int to) async {
    final mouse = await tester.startGesture(
      tester.getCenter(tile(from)),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(tester.getCenter(tile(to)));
    await tester.pump();
    return mouse;
  }

  testWidgets(
    'several pointer updates within one frame still restore a shrinking range',
    (tester) async {
      await mount(tester);
      final mouse = await sweep(tester, 0, 2);
      expect(selected, {'image0', 'image1', 'image2'});
      await mouse.moveTo(tester.getCenter(tile(5)));
      await mouse.moveTo(tester.getCenter(tile(2)));
      await tester.pump();
      expect(selected, {'image0', 'image1', 'image2'});
      await mouse.up();
      await finish(tester);
    },
  );

  testWidgets(
    'scope order changes cancel a held sweep even if the list is mutated in place',
    (tester) async {
      await mount(tester);
      final nextPoint = tester.getCenter(tile(5));
      final mouse = await sweep(tester, 0, 2);
      expect(selected, {'image0', 'image1', 'image2'});
      final before = changes;
      rebuild(() => order.insert(0, order.removeLast()));
      await tester.pump();
      await mouse.moveTo(nextPoint);
      await tester.pump(const Duration(milliseconds: 250));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(changes, before);
      expect(selected, {'image0', 'image1', 'image2'});
      await finish(tester);
    },
  );

  testWidgets(
    'disabling selection stops edge scrolling and cannot resume within the same press',
    (tester) async {
      await mount(tester);
      final viewport = tester.getRect(find.byKey(selectionKey));
      final mouse = await sweep(tester, 0, 2);
      await mouse.moveTo(Offset(viewport.right - 50, viewport.bottom + 12));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scroll.offset, greaterThan(100));
      rebuild(() => enabled = false);
      await tester.pump();
      final stopped = scroll.offset;
      final before = Set<String>.of(selected);
      await tester.pump(const Duration(milliseconds: 300));
      expect(scroll.offset, stopped);
      rebuild(() => enabled = true);
      await tester.pump();
      await mouse.moveBy(const Offset(-50, -40));
      await tester.pump(const Duration(milliseconds: 250));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(selected, before);
      expect(scroll.offset, stopped);
      await finish(tester);
    },
  );

  testWidgets(
    'hit testing ignores an external metadata target with a valid image ID',
    (tester) async {
      await mount(tester);
      final point = tester.getCenter(tile(2));
      final mouse = await tester.startGesture(
        tester.getCenter(tile(0)),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(25, 0));
      await tester.pump();
      expect(selected, {'image0'});
      rebuild(() => foreign = true);
      await tester.pump();
      await mouse.moveTo(point);
      await tester.pump();
      expect(selected, {'image0'});
      rebuild(() => foreign = false);
      await tester.pump();
      await mouse.moveTo(point + const Offset(1, 0));
      await tester.pump();
      expect(selected, {'image0', 'image1', 'image2'});
      await mouse.up();
      await finish(tester);
    },
  );

  testWidgets(
    'a horizontal sweep starting near the edge waits for vertical intent',
    (tester) async {
      await mount(tester);
      final mouse = await sweep(tester, 6, 8);
      expect(selected, {'image6', 'image7', 'image8'});
      await tester.pump(const Duration(milliseconds: 400));
      expect(scroll.offset, 0);
      await mouse.moveBy(const Offset(0, 40));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scroll.offset, greaterThan(100));
      final expected = Set<String>.of(selected);
      selectionKey.currentState!.cancel();
      final stopped = scroll.offset;
      await tester.pump(const Duration(milliseconds: 300));
      await mouse.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(scroll.offset, stopped);
      expect(selected, expected);
      await mouse.up();
      await finish(tester);
    },
  );

  testWidgets(
    'first mouse movement can sweep vertically, auto-scroll, then stop on release',
    (tester) async {
      await mount(tester);
      rebuild(() => enabled = false);
      await tester.pump();
      final press = await tester.startGesture(
        tester.getCenter(tile(0)),
        kind: PointerDeviceKind.mouse,
      );
      await press.moveTo(tester.getCenter(tile(6)));
      await tester.pump();
      expect(selected, {for (var i = 0; i <= 6; i++) 'image$i'});
      final viewport = tester.getRect(find.byKey(selectionKey));
      await press.moveTo(Offset(viewport.right - 50, viewport.bottom + 15));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scroll.offset, greaterThan(100));
      expect(selected.length, greaterThan(7));
      await press.up();
      final stopped = scroll.offset;
      final finalSelection = Set<String>.of(selected);
      await tester.pump(const Duration(milliseconds: 300));
      expect(scroll.offset, stopped);
      expect(selected, finalSelection);
      await finish(tester);
    },
  );

  testWidgets(
    'wheel interrupts the first mouse sweep without further selection',
    (tester) async {
      await mount(tester);
      rebuild(() => enabled = false);
      await tester.pump();
      final press = await tester.startGesture(
        tester.getCenter(tile(0)),
        kind: PointerDeviceKind.mouse,
      );
      await press.moveTo(tester.getCenter(tile(1)));
      await tester.pump();
      final before = Set<String>.of(selected);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(tile(1)),
          scrollDelta: const Offset(0, 12),
        ),
      );
      await tester.pump();
      await press.moveTo(tester.getCenter(tile(2)));
      await tester.pump();
      expect(selected, before);
      await press.up();
      await finish(tester);
    },
  );

  for (final (from, to) in [(0, 2), (2, 0), (0, 3), (3, 0), (0, 4)]) {
    testWidgets('first mouse sweep $from to $to starts without a hold', (
      tester,
    ) async {
      await mount(tester);
      rebuild(() => enabled = false);
      await tester.pump();
      final mouse = await sweep(tester, from, to);
      final first = from < to ? from : to;
      final last = from < to ? to : from;
      expect(selected, {for (var i = first; i <= last; i++) 'image$i'});
      expect(enabled, isTrue);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(selected, {for (var i = first; i <= last; i++) 'image$i'});
      await finish(tester);
    });
  }

  testWidgets('mouse jitter and a stationary hold remain a click', (
    tester,
  ) async {
    await mount(tester);
    rebuild(() => enabled = false);
    await tester.pump();
    final origin = tester.getCenter(tile(0));
    final mouse = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
    );
    for (var i = 0; i < 4; i++) {
      await mouse.moveTo(origin + const Offset(3, 0));
      await mouse.moveTo(origin);
    }
    await tester.pump(const Duration(milliseconds: 500));
    expect(enabled, isFalse);
    expect(selected, isEmpty);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(enabled, isFalse);
    expect(selected, {'image0'});
    await finish(tester);
  });

  testWidgets('touch still waits 200ms before a vertical selection sweep', (
    tester,
  ) async {
    await mount(tester);
    rebuild(() => enabled = false);
    await tester.pump();
    final touch = await tester.startGesture(tester.getCenter(tile(0)));
    await tester.pump(const Duration(milliseconds: 199));
    expect(enabled, isFalse);
    expect(selected, isEmpty);
    await tester.pump(const Duration(milliseconds: 2));
    expect(selected, {'image0'});
    await touch.moveTo(tester.getCenter(tile(3)));
    await tester.pump();
    expect(selected, {'image0', 'image1', 'image2', 'image3'});
    await touch.up();
    await finish(tester);
  });

  testWidgets(
    'Escape cancels a first sweep and cannot restart the same press',
    (tester) async {
      await mount(tester);
      rebuild(() => enabled = false);
      await tester.pump();
      final mouse = await sweep(tester, 0, 2);
      final before = Set<String>.of(selected);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await mouse.moveTo(tester.getCenter(tile(5)));
      await tester.pump();
      expect(selected, before);
      await mouse.up();
      await finish(tester);
    },
  );

  testWidgets('Escape before threshold prevents entering selection', (
    tester,
  ) async {
    await mount(tester);
    rebuild(() => enabled = false);
    await tester.pump();
    final mouse = await tester.startGesture(
      tester.getCenter(tile(0)),
      kind: PointerDeviceKind.mouse,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await mouse.moveTo(tester.getCenter(tile(2)));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(enabled, isFalse);
    expect(selected, isEmpty);
    await finish(tester);
  });

  testWidgets('secondary mouse dragging never starts selection', (
    tester,
  ) async {
    await mount(tester);
    rebuild(() => enabled = false);
    await tester.pump();
    final mouse = await tester.startGesture(
      tester.getCenter(tile(0)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await mouse.moveTo(tester.getCenter(tile(2)));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(enabled, isFalse);
    expect(selected, isEmpty);
    await finish(tester);
  });

  testWidgets(
    'disposing a selector during edge scrolling removes its ticker and pointer route',
    (tester) async {
      await mount(tester);
      final viewport = tester.getRect(find.byKey(selectionKey));
      final mouse = await sweep(tester, 0, 2);
      await mouse.moveTo(Offset(viewport.right - 50, viewport.bottom + 20));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(scroll.offset, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 300));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
