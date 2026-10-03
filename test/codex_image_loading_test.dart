import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/features/inspiration/codex/codex_image_loading.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CodexImageLoadController loading;
  late ScrollController scroll;
  late ui.Image pixels;
  late Map<String, int> starts;
  late Map<int, int> builds;
  var extraId = 'extra-a';

  Finder keyed(String key) => find.byKey(ValueKey(key));
  int getStarts() => starts.values.fold(0, (sum, count) => sum + count);

  Future<void> prepare(WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    loading = CodexImageLoadController();
    scroll = ScrollController(
      onAttach: loading.attach,
      onDetach: loading.detach,
    );
    starts = {};
    builds = {};
    pixels = (await tester.runAsync(() async {
      final png = Uint8List.fromList(
        img.encodePng(img.Image(width: 4, height: 4)),
      );
      final codec = await ui.instantiateImageCodec(png);
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    }))!;
    addTearDown(() {
      loading.dispose();
      scroll.dispose();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      pixels.dispose();
    });
  }

  ImageProvider<Object> provider(
    String id, {
    Future<ImageInfo> Function()? frame,
  }) => _CountingProvider(id, starts, pixels, frame: frame);

  Widget thumbnail(String id, {ImageProvider<Object>? source, Key? key}) =>
      CodexDeferredImage(
        key: key ?? ValueKey('thumbnail-$id'),
        controller: loading,
        builder: (decorate) => Image(
          image: decorate(source ?? provider(id)),
          width: 32,
          height: 32,
          errorBuilder: (_, _, _) => const Text('image failed'),
        ),
      );

  Widget page({bool images = true, Widget? extra}) => MaterialApp(
    theme: ThemeData(platform: TargetPlatform.windows),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 360,
          height: 450,
          child: Column(
            children: [
              if (extra != null) SizedBox(height: 50, child: extra),
              Expanded(
                child: ScrollConfiguration(
                  behavior: const MaterialScrollBehavior().copyWith(
                    scrollbars: false,
                  ),
                  child: Scrollbar(
                    key: const ValueKey('codex-scrollbar'),
                    controller: scroll,
                    thumbVisibility: true,
                    interactive: true,
                    thickness: 12,
                    child: ListView.builder(
                      key: const ValueKey('codex-list'),
                      controller: scroll,
                      itemExtent: 100,
                      itemCount: 100,
                      scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                      itemBuilder: (_, index) {
                        builds.update(index, (n) => n + 1, ifAbsent: () => 1);
                        return Row(
                          children: [
                            Text('entry $index', key: ValueKey('title-$index')),
                            if (images) thumbnail('$index'),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'held scrollbar drag moves titles but queues uncached images until release',
    (tester) async {
      await prepare(tester);
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      final before = getStarts();
      final bar = tester.getRect(keyed('codex-scrollbar'));
      final gesture = await tester.startGesture(
        Offset(bar.right - 6, bar.top + 9),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      expect(scroll.offset, greaterThan(500));
      expect(scroll.position.isScrollingNotifier.value, isTrue);
      expect(loading.isPaused, isTrue);
      expect(loading.pendingCount, greaterThan(0));
      expect(keyed('title-0'), findsNothing);
      expect(find.textContaining('entry '), findsWidgets);
      expect(getStarts(), before);

      // A stationary thumb drag has no velocity but remains an active drag.
      await tester.pump(const Duration(milliseconds: 300));
      expect(getStarts(), before);
      expect(loading.isPaused, isTrue);
      final cardBuilds = Map<int, int>.of(builds);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 139));
      expect(getStarts(), before);
      await tester.pump(const Duration(milliseconds: 2));
      expect(getStarts() - before, inInclusiveRange(1, loading.startsPerFrame));
      await tester.pumpAndSettle();
      expect(getStarts(), greaterThan(before));
      expect(builds, cardBuilds); // Loading does not rebuild/filter the cards.
      expect(loading.pendingCount, 0);
      expect(starts.values.every((n) => n == 1), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'wheel bursts and jumpTo postpone starts until the last quiet period',
    (tester) async {
      await prepare(tester);
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      final before = getStarts();
      final point = tester.getCenter(keyed('codex-list'));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: const Offset(0, 700)),
      );
      await tester.pump();
      expect(scroll.offset, greaterThan(0));
      expect(loading.isPaused, isTrue);
      expect(getStarts(), before);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: const Offset(0, 700)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(getStarts(), before);
      scroll.jumpTo(2300);
      await tester.pump(const Duration(milliseconds: 100));
      expect(getStarts(), before);
      final currentTitles = tester
          .widgetList<Text>(find.textContaining('entry '))
          .map((t) => t.data)
          .toSet();
      expect(currentTitles, contains('entry 23'));
      await tester.pump(const Duration(milliseconds: 41));
      await tester.pumpAndSettle();
      expect(getStarts(), greaterThan(before));
      // Intermediate wheel destinations were disposed before they could load.
      expect(starts.containsKey('7'), isFalse);
      expect(starts.containsKey('14'), isFalse);
      expect(starts.containsKey('23'), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'decoded cache hits remain visible while new thumbnails are deferred',
    (tester) async {
      await prepare(tester);
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      final before = getStarts();
      scroll.jumpTo(2500);
      await tester.pump();
      // Flutter's outer ScrollAware provider defers a large jump for one frame
      // via _impliedVelocity. Let it reach our queue without advancing time.
      await tester.pump();
      expect(loading.pendingCount, greaterThan(0));
      scroll.jumpTo(0);
      await tester.pump();
      expect(loading.isPaused, isTrue);
      expect(getStarts(), before);
      final image = tester.widget<RawImage>(
        find.descendant(
          of: keyed('thumbnail-0'),
          matching: find.byType(RawImage),
        ),
      );
      expect(image.image, isNotNull);
      expect(loading.pendingCount, 0);
      await tester.pump(const Duration(milliseconds: 141));
      await tester.pumpAndSettle();
      expect(getStarts(), before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('touch inertia keeps new loads paused after the finger lifts', (
    tester,
  ) async {
    await prepare(tester);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    final before = getStarts();
    await tester.fling(keyed('codex-list'), const Offset(0, -500), 1800);
    await tester.pump(const Duration(milliseconds: 30));
    expect(scroll.offset, greaterThan(400));
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    expect(loading.isPaused, isTrue);
    expect(getStarts(), before);
    for (var i = 0; i < 100 && scroll.position.isScrollingNotifier.value; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(getStarts(), before);
    }
    expect(scroll.position.isScrollingNotifier.value, isFalse);
    await tester.pump(const Duration(milliseconds: 141));
    await tester.pumpAndSettle();
    expect(getStarts(), greaterThan(before));
    expect(starts.values.every((n) => n == 1), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a matching in-flight image is shared while paused without a new load',
    (tester) async {
      await prepare(tester);
      final completed = Completer<ImageInfo>();
      final source = provider('shared', frame: () => completed.future);
      final stream = source.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((image, _) => image.dispose());
      stream.addListener(listener);
      expect(starts['shared'], 1);
      await tester.pumpWidget(page(images: false));
      scroll.jumpTo(200);
      await tester.pump();
      await tester.pumpWidget(
        page(images: false, extra: thumbnail('shared', source: source)),
      );
      expect(loading.isPaused, isTrue);
      expect(loading.pendingCount, 0);
      expect(starts['shared'], 1);
      completed.complete(ImageInfo(image: pixels.clone()));
      await tester.pump();
      await tester.pump();
      final image = tester.widget<RawImage>(
        find.descendant(
          of: keyed('thumbnail-shared'),
          matching: find.byType(RawImage),
        ),
      );
      expect(image.image, isNotNull);
      expect(starts['shared'], 1);
      stream.removeListener(listener);
      await tester.pumpWidget(const SizedBox());
      expect(loading.isPaused, isFalse);
      expect(loading.pendingCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'replacing a queued source and disposing the card cancels obsolete requests',
    (tester) async {
      await prepare(tester);
      await tester.pumpWidget(page(images: false));
      scroll.jumpTo(100);
      await tester.pump();
      extraId = 'extra-a';
      await tester.pumpWidget(
        page(
          images: false,
          extra: thumbnail(extraId, key: const ValueKey('extra')),
        ),
      );
      expect(loading.pendingCount, 1);
      extraId = 'extra-b';
      await tester.pumpWidget(
        page(
          images: false,
          extra: thumbnail(extraId, key: const ValueKey('extra')),
        ),
      );
      expect(loading.pendingCount, 1);
      await tester.pump(const Duration(milliseconds: 141));
      await tester.pumpAndSettle();
      expect(starts['extra-a'], isNull);
      expect(starts['extra-b'], 1);

      scroll.jumpTo(200);
      await tester.pumpWidget(
        page(
          images: false,
          extra: thumbnail('extra-c', key: const ValueKey('extra')),
        ),
      );
      expect(loading.pendingCount, 1);
      await tester.pumpWidget(page(images: false));
      expect(loading.pendingCount, 0);
      await tester.pump(const Duration(milliseconds: 141));
      await tester.pumpAndSettle();
      expect(starts['extra-c'], isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late key callbacks and controller disposal cannot restart old work',
    (tester) async {
      await prepare(tester);
      final key = Completer<Object>();
      await tester.pumpWidget(
        page(
          images: false,
          extra: thumbnail(
            'late',
            source: _DelayedKeyProvider('late', starts, pixels, key.future),
            key: const ValueKey('extra'),
          ),
        ),
      );
      await tester.pumpWidget(
        page(
          images: false,
          extra: thumbnail('current', key: const ValueKey('extra')),
        ),
      );
      key.complete('probe-late');
      await tester.pumpAndSettle();
      expect(starts['late'], isNull);
      expect(starts['current'], 1);

      scroll.jumpTo(100);
      await tester.pumpWidget(
        page(
          images: false,
          extra: thumbnail('disposed', key: const ValueKey('extra')),
        ),
      );
      expect(loading.pendingCount, 1);
      loading.dispose();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(starts['disposed'], isNull);
      expect(loading.pendingCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

@immutable
class _CountingProvider extends ImageProvider<Object> {
  const _CountingProvider(this.id, this.starts, this.pixels, {this.frame});

  final String id;
  final Map<String, int> starts;
  final ui.Image pixels;
  final Future<ImageInfo> Function()? frame;

  @override
  Future<Object> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture('probe-$id');

  @override
  ImageStreamCompleter loadImage(Object key, ImageDecoderCallback decode) {
    starts.update(id, (n) => n + 1, ifAbsent: () => 1);
    return OneFrameImageStreamCompleter(
      frame?.call() ?? SynchronousFuture(ImageInfo(image: pixels.clone())),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _CountingProvider && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class _DelayedKeyProvider extends _CountingProvider {
  const _DelayedKeyProvider(
    super.id,
    super.starts,
    super.pixels,
    this.keyResult,
  );

  final Future<Object> keyResult;

  @override
  Future<Object> obtainKey(ImageConfiguration configuration) => keyResult;
}
