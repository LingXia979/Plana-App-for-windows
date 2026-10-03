import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_gallery_browser.dart';
import 'package:plana_app/features/desktop/desktop_gallery_page.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/gallery_groups.dart';
import 'package:plana_app/features/gallery/gallery_search.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';

const _tags = <String, List<GroupTag>>{
  'sample0': [(key: 'first', label: '第一组')],
  'sample1': [(key: 'first', label: '第一组')],
  'sample2': [(key: 'second', label: '第二组')],
  'sample3': [(key: 'second', label: '第二组')],
};

class _Gallery extends GalleryNotifier {
  _Gallery(this.images);
  final List<ResultImage> images;

  @override
  GalleryState build() => GalleryState(results: images, selectedId: 'sample0');
}

class _Search extends GallerySearchNotifier {
  @override
  GallerySearchState build() => const GallerySearchState(byId: {});
}

class _Characters extends GalleryCharTags {
  @override
  Future<Map<String, List<GroupTag>>> build() async => _tags;
}

class _Styles extends GalleryStyleTags {
  @override
  Future<Map<String, List<GroupTag>>> build() async => _tags;
}

void main() {
  late AppStores stores;
  late ProviderContainer container;
  setUp(() {
    stores = AppStores.ephemeral();
    final bytes = File('assets/app_icon.png').readAsBytesSync();
    final images = [
      for (var i = 0; i < 4; i++)
        ResultImage(
          id: 'sample$i',
          width: 100,
          height: 100,
          seed: i + 1,
          createdAt: DateTime.now().millisecondsSinceEpoch - i * 1000,
          bytes: bytes,
        ),
    ];
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        galleryProvider.overrideWith(() => _Gallery(images)),
        gallerySearchProvider.overrideWith(_Search.new),
        galleryCharTagsProvider.overrideWith(_Characters.new),
        galleryStyleTagsProvider.overrideWith(_Styles.new),
      ],
    );
    container.read(desktopLibraryProvider.notifier).choose(null);
  });
  tearDown(() {
    stores.flushNow();
    container.dispose();
  });

  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> mount(
    WidgetTester tester, {
    required bool quick,
    bool style = false,
  }) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: quick
                ? const Align(
                    alignment: Alignment.topRight,
                    child: SizedBox(width: 320, child: DesktopLibraryButton()),
                  )
                : const DesktopGalleryBrowser(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      key(quick ? 'desktop-history-browse' : 'desktop-library-card-all'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('分组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(style ? '按画风' : '按角色'));
    await tester.pumpAndSettle();
    expect(key('group-card-first'), findsOneWidget);
    expect(key('group-card-second'), findsOneWidget);
    expect(find.text('多选'), findsNothing);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    stores.flushNow();
    await tester.runAsync(() async {
      await stores.gallery.idle;
      await stores.albums.idle;
    });
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  for (final quick in [true, false]) {
    final page = quick ? 'quick browser' : 'full gallery';
    for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
      testWidgets(
        '$page ${kind.name} selection selects a whole group without opening it',
        (tester) async {
          await mount(
            tester,
            quick: quick,
            style: kind == PointerDeviceKind.touch,
          );
          final imagePrefix = quick ? 'quick-gallery-image' : 'desktop-image';
          final press = await tester.startGesture(
            tester.getCenter(key('group-card-first')),
            kind: kind,
          );
          expect(find.textContaining('已选 '), findsNothing);
          expect(key('group-card-first'), findsOneWidget);
          if (kind == PointerDeviceKind.touch) {
            await tester.pump(const Duration(milliseconds: 199));
            expect(find.textContaining('已选 '), findsNothing);
            await tester.pump(const Duration(milliseconds: 2));
          } else {
            await press.moveBy(const Offset(5, 0));
            await tester.pump();
          }
          expect(find.text('已选 2 张'), findsOneWidget);
          expect(key('$imagePrefix-sample0'), findsNothing);
          await press.up();
          await tester.pumpAndSettle();
          expect(find.text('已选 2 张'), findsOneWidget);
          expect(key('group-card-first'), findsOneWidget);
          expect(key('group-card-second'), findsOneWidget);
          expect(key('desktop-image-viewer'), findsNothing);
          await tester.tap(key('group-card-second'));
          await tester.pumpAndSettle();
          expect(find.text('已选 4 张'), findsOneWidget);
          await tester.tap(key('group-card-second'));
          await tester.pumpAndSettle();
          expect(find.text('已选 2 张'), findsOneWidget);
          await tester.tap(find.text('完成'));
          await tester.pumpAndSettle();
          expect(find.textContaining('已选 '), findsNothing);
          expect(find.text('多选'), findsNothing);
          await tester.tap(key('group-card-first'));
          await tester.pumpAndSettle();
          expect(key('group-card-first'), findsNothing);
          expect(key('$imagePrefix-sample0'), findsOneWidget);
          expect(key('$imagePrefix-sample1'), findsOneWidget);
          expect(key('$imagePrefix-sample2'), findsNothing);
          expect(container.read(galleryProvider).selectedId, 'sample0');
          await tester.tap(find.byTooltip('回到全部'));
          await tester.pumpAndSettle();
          expect(key('group-card-first'), findsOneWidget);
          await finish(tester);
        },
      );
    }

    testWidgets(
      '$page wheel input cancels a pending group hold even at the top boundary',
      (tester) async {
        await mount(tester, quick: quick);
        final point = tester.getCenter(key('group-card-first'));
        final press = await tester.startGesture(
          point,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 80));
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: point,
            scrollDelta: const Offset(0, -100),
            kind: PointerDeviceKind.mouse,
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        await press.up();
        await tester.pumpAndSettle();
        expect(find.textContaining('已选 '), findsNothing);
        expect(key('group-card-first'), findsOneWidget);
        expect(key('group-card-second'), findsOneWidget);
        expect(container.read(galleryProvider).selectedId, 'sample0');
        await finish(tester);
      },
    );
  }
}
