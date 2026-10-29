import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/film_strip.dart';

void main() {
  final bytes = File('assets/app_icon.png').readAsBytesSync();
  late AppStores stores;
  late List<ResultImage> images;
  late String? selected;
  late StateSetter rebuild;
  final deleted = <String>[];
  ImageDropPayload? dropped;

  setUp(() {
    stores = AppStores.ephemeral();
    images = [
      for (var i = 0; i < 20; i++)
        ResultImage(
          id: 'gen$i',
          width: i.isEven ? 60 : 120,
          height: 90,
          seed: i,
          bytes: bytes,
        ),
    ];
    selected = 'gen0';
    deleted.clear();
    dropped = null;
  });
  tearDown(() => stores.flushForExit());

  Finder thumb(String id) => find.byKey(ValueKey('history-thumb-$id'));
  Finder close(String id) => find.byKey(ValueKey('history-delete-$id'));
  ScrollController scroll(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).controller!;
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStoresProvider.overrideWithValue(stores)],
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return Column(
                  children: [
                    Expanded(
                      child: DragTarget<ImageDropPayload>(
                        onAcceptWithDetails: (details) =>
                            dropped = details.data,
                        builder: (_, _, _) =>
                            const SizedBox.expand(key: ValueKey('receiver')),
                      ),
                    ),
                    FilmStrip(
                      results: images,
                      selectedId: selected,
                      desktop: true,
                      showMore: false,
                      onSelect: (id) => rebuild(() => selected = id),
                      onShare: (_) {},
                      onDelete: (id) => rebuild(() {
                        deleted.add(id);
                        images = images.where((r) => r.id != id).toList();
                        if (selected == id) selected = images.firstOrNull?.id;
                      }),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'mixed-width offscreen inserts and removals keep the same visible image',
    (tester) async {
      await mount(tester);
      scroll(tester).jumpTo(520);
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(thumb('gen7')).dx;
      final head = ResultImage(
        id: 'new',
        width: 120,
        height: 90,
        seed: 99,
        bytes: bytes,
      );
      rebuild(() => images = [head, ...images]);
      await tester.pump();
      expect(tester.getTopLeft(thumb('gen7')).dx, closeTo(before, .1));
      expect(scroll(tester).offset, closeTo(520 + 112, .1));
      await tester.pumpAndSettle();
      rebuild(() => images = images.where((r) => r.id != 'new').toList());
      await tester.pump();
      expect(tester.getTopLeft(thumb('gen7')).dx, closeTo(before, .1));
      await tester.pumpAndSettle();
      expect(scroll(tester).offset, closeTo(520, .1));
      expect(selected, 'gen0');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop two-click delete cancels on selection and removes only the chosen image',
    (tester) async {
      await mount(tester);
      await tester.tap(close('gen1'));
      await tester.pump();
      expect(deleted, isEmpty);
      await tester.tap(thumb('gen2'));
      await tester.pumpAndSettle();
      expect(selected, 'gen2');
      await tester.tap(close('gen1'));
      await tester.pump();
      expect(deleted, isEmpty);
      await tester.tap(close('gen1'));
      await tester.pump();
      expect(deleted, ['gen1']);
      expect(selected, 'gen2');
      // The shrinking tile is no longer a mouse or keyboard target.
      expect(close('gen1').hitTestable(), findsNothing);
      await tester.pumpAndSettle();
      expect(thumb('gen1'), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop drag still sends the original image to its drop target',
    (tester) async {
      await mount(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(thumb('gen1')),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(-30, -20));
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('receiver'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(dropped?.imageId, 'gen1');
      expect(dropped?.source, 'history');
      final imported = await dropped!.read();
      expect(imported.single.bytes, bytes);
      expect(selected, 'gen0');
      expect(deleted, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid removal and restoration finishes without duplicate or stale tiles',
    (tester) async {
      await mount(tester);
      final original = images;
      rebuild(() => images = images.where((r) => r.id != 'gen1').toList());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      rebuild(() => images = original);
      await tester.pumpAndSettle();
      expect(thumb('gen1'), findsOneWidget);
      expect(scroll(tester).offset, 0);
      final x = tester.getTopLeft(thumb('gen2')).dx;
      expect(x, closeTo(12 + 64 + 112, .1));
      expect(tester.takeException(), isNull);
      // Batch filtering removes all items at once, without retaining ghost tiles.
      rebuild(() {
        images = [];
        selected = null;
      });
      await tester.pumpAndSettle();
      expect(find.byType(ListView), findsOneWidget);
      expect(thumb('gen1'), findsNothing);
      expect(scroll(tester).offset, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
