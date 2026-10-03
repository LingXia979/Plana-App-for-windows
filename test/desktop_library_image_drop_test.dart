import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/features/char_library/char_library.dart';
import 'package:plana_app/features/char_library/char_library_page.dart';
import 'package:plana_app/features/gallery/albums/album_cover_dialog.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/inspiration/tag_editor_page.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/vibe_library/vibe_library.dart';
import 'package:plana_app/features/vibe_library/vibe_library_page.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathsChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  late AppStores stores;
  late ProviderContainer container;
  late List<File> files;
  var fallbackCalls = 0;
  var disposed = false;
  var dropsInFlight = 0;

  Finder key(String name) => find.byKey(ValueKey(name));

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('plana_library_drop_');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathsChannel,
      (_) async => root.path,
    );
    files = [
      for (var i = 0; i < 3; i++)
        File('${root.path}/参考$i.png')..writeAsBytesSync(
          img.encodePng(
            img.fill(
              img.Image(width: 24, height: 32, numChannels: 4),
              color: img.ColorRgba8(60 + i * 60, 120, 210, 255),
            ),
          ),
        ),
    ];
    stores = await AppStores.open(
      rootOverride: Directory('${root.path}/runtime'),
    );
    container = ProviderContainer(
      overrides: [
        desktopModeProvider.overrideWithValue(true),
        appStoresProvider.overrideWithValue(stores),
      ],
    );
    fallbackCalls = 0;
    disposed = false;
    dropsInFlight = 0;
  });

  tearDown(() {
    if (!disposed) container.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathsChannel, null);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 300 && !ready(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ready(), isTrue);
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> mount(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (_, child) => DesktopImageDropHost(child: child!),
          home: ImageDropRegion(
            label: '全局导入',
            multiple: true,
            onDrop: (_, _) async => fallbackCalls++,
            child: page,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> drop(
    WidgetTester tester,
    Offset point,
    List<File> images,
  ) async {
    await tester.runAsync(() async {
      dropsInFlight++;
      unawaited(
        binding.defaultBinaryMessenger.handlePlatformMessage(
          DesktopImageDropHost.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('drop', {
              'x': point.dx,
              'y': point.dy,
              'paths': [for (final image in images) image.path],
            }),
          ),
          (reply) {
            dropsInFlight--;
            if (reply != null) {
              const StandardMethodCodec().decodeEnvelope(reply);
            }
          },
        ),
      );
    });
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await waitFor(tester, () => dropsInFlight == 0);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    disposed = true;
    stores.flushNow();
    var idle = false;
    unawaited(
      Future.wait([
        stores.gallery.idle,
        stores.albums.idle,
        stores.workspace.idle,
        stores.assistant.idle,
        stores.prefs.write(key: 'fixture_finished', value: '1'),
      ]).then((_) => idle = true),
    );
    await waitFor(tester, () => idle);
    expect(tester.takeException(), isNull);
  }

  for (final vibe in [true, false]) {
    testWidgets(
      '${vibe ? 'Vibe' : 'character'} library imports dropped batch once and keeps creation unchanged',
      (tester) async {
        await mount(
          tester,
          vibe ? const VibeLibraryPage() : const CharLibraryPage(),
        );
        await waitFor(
          tester,
          () => vibe
              ? container.read(vibeLibraryProvider).hasValue
              : container.read(charLibraryProvider).hasValue,
        );
        final receiver = key(
          vibe ? 'vibe-library-image-drop' : 'char-library-image-drop',
        );
        final point = tester.getCenter(receiver);
        expect(tester.widget<ImageDropRegion>(receiver).enabled, isTrue);
        await drop(tester, point, files.take(2).toList());
        await waitFor(tester, () => dropsInFlight == 0);
        expect(
          vibe
              ? container.read(vibeLibraryProvider).value?.length
              : container.read(charLibraryProvider).value?.length,
          2,
          reason:
              'fallback $fallbackCalls; ${find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)).evaluate().map((element) => (element.widget as Text).data).join(' / ')}',
        );
        expect(fallbackCalls, 0);
        expect(container.read(generateProvider).vibes, isEmpty);
        expect(container.read(generateProvider).charRefs, isEmpty);
        if (vibe) {
          final library = container.read(vibeLibraryProvider.notifier);
          final entries = container.read(vibeLibraryProvider).requireValue;
          expect(entries.map((entry) => entry.name).toSet(), {'参考0', '参考1'});
          expect(
            entries.every((entry) => library.fileOf(entry).existsSync()),
            isTrue,
          );
        } else {
          final library = container.read(charLibraryProvider.notifier);
          final entries = container.read(charLibraryProvider).requireValue;
          expect(entries.map((entry) => entry.name).toSet(), {'参考0', '参考1'});
          expect(
            entries.every((entry) => library.fileOf(entry).existsSync()),
            isTrue,
          );
        }
        await finish(tester);
      },
    );
  }

  List<MemoryImage> slotImages(int index) => find
      .descendant(
        of: key('tag-preview-slot-drop-$index'),
        matching: find.byType(Image),
      )
      .evaluate()
      .map((element) => (element.widget as Image).image)
      .whereType<MemoryImage>()
      .toList();

  testWidgets(
    'inspiration batch fills preview slots and a single drop replaces only its slot',
    (tester) async {
      await mount(tester, const TagEditorPage(cat: TagCategory.artist));
      await tester.pumpAndSettle();
      final batchPoint = tester.getCenter(
        find.text('横图 1216×832 · 四格画风样例,首张为封面'),
      );
      await drop(tester, batchPoint, files.take(2).toList());
      await waitFor(
        tester,
        () => slotImages(0).isNotEmpty && slotImages(1).isNotEmpty,
      );
      expect(slotImages(0).single.bytes, files[0].readAsBytesSync());
      expect(slotImages(1).single.bytes, files[1].readAsBytesSync());
      expect(slotImages(2), isEmpty);
      await drop(tester, tester.getCenter(key('tag-preview-slot-drop-0')), [
        files[2],
      ]);
      await waitFor(
        tester,
        () =>
            slotImages(0).isNotEmpty &&
            orderedEquals(
              files[2].readAsBytesSync(),
            ).matches(slotImages(0).single.bytes, {}),
      );
      expect(slotImages(1).single.bytes, files[1].readAsBytesSync());
      expect(slotImages(2), isEmpty);
      expect(fallbackCalls, 0);
      await finish(tester);
    },
  );

  testWidgets(
    'dropped gallery cover still requires crop confirmation and cancellation preserves it',
    (tester) async {
      await mount(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showAlbumCoverDialog(context),
                child: const Text('cover'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('cover'));
      await tester.pumpAndSettle();
      await drop(tester, tester.getCenter(key('album-cover-image-drop')), [
        files[0],
      ]);
      await waitFor(
        tester,
        () => key('album-cover-crop-dialog').evaluate().isNotEmpty,
      );
      expect(container.read(albumsProvider).cover(null), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(container.read(albumsProvider).cover(null), isNull);
      await tester.tap(find.text('cover'));
      await tester.pumpAndSettle();
      await drop(tester, tester.getCenter(key('album-cover-image-drop')), [
        files[1],
      ]);
      await waitFor(
        tester,
        () => key('album-cover-crop-dialog').evaluate().isNotEmpty,
      );
      await tester.tap(key('album-cover-save'));
      await waitFor(
        tester,
        () => container.read(albumsProvider).cover(null) != null,
      );
      expect(fallbackCalls, 0);
      expect(container.read(albumsProvider).cover(null)!.sourceImageId, isNull);
      await finish(tester);
    },
  );
}
