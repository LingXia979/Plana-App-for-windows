import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/shell/shell_state.dart';
import 'package:plana_app/features/tools/tools_page.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late bool desktop;
  String? clipboard;

  setUp(() {
    desktop = true;
    clipboard = null;
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWith((ref) => desktop),
      ],
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1500, 900),
    double textScale = 1.4,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const ToolsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop editors adapt to width and large text while copy, import and drafts work',
    (tester) async {
      await mount(tester);
      final input = key('weight-convert-input');
      await tester.enterText(input, '(cat ears:1.2), solo');
      await tester.pump();
      await tester.tap(key('weight-convert-run'));
      await tester.pumpAndSettle();
      final output = key('weight-convert-output');
      final converted = tester
          .widget<SelectableText>(output)
          .textSpan!
          .toPlainText();
      expect(
        tester.getRect(output).left,
        greaterThan(tester.getRect(input).right),
      );

      for (final size in [const Size(900, 600), const Size(640, 500)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(input).controller!.text,
          '(cat ears:1.2), solo',
        );
        expect(
          tester.getRect(output).top,
          greaterThan(tester.getRect(input).bottom),
        );
        await tester.ensureVisible(find.text('复制结果'));
        await tester.tap(find.text('复制结果'));
        await tester.pumpAndSettle();
        expect(clipboard, converted);
        expect(tester.takeException(), isNull);
      }

      await tester.ensureVisible(find.text('图片元数据'));
      await tester.tap(find.text('图片元数据'));
      await tester.pumpAndSettle();
      await tester.enterText(key('metadata-field-prompt'), '1girl, forest');
      await tester.ensureVisible(find.text('权重转换'));
      await tester.tap(find.text('权重转换'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        '(cat ears:1.2), solo',
      );
      expect(
        tester.widget<SelectableText>(output).textSpan!.toPlainText(),
        converted,
      );
      await tester.ensureVisible(find.text('导入提示词'));
      await tester.tap(find.text('导入提示词'));
      await tester.pumpAndSettle();
      expect(container.read(shellIndexProvider), kTabCreate);
      expect(container.read(generateProvider).prompt, converted);
      expect(find.byType(ToolsPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'edited input and changed conversion options invalidate the old result',
    (tester) async {
      await mount(tester, textScale: 1);
      final input = key('weight-convert-input');
      await tester.enterText(input, '(cat ears:1.2), solo');
      await tester.pump();
      await tester.tap(key('weight-convert-run'));
      await tester.pumpAndSettle();
      await tester.enterText(input, '1girl, forest');
      await tester.pumpAndSettle();
      expect(key('weight-convert-output'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '复制结果'))
            .onPressed,
        isNull,
      );
      await tester.pump();
      await tester.tap(key('weight-convert-run'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(key('weight-convert-output'), findsNothing);
      await tester.tap(find.text('NAI → SD'));
      await tester.enterText(input, '1.2::cat ears::, solo');
      await tester.pump();
      await tester.tap(key('weight-convert-run'));
      await tester.pumpAndSettle();
      expect(find.text('导入提示词'), findsNothing);
      expect(
        tester
            .widget<SelectableText>(key('weight-convert-output'))
            .textSpan!
            .toPlainText(),
        contains('cat ears'),
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mobile tools retain the app bar and conversion workflow', (
    tester,
  ) async {
    desktop = false;
    await mount(tester, size: const Size(400, 800), textScale: 1);
    expect(find.byType(AppBar), findsOneWidget);
    expect(key('weight-convert-input'), findsNothing);
    await tester.enterText(
      find.byType(TextField).first,
      '(cat ears:1.2), solo',
    );
    await tester.tap(find.text('转换'));
    await tester.pumpAndSettle();
    expect(find.text('导入提示词'), findsOneWidget);
    await tester.tap(find.text('复制结果'));
    await tester.pumpAndSettle();
    expect(clipboard, contains('cat ears'));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
