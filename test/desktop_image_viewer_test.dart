import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_image_viewer.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';
import 'package:plana_app/features/inpaint/inpaint_ops.dart';
import 'package:plana_app/features/shell/shell_state.dart';

void main() {
  late AppStores stores;
  late ProviderContainer container;
  late List<Completer<Uint8List?>> reads;
  late List<Completer<GenerateState?>> inputReads;
  late List<Uint8List> pixels;
  final requested = <String>[];
  Finder key(String value) => find.byKey(ValueKey(value));
  final imageFinder = key('desktop-viewer-image');

  setUp(() {
    stores = AppStores.ephemeral();
    reads = List.generate(5, (_) => Completer<Uint8List?>());
    inputReads = List.generate(5, (_) => Completer<GenerateState?>());
    pixels = List.generate(
      5,
      (i) => Uint8List.fromList(
        img.encodePng(
          img.fill(
            img.Image(width: 32 + i * 8, height: 40),
            color: img.ColorRgb8(30 + i * 40, 80, 160),
          ),
        ),
      ),
    );
    requested.clear();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        galleryImageProvider.overrideWith((ref, id) {
          requested.add(id);
          return reads[int.parse(id.substring(3))].future;
        }),
        galleryInputProvider.overrideWith(
          (ref, id) => inputReads[int.parse(id.substring(3))].future,
        ),
      ],
    );
    container.read(shellIndexProvider.notifier).select(kTabGallery);
  });

  tearDown(() {
    container.dispose();
    stores.flushNow();
  });

  Future<void> advance(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }

  Future<void> expectFrame(
    WidgetTester tester,
    int index, {
    String? prompt,
  }) async {
    for (var i = 0; i < 50; i++) {
      await advance(tester);
      if (find.text('${index + 1} / 5').evaluate().isNotEmpty &&
          imageFinder.evaluate().isNotEmpty &&
          (tester.widget<Image>(imageFinder).image as MemoryImage).bytes ==
              pixels[index]) {
        break;
      }
    }
    expect(find.text('${index + 1} / 5'), findsOneWidget);
    expect(
      (tester.widget<Image>(imageFinder).image as MemoryImage).bytes,
      same(pixels[index]),
    );
    expect(
      tester
          .widget<RawImage>(
            find.descendant(of: imageFinder, matching: find.byType(RawImage)),
          )
          .image,
      isNotNull,
    );
    expect(find.text(prompt ?? 'prompt-$index'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  Future<void> mount(
    WidgetTester tester, {
    bool diskInputs = false,
    bool comparison = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    reads[0].complete(pixels[0]);
    if (diskInputs) {
      inputReads[0].complete(
        GenerateState.initial().copyWith(prompt: 'prompt-0'),
      );
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDesktopImageViewer(
                  context,
                  images: [
                    for (var i = 0; i < 5; i++)
                      ResultImage(
                        id: 'gen$i',
                        width: 32 + i * 8,
                        height: 40,
                        seed: i,
                        bytes: comparison && i == 0 ? pixels[0] : null,
                        hasInput: true,
                        input: diskInputs
                            ? null
                            : GenerateState.initial().copyWith(
                                prompt: 'prompt-$i',
                                inpaint: comparison && i == 0
                                    ? InpaintJob(
                                        image: pixels[0],
                                        mask: pixels[0],
                                        strength: .7,
                                        grid: (MaskGrid(
                                          32,
                                          40,
                                        )..paintDot(12, 12, 8)).encode(),
                                      )
                                    : null,
                              ),
                      ),
                  ],
                  index: 0,
                  libraryName: '测试图库',
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await expectFrame(tester, 0);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'held old-region preview follows the current result and leaves action height fixed',
    (tester) async {
      await mount(tester, comparison: true);
      final importTop = tester.getTopLeft(key('desktop-image-import')).dy;
      final canvas = tester.getRect(imageFinder);
      final old = tester.getRect(key('canvas-compare-old'));
      expect(old.right, closeTo(canvas.right - 12, .01));
      expect(old.bottom, closeTo(canvas.bottom - 12, .01));
      final held = await tester.startGesture(
        tester.getCenter(key('canvas-compare-old')),
      );
      for (
        var i = 0;
        i < 30 && container.read(comparePreviewProvider) == null;
        i++
      ) {
        await advance(tester);
      }
      final preview = container.read(comparePreviewProvider);
      expect(preview?.resultId, 'gen0');
      expect(
        (tester.widget<Image>(imageFinder).image as MemoryImage).bytes,
        same(preview!.bytes),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      reads[1].complete(pixels[1]);
      await expectFrame(tester, 1);
      expect(container.read(comparePreviewProvider), isNull);
      expect(tester.getTopLeft(key('desktop-image-import')).dy, importTop);
      await held.up();
      await tester.pumpAndSettle();
      expect(
        (tester.widget<Image>(imageFinder).image as MemoryImage).bytes,
        same(pixels[1]),
      );
      await tester.tap(key('desktop-image-close'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'waits for saved parameters and ignores late metadata from skipped images',
    (tester) async {
      await mount(tester, diskInputs: true);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      reads[1].complete(pixels[1]);
      for (var i = 0; i < 8; i++) {
        await advance(tester);
        expect(find.text('prompt-0'), findsOneWidget);
        expect(find.text('未保存生成参数'), findsNothing);
        expect(
          (tester.widget<Image>(imageFinder).image as MemoryImage).bytes,
          same(pixels[0]),
        );
      }
      inputReads[1].complete(
        GenerateState.initial().copyWith(prompt: 'prompt-1'),
      );
      await expectFrame(tester, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      reads[3].complete(pixels[3]);
      inputReads[3].complete(
        GenerateState.initial().copyWith(prompt: 'prompt-3'),
      );
      await expectFrame(tester, 3);
      reads[2].complete(pixels[2]);
      inputReads[2].complete(
        GenerateState.initial().copyWith(prompt: 'prompt-2'),
      );
      await advance(tester);
      await expectFrame(tester, 3);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'long, short, empty and missing prompts keep controls fixed and reset text scroll',
    (tester) async {
      await mount(tester, diskInputs: true);
      final panel = tester.element(key('desktop-image-info'));
      final actions = tester.getRect(key('desktop-image-import'));
      final viewport = tester.getRect(key('desktop-image-prompts'));
      final long = List.filled(300, 'long prompt, forest, sky').join(', ');
      reads[1].complete(pixels[1]);
      inputReads[1].complete(GenerateState.initial().copyWith(prompt: long));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await expectFrame(tester, 1, prompt: long);
      expect(tester.getRect(key('desktop-image-import')), actions);
      expect(tester.getRect(key('desktop-image-prompts')), viewport);
      final scroll = tester
          .widget<SingleChildScrollView>(key('desktop-image-prompts'))
          .controller!;
      scroll.jumpTo(250);
      await tester.pump();
      expect(scroll.offset, 250);
      for (final i in [2, 3, 4]) {
        reads[i].complete(pixels[i]);
        inputReads[i].complete(
          i == 3
              ? null
              : GenerateState.initial().copyWith(
                  prompt: i == 2 ? '' : 'prompt-4',
                ),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await expectFrame(
          tester,
          i,
          prompt: i == 2
              ? '未填写正面提示词'
              : i == 3
              ? '这张作品没有保存参数快照，可通过导入读取图片元数据。'
              : null,
        );
        expect(tester.element(key('desktop-image-info')), same(panel));
        expect(tester.getRect(key('desktop-image-import')), actions);
        expect(tester.getRect(key('desktop-image-prompts')), viewport);
        expect(scroll.offset, 0);
      }
      tester.view.physicalSize = const Size(900, 600);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(key('desktop-image-import')).bottom, lessThan(600));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'keeps decoded pixels and metadata while loading, and prefetches neighbours',
    (tester) async {
      await mount(tester);
      expect(requested, containsAll(['gen0', 'gen1']));
      expect(requested, isNot(contains('gen2')));
      final element = tester.element(imageFinder);
      final selected = container.read(galleryProvider).selectedId;
      await tester.tap(key('desktop-image-next'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.element(imageFinder), same(element));
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('prompt-0'), findsOneWidget);
        expect(find.text('prompt-1'), findsNothing);
      }
      reads[1].complete(pixels[1]);
      await expectFrame(tester, 1);
      expect(tester.element(imageFinder), same(element));
      expect(requested, contains('gen2'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await expectFrame(tester, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(find.text('1 / 5'), findsOneWidget);
      expect(container.read(galleryProvider).selectedId, selected);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rapid navigation discards stale loads and closing cancels pending UI work',
    (tester) async {
      await mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      reads[2].complete(pixels[2]);
      await expectFrame(tester, 2);
      reads[1].complete(pixels[1]);
      await advance(tester);
      await expectFrame(tester, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      reads[3].complete(pixels[3]);
      await advance(tester);
      expect(key('desktop-image-viewer'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unreadable images show an error instead of the previous picture',
    (tester) async {
      await mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      reads[1].complete(null);
      await advance(tester);
      await tester.pumpAndSettle();
      expect(find.text('无法读取这张图片'), findsOneWidget);
      expect(imageFinder, findsNothing);
      expect(find.text('2 / 5'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      reads[2].complete(Uint8List.fromList([1, 2, 3]));
      for (var i = 0; i < 10; i++) {
        await advance(tester);
      }
      expect(find.text('无法读取这张图片'), findsOneWidget);
      expect(find.text('3 / 5'), findsOneWidget);
      expect(imageFinder, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
