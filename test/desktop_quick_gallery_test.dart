import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/ui_prefs.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_gallery_page.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/gallery_date_filter.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/shell/shell_state.dart';

class _Gallery extends GalleryNotifier {
  _Gallery(this.images);
  final List<ResultImage> images;
  @override
  GalleryState build() =>
      GalleryState(results: images, selectedId: images.first.id);
}

class _Picker extends FilePicker {
  String? path;
  int calls = 0;
  File? savedZip;
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    calls++;
    return path;
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    final file = File('$path/$fileName');
    await file.writeAsBytes(bytes!);
    savedZip = file;
    return file.path;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late Directory output;
  late _Picker picker;
  late List<ResultImage> images;
  setUp(() {
    stores = AppStores.ephemeral();
    output = Directory.systemTemp.createTempSync('plana_quick_export_');
    picker = _Picker()..path = output.path;
    FilePicker.platform = picker;
    images = [
      for (var i = 0; i < 3; i++)
        ResultImage(
          id: 'sample$i',
          width: 80,
          height: 120,
          seed: 100 + i,
          createdAt: DateTime.now()
              .subtract(Duration(days: i))
              .millisecondsSinceEpoch,
          bytes: Uint8List.fromList(
            img.encodePng(img.Image(width: 80, height: 120)),
          ),
        ),
    ];
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        galleryProvider.overrideWith(() => _Gallery(images)),
      ],
    );
    container.read(desktopLibraryProvider.notifier).choose(null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('gal'),
      (_) async =>
          throw StateError('Desktop export must never call phone gallery'),
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => output.path,
    );
  });
  tearDown(() {
    stores.flushNow();
    container.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('gal'),
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    output.deleteSync(recursive: true);
  });
  Finder key(String name) => find.byKey(ValueKey(name));
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final empty = ref.watch(galleryViewProvider).results.isEmpty;
                // The real canvas rebuilds this subtree when the library empties.
                return Align(
                  alignment: Alignment.topRight,
                  child: SizedBox(
                    key: ValueKey(empty ? 'empty-canvas' : 'full-canvas'),
                    width: 320,
                    child: const DesktopLibraryButton(),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(key('desktop-history-browse'));
    await tester.pumpAndSettle();
    // Search index and image decoders may have real I/O pending.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(key('desktop-quick-gallery'), findsOneWidget);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    stores.flushNow();
    var done = false;
    unawaited(
      Future.wait([
        stores.gallery.idle,
        stores.albums.idle,
      ]).then((_) => done = true),
    );
    for (var i = 0; i < 100 && !done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(done, isTrue, reason: 'Pending gallery writes must finish');
    expect(tester.takeException(), isNull);
  }

  Future<void> exported(WidgetTester tester) async {
    await tester.tap(key('gallery-batch-export'));
    await tester.pumpAndSettle();
    expect(key('gallery-export-dialog'), findsOneWidget);
    await tester.tap(key('gallery-export-browse'));
    await tester.pumpAndSettle();
    await tester.tap(
      key(
        picker.path == null ? 'gallery-export-cancel' : 'gallery-export-submit',
      ),
    );
    await tester.pump();
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (key('gallery-export-dialog').evaluate().isEmpty &&
          tester.widget<FilledButton>(key('gallery-batch-export')).onPressed !=
              null) {
        break;
      }
    }
    expect(
      tester.widget<FilledButton>(key('gallery-batch-export')).onPressed,
      isNotNull,
    );
    expect(key('gallery-export-dialog'), findsNothing);
    await tester.pumpAndSettle();
  }

  Future<void> holdImage(WidgetTester tester, String id) async {
    final press = await tester.startGesture(
      tester.getCenter(key('quick-gallery-image-$id')),
      kind: PointerDeviceKind.mouse,
    );
    await press.moveBy(const Offset(5, 0));
    await tester.pump();
    await press.up();
    await tester.pumpAndSettle();
  }

  testWidgets(
    'two history controls switch library and open scoped quick browsing without leaving creation',
    (tester) async {
      final album = await tester.runAsync(
        () =>
            container.read(albumsProvider.notifier).create('Selected library'),
      );
      await tester.runAsync(
        () => container
            .read(albumsProvider.notifier)
            .organize({'sample0', 'sample1'}, {album!}),
      );
      await mount(tester);
      expect(find.text('切换图库'), findsOneWidget);
      expect(
        tester.widget<IconButton>(key('desktop-history-browse')).icon,
        isA<Icon>().having((i) => i.icon, 'up arrow', Icons.expand_less),
      );
      await tester.tap(key('desktop-library-picker'));
      await tester.pumpAndSettle();
      expect(key('desktop-library-dialog'), findsOneWidget);
      await tester.tap(key('desktop-album-$album'));
      await tester.pumpAndSettle();
      final beforeTab = container.read(shellIndexProvider);
      await open(tester);
      expect(find.text('Selected library'), findsOneWidget);
      expect(key('quick-gallery-image-sample0'), findsOneWidget);
      expect(key('quick-gallery-image-sample1'), findsOneWidget);
      expect(key('quick-gallery-image-sample2'), findsNothing);
      expect(find.text('分组'), findsOneWidget);
      expect(find.text('多选'), findsNothing);
      await tester.tap(
        find.descendant(
          of: key('desktop-quick-gallery'),
          matching: find.text('切换图库'),
        ),
      );
      await tester.pumpAndSettle();
      expect(key('desktop-library-dialog'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(key('desktop-album-'));
      await tester.pumpAndSettle();
      expect(key('desktop-quick-gallery'), findsOneWidget);
      expect(key('quick-gallery-image-sample2'), findsOneWidget);
      await tester.tap(key('quick-gallery-image-sample1'));
      await tester.pumpAndSettle();
      expect(key('desktop-quick-gallery'), findsNothing);
      expect(container.read(galleryProvider).selectedId, 'sample1');
      expect(container.read(shellIndexProvider), beforeTab);
      await finish(tester);
    },
  );

  testWidgets(
    'desktop batch export writes only selected originals, avoids collisions and cancellation writes nothing',
    (tester) async {
      await mount(tester);
      await open(tester);
      await holdImage(tester, 'sample0');
      await tester.tap(key('quick-gallery-image-sample1'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 张'), findsOneWidget);
      expect(find.text('手机相册'), findsNothing);
      expect(find.text('分享'), findsNothing);
      expect(find.text('打包 ZIP'), findsOneWidget);
      await exported(tester);
      expect(picker.calls, 1);
      var files = output.listSync().whereType<File>().toList();
      expect(files, hasLength(2));
      for (final file in files) {
        expect(file.readAsBytesSync(), images.first.bytes);
      }
      expect(files.any((file) => file.path.contains('sample2')), isFalse);
      await exported(tester);
      expect(output.listSync().whereType<File>(), hasLength(4));
      picker.path = null;
      await exported(tester);
      expect(output.listSync().whereType<File>(), hasLength(4));
      expect(container.read(galleryProvider).results, hasLength(3));
      tester.view.physicalSize = const Size(720, 600);
      await tester.pumpAndSettle();
      expect(key('gallery-batch-export').hitTestable(), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'quick browsing can leave an empty automatic library after its launcher is disposed',
    (tester) async {
      await mount(tester);
      await open(tester);
      final switchLibrary = find.descendant(
        of: key('desktop-quick-gallery'),
        matching: find.text('切换图库'),
      );
      for (var i = 0; i < 2; i++) {
        await tester.tap(switchLibrary);
        await tester.pumpAndSettle();
        await tester.tap(key('desktop-album-auto'));
        await tester.pumpAndSettle();
        expect(key('empty-canvas'), findsOneWidget);
        expect(
          find.text(container.read(desktopLibraryProvider).day),
          findsOneWidget,
        );
        expect(key('desktop-quick-gallery'), findsOneWidget);
        expect(key('quick-gallery-image-sample0'), findsNothing);
        await tester.tap(switchLibrary);
        await tester.pumpAndSettle();
        expect(key('desktop-library-dialog'), findsOneWidget);
        await tester.tap(key('desktop-album-'));
        await tester.pumpAndSettle();
        expect(key('full-canvas'), findsOneWidget);
        expect(key('quick-gallery-image-sample0'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await finish(tester);
    },
  );

  testWidgets(
    'group, model and date open menus under their controls and date selection filters results',
    (tester) async {
      await mount(tester);
      await open(tester);
      for (final (label, option) in [
        ('分组', '不分组'),
        ('模型', '未知'),
        ('全部时间', '今天'),
      ]) {
        final control = find.descendant(
          of: key('desktop-quick-gallery'),
          matching: find.text(label),
        );
        final anchor = tester.getRect(control);
        await tester.tap(control);
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        final item = find.text(option).last;
        final menu = label == '全部时间' ? key('gallery-date-panel') : item;
        expect(tester.getTopLeft(menu).dy, greaterThan(anchor.bottom));
        expect(tester.getTopLeft(menu).dx, lessThan(anchor.right + 24));
        await tester.tap(item);
        await tester.pumpAndSettle();
      }
      expect(
        container.read(uiPrefsProvider).dateFilter.kind,
        GalleryDateKind.today,
      );
      expect(key('quick-gallery-image-sample0'), findsOneWidget);
      expect(key('quick-gallery-image-sample1'), findsNothing);
      for (final kind in ['day', 'range']) {
        await tester.tap(find.text('今天').first);
        await tester.pumpAndSettle();
        await tester.tap(key('gallery-date-kind-$kind'));
        await tester.pumpAndSettle();
        expect(key('desktop-gallery-calendar'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(
          container.read(uiPrefsProvider).dateFilter.kind,
          GalleryDateKind.today,
        );
      }
      await finish(tester);
    },
  );

  testWidgets(
    'desktop ZIP dialog exports a readable archive of the selection',
    (tester) async {
      await mount(tester);
      await open(tester);
      await holdImage(tester, 'sample0');
      await tester.tap(key('quick-gallery-image-sample1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打包 ZIP'));
      // The parent shows a spinner while the ZIP dialog is open.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(Dialog), findsNWidgets(2));
      expect(find.byType(BottomSheet), findsNothing);
      final zipName = find
          .descendant(
            of: find.byType(Dialog).last,
            matching: find.byType(TextField),
          )
          .first;
      expect(tester.getSize(zipName).width, lessThan(480));
      await tester.tap(find.text('打包'));
      await tester.pump();
      for (var i = 0; i < 300; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (picker.savedZip != null &&
            tester
                    .widget<FilledButton>(key('gallery-batch-export'))
                    .onPressed !=
                null) {
          break;
        }
      }
      await tester.pumpAndSettle();
      expect(picker.savedZip, isNotNull);
      final archive = ZipDecoder().decodeBytes(
        picker.savedZip!.readAsBytesSync(),
      );
      expect(archive.files.map((f) => f.name), [
        'plana_100.png',
        'plana_101.png',
      ]);
      for (var i = 0; i < archive.files.length; i++) {
        expect(archive.files[i].readBytes(), images[i].bytes);
      }
      expect(find.byType(Dialog), findsOneWidget);
      await finish(tester);
    },
  );
}
