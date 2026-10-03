import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/util/preview_cache.dart';
import 'package:plana_app/features/char_library/char_library.dart';
import 'package:plana_app/features/char_library/char_library_page.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/widgets/top_bar.dart';
import 'package:plana_app/features/vibe_library/local_vibe_folder.dart';
import 'package:plana_app/features/vibe_library/vibe_library.dart';
import 'package:plana_app/features/vibe_library/vibe_library_page.dart';

class _Vibes extends VibeLibrary {
  @override
  Future<List<VibeEntry>> build() async => [
    for (var i = 0; i < 9; i++)
      VibeEntry(id: '$i', name: '参考素材 ${i + 1}', fileName: 'unused'),
  ];
  @override
  File fileOf(VibeEntry e) => File('assets/app_icon.png');
}

class _Chars extends CharLibrary {
  @override
  Future<List<CharRefEntry>> build() async => const [];
}

class _Folder extends VibeFolderLibrary {
  @override
  Future<VibeFolderState> build() async => const VibeFolderState(
    directory: 'D:\\示例素材\\Vibe',
    entries: [
      FolderVibe(
        source: 'unused',
        fingerprint: '0',
        ordinal: 0,
        id: 'folder-example',
        name: '本地文件示例',
        hasImage: false,
        models: ['v4-5full'],
        strength: .6,
        infoExtracted: 1,
      ),
    ],
  );
  @override
  Future<void> refresh() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.isWindows) {
      for (final font in [
        ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
        (
          'MaterialIcons',
          r'D:\Android\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
        ),
      ]) {
        await (FontLoader(font.$1)
              ..addFont(File(font.$2).readAsBytes().then(ByteData.sublistView)))
            .load();
      }
    }
  });
  late ProviderContainer container;
  final capture = GlobalKey();
  setUp(() {
    container = ProviderContainer(
      overrides: [
        desktopModeProvider.overrideWithValue(true),
        appStoresProvider.overrideWithValue(AppStores.ephemeral()),
        vibeLibraryProvider.overrideWith(_Vibes.new),
        charLibraryProvider.overrideWith(_Chars.new),
        vibeFolderProvider.overrideWith(_Folder.new),
        filePreviewProvider.overrideWith(
          (ref, path) async => 'assets/app_icon.png',
        ),
      ],
    );
  });
  tearDown(() => container.dispose());

  Future<void> mount(WidgetTester tester, Widget page, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(
            platform: TargetPlatform.windows,
            textTheme: AppTheme.light().textTheme.apply(
              fontFamily: 'Microsoft YaHei',
            ),
          ),
          home: RepaintBoundary(key: capture, child: page),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (Platform.environment['PLANA_DESKTOP_CAPTURE'] != '1') return;
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/windows-validation/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'desktop libraries use small responsive cards and an inline folder source',
    (tester) async {
      await mount(tester, const VibeLibraryPage(), const Size(1280, 800));
      expect(find.text('本地文件夹'), findsOneWidget);
      final grid = tester.widget<GridView>(find.byType(GridView).first);
      expect(
        grid.gridDelegate,
        isA<SliverGridDelegateWithMaxCrossAxisExtent>(),
      );
      await screenshot(tester, 'vibe-library-desktop');
      tester.view.physicalSize = const Size(1920, 1080);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(GridView).first).left, 20);
      expect(tester.getRect(find.byType(GridView).first).width, 1880);
      expect(
        tester.getRect(find.byType(TextField).first).right,
        greaterThan(1850),
      );
      await screenshot(tester, 'windows15-vibe-maximized');
      await tester.tap(find.text('本地文件夹'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      expect(find.text('本地文件示例'), findsOneWidget);
      expect(find.text('更换文件夹'), findsOneWidget);
      await screenshot(tester, 'vibe-folder-desktop');
      tester.view.physicalSize = const Size(880, 640);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('示例预览'));
      await tester.pumpAndSettle();
      await screenshot(tester, 'vibe-library-samples');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.read(appStoresProvider).flushNow();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'empty character library shows independent aspect-ratio examples',
    (tester) async {
      await mount(tester, const CharLibraryPage(), const Size(1280, 800));
      expect(find.text('蓝调小猫'), findsOneWidget);
      expect(container.read(charLibraryProvider).requireValue, isEmpty);
      expect(container.read(generateProvider).charRefs, isEmpty);
      await screenshot(tester, 'character-library-samples');
      tester.view.physicalSize = const Size(1920, 1080);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(GridView).first).left, 20);
      expect(tester.getRect(find.byType(GridView).first).width, 1880);
      expect(
        tester.getRect(find.byType(TextField).first).right,
        greaterThan(1850),
      );
      await screenshot(tester, 'windows15-character-library-maximized');
      tester.view.physicalSize = const Size(880, 640);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.read(appStoresProvider).flushNow();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('desktop model menu is anchored and applies selected model', (
    tester,
  ) async {
    await mount(
      tester,
      const Scaffold(body: SizedBox(width: 360, child: GenerateTopBar())),
      const Size(880, 640),
    );
    await tester.tap(find.byKey(const ValueKey('desktop-model-dropdown')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    final choice = find.widgetWithText(MenuItemButton, 'NAI 4.5 Curated');
    expect(choice, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(choice, findsNothing);
    await tester.tap(find.byKey(const ValueKey('desktop-model-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(container.read(generateProvider).params.model, 'NAI 4.5 Curated');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    container.read(appStoresProvider).flushNow();
    await tester.pump(const Duration(seconds: 1));
  });
}
