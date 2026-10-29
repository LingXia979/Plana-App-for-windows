import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/gallery/gallery_page.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/widgets/film_strip.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';
import 'package:plana_app/features/gallery/widgets/result_thumb.dart';

void main() {
  testWidgets('删除图库图片后预览页和胶片条保持在相邻作品', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final stores = (await tester.runAsync(() async => AppStores.ephemeral()))!;
    final container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(container.dispose);
    final gallery = container.read(galleryProvider.notifier);
    final bytes = File('assets/app_icon.png').readAsBytesSync();
    final ids = (await tester.runAsync(() async {
      final ids = [
        for (var i = 0; i < 4; i++)
          gallery.addResult(bytes: bytes, width: 64, height: 64, seed: i).id,
      ];
      await stores.gallery.idle;
      return ids;
    }))!;
    gallery.select(ids[2]);
    await tester.runAsync(() async {
      await stores.prefs.write(key: 'hint_save_longpress', value: '1');
      await stores.prefs.write(key: 'hint_strip_swipe', value: '1');
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: GalleryPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    void expectSelection(String id) {
      expect(container.read(galleryProvider).selectedId, id);
      expect(
        tester.widget<ResultChrome>(find.byType(ResultChrome)).result.id,
        id,
      );
      expect(tester.widget<FilmStrip>(find.byType(FilmStrip)).selectedId, id);
      final page = tester.widget<PageView>(find.byType(PageView));
      final index = container
          .read(galleryProvider)
          .results
          .indexWhere((r) => r.id == id);
      expect(page.controller?.page?.round(), index);
      expect(tester.takeException(), isNull);
    }

    expectSelection(ids[2]);
    await _deleteFromStrip(tester, container, ids[2]);
    await tester.pumpAndSettle();
    expectSelection(ids[1]); // 中间图片被删，停在相邻的旧图。

    await _deleteFromStrip(tester, container, ids[3]);
    await tester.pumpAndSettle();
    expectSelection(ids[1]); // 删除前面的其他图片，当前预览不变。

    tester.widget<FilmStrip>(find.byType(FilmStrip)).onSelect(ids[0]);
    await tester.pumpAndSettle();
    expectSelection(ids[0]);
    await _deleteFromStrip(tester, container, ids[0]);
    await tester.pumpAndSettle();
    expectSelection(ids[1]); // 最后一张被删，停在上一张。

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _flushStores(tester, stores);
  });

  testWidgets('删除图片后胶片条不滚回选中项', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final stores = (await tester.runAsync(() async => AppStores.ephemeral()))!;
    final container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(container.dispose);
    final gallery = container.read(galleryProvider.notifier);
    final bytes = File('assets/app_icon.png').readAsBytesSync();
    final ids = (await tester.runAsync(() async {
      final ids = [
        for (var i = 0; i < 16; i++)
          gallery.addResult(bytes: bytes, width: 64, height: 64, seed: i).id,
      ];
      await stores.gallery.idle;
      return ids;
    }))!;
    gallery.select(ids.last);
    await tester.runAsync(() async {
      await stores.prefs.write(key: 'hint_save_longpress', value: '1');
      await stores.prefs.write(key: 'hint_strip_swipe', value: '1');
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: GalleryPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final strip = find.byType(FilmStrip);
    final list = find.descendant(of: strip, matching: find.byType(ListView));
    final scroll = tester.widget<ListView>(list).controller!;
    scroll.jumpTo(500);
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(500, 1));

    await _deleteFromStrip(tester, container, ids[5]);
    await tester.pumpAndSettle();
    expect(container.read(galleryProvider).selectedId, ids.last);
    expect(scroll.offset, closeTo(500, 1));

    // 删的是视野左边那张:少了一格(88),视野里的图原地不动
    await _deleteFromStrip(tester, container, ids.last);
    await tester.pumpAndSettle();
    expect(container.read(galleryProvider).selectedId, ids[14]);
    expect(scroll.offset, closeTo(500 - _slot, 1));

    tester.widget<FilmStrip>(strip).onSelect(ids.first);
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(500)); // 主动选图仍会定位到选中项。

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _flushStores(tester, stores);
  });

  testWidgets('新图插到头部:滚开时视野不动,停在最左头时新图滑进来', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final stores = (await tester.runAsync(() async => AppStores.ephemeral()))!;
    final container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(container.dispose);
    final gallery = container.read(galleryProvider.notifier);
    final bytes = File('assets/app_icon.png').readAsBytesSync();
    final ids = (await tester.runAsync(() async {
      final ids = [
        for (var i = 0; i < 16; i++)
          gallery.addResult(bytes: bytes, width: 64, height: 64, seed: i).id,
      ];
      await stores.gallery.idle;
      return ids;
    }))!;
    gallery.select(ids[8]);
    await tester.runAsync(() async {
      await stores.prefs.write(key: 'hint_save_longpress', value: '1');
      await stores.prefs.write(key: 'hint_strip_swipe', value: '1');
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: GalleryPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final strip = find.byType(FilmStrip);
    final list = find.descendant(of: strip, matching: find.byType(ListView));
    final scroll = tester.widget<ListView>(list).controller!;
    scroll.jumpTo(500);
    await tester.pumpAndSettle();

    await _flushStores(tester, stores);
    await tester.runAsync(() async {
      gallery.addResult(
        bytes: bytes,
        width: 64,
        height: 64,
        seed: 99,
        select: false,
      );
      await stores.gallery.idle;
    });
    await tester.pump();
    expect(scroll.offset, closeTo(500 + _slot, 1));
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(500 + _slot, 1));

    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    final head = find.descendant(
      of: strip,
      matching: find.byWidgetPredicate(
        (w) => w is ResultThumb && w.result.id == ids.last,
      ),
    );
    final x0 = tester.getTopLeft(head).dx;
    await _flushStores(tester, stores);
    await tester.runAsync(() async {
      gallery.addResult(
        bytes: bytes,
        width: 64,
        height: 64,
        seed: 100,
        select: false,
      );
      await stores.gallery.idle;
    });
    await tester.pump();
    // 新图从 0 宽长起:这一帧原来打头那张还没动,之后被推开一格
    expect(scroll.offset, 0);
    expect(tester.getTopLeft(head).dx, closeTo(x0, 1));
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(tester.getTopLeft(head).dx, closeTo(x0 + _slot, 1));

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _flushStores(tester, stores);
  });
}

/// 方图在胶片条上的一格:图宽 72 + 内衬与边框 8 + 分隔 8。
const _slot = 88.0;

// Windows verifies the actual file deletion before removing the gallery record.
// Let disk I/O and thumbnail encoding finish outside the widget test's fake clock.
Future<void> _deleteFromStrip(
  WidgetTester tester,
  ProviderContainer container,
  String id,
) async {
  tester.widget<FilmStrip>(find.byType(FilmStrip)).onDelete(id);
  for (var i = 0; i < 500; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (!container.read(galleryProvider).results.any((r) => r.id == id)) return;
  }
  fail('Image deletion did not finish: $id');
}

Future<void> _flushStores(WidgetTester tester, AppStores stores) async {
  var done = false;
  unawaited(stores.flushForExit().then((_) => done = true));
  for (var i = 0; i < 500 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done, isTrue);
}
