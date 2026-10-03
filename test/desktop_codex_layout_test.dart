import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/inspiration/codex/codex_favorites.dart';
import 'package:plana_app/features/inspiration/codex/codex_models.dart';
import 'package:plana_app/features/inspiration/codex/codex_providers.dart';
import 'package:plana_app/features/inspiration/codex/codex_view.dart';

import 'support/desktop_capture.dart';

class _Acknowledged extends CodexIntro {
  @override
  bool? build() => true;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const meta = CodexMeta(
    id: 'styles',
    type: CodexType.string,
    title: '画风词典',
    entryCount: 12,
  );
  const other = CodexMeta(
    id: 'scenes',
    type: CodexType.composition,
    title: '场景法典',
    entryCount: 1,
  );
  final entries = [
    for (var i = 0; i < 12; i++)
      CodexEntry(
        id: 'style$i',
        title: '${['水彩森林', '暮色海岸', '午后花园'][i % 3]} ${i + 1}',
        tags: [
          'watercolor, forest, light rays',
          'sunset, sea, warm light',
          'garden, flowers, afternoon',
        ][i % 3],
        path: i < 6 ? ['自然', if (i < 3) '森林' else '花园'] : ['光影'],
      ),
  ];
  late Directory temp;
  late AppStores stores;
  late ProviderContainer container;
  final capture = GlobalKey();
  Finder key(String value) => find.byKey(ValueKey(value));

  setUpAll(loadDesktopCaptureFonts);
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('plana_codex_desktop_');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        codexIntroProvider.overrideWith(_Acknowledged.new),
        codexIndexProvider.overrideWith((ref) async => [meta, other]),
        codexMediaProvider.overrideWith((ref) async => CodexMedia.fallback),
        codexDataProvider.overrideWith(
          (ref, id) async => id == meta.id
              ? CodexData(
                  meta: meta,
                  entries: entries,
                  tree: const [
                    CodexNode('自然', 6, [
                      CodexNode('森林', 3, []),
                      CodexNode('花园', 3, []),
                    ]),
                    CodexNode('光影', 6, []),
                  ],
                )
              : const CodexData(
                  meta: other,
                  entries: [
                    CodexEntry(id: 'scene0', title: '夜空', tags: 'night sky'),
                  ],
                ),
        ),
        codexTagZhProvider.overrideWith((ref, id) async => null),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    temp.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await container.read(codexFavoritesProvider.future);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light().copyWith(
              platform: TargetPlatform.windows,
              textTheme: AppTheme.light().textTheme.apply(
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            home: const Scaffold(
              body: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '灵感 · 法典',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        CodexPickerButton(),
                      ],
                    ),
                  ),
                  Expanded(child: CodexView(desktop: true)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop codex supports nested filters, search, resizing and book switching',
    (tester) async {
      await mount(tester);
      final first = tester.getRect(key('desktop-codex-card-style0'));
      expect(first.width, lessThan(300));
      expect(first.height, 330);
      expect(tester.getTopLeft(key('desktop-codex-card-style4')).dy, first.top);
      await captureDesktop(tester, capture, 'windows17-codex-wide');
      await tester.tap(key('codex-category-自然'));
      await tester.pumpAndSettle();
      expect(find.text('自然 · 6 条'), findsOneWidget);
      await tester.tap(key('codex-category-自然/森林'));
      await tester.pumpAndSettle();
      expect(find.text('自然 / 森林 · 3 条'), findsOneWidget);
      await tester.enterText(key('desktop-codex-search'), 'sea');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(key('desktop-codex-card-style1'), findsOneWidget);
      expect(key('desktop-codex-card-style0'), findsNothing);
      tester.view.physicalSize = const Size(740, 700);
      await tester.pumpAndSettle();
      expect(key('desktop-codex-categories'), findsNothing);
      expect(
        tester.widget<TextField>(key('desktop-codex-search')).controller!.text,
        'sea',
      );
      expect(tester.takeException(), isNull);
      await captureDesktop(tester, capture, 'windows17-codex-compact');
      await tester.tap(find.byType(CodexPickerButton));
      await tester.pumpAndSettle();
      expect(key('codex-desktop-dialog'), findsOneWidget);
      await tester.tap(find.text('场景法典'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-card-scene0'), findsOneWidget);
      expect(
        tester.widget<TextField>(key('desktop-codex-search')).controller!.text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop favorites and random details keep all actions accessible',
    (tester) async {
      await mount(tester);
      await tester.runAsync(() async {
        await tester.tap(
          find.descendant(
            of: key('desktop-codex-card-style0'),
            matching: find.byTooltip('收藏'),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(container.read(codexFavKeysProvider), contains('styles/style0'));
      await tester.tap(key('desktop-codex-favorites'));
      await tester.pumpAndSettle();
      expect(find.text(entries.first.title), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-codex-card-style0'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-detail'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await captureDesktop(tester, capture, 'windows17-codex-detail');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('1 / 12'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('2 / 12'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一条'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 12'), findsOneWidget);
      // Clicking a control must not steal the dialog's arrow shortcuts.
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.pumpAndSettle();
      expect(find.text('12 / 12'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('11 / 12'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-codex-random'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-detail'), findsOneWidget);
      expect(find.text('换一个'), findsOneWidget);
      final randomTitle = find.descendant(
        of: key('desktop-codex-detail'),
        matching: find.byWidgetPredicate(
          (w) => w is Text && entries.any((e) => e.title == w.data),
        ),
      );
      final firstDraw = tester.widget<Text>(randomTitle).data;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(randomTitle).data, isNot(firstDraw));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(randomTitle).data, firstDraw);
      await tester.tap(find.text('换一个'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
