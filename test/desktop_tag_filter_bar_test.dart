import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/inspiration/widgets/desktop_tag_filter_bar.dart';

void main() {
  setUpAll(() async {
    // Real narrow glyphs expose the feedback loop hidden by uniform Ahem.
    await (FontLoader('TagFilterTest')..addFont(
          File(
            'test/fixtures/fonts/tag_filter_test.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });

  final tags = [for (var i = 0; i < 40; i++) 'tag-$i'];
  final picked = <String?>[];
  Finder chip(String label) => find.widgetWithText(ChoiceChip, label);
  Finder getStrip() => find.byKey(const ValueKey('inspiration-tag-strip'));

  void prepare(WidgetTester tester) {
    picked.clear();
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> mount(
    WidgetTester tester, {
    required double width,
    required List<String> tags,
    String? selected,
    double textScale = 1.05,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light().copyWith(
          textTheme: AppTheme.light().textTheme.apply(
            fontFamily: 'TagFilterTest',
          ),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: DesktopTagFilterBar(
                tags: tags,
                selectedTag: selected,
                favoritesSelected: false,
                onTagSelected: picked.add,
                onFavoritesSelected: () {},
                onManage: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 20),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
    expect(tester.takeException(), isNull);
  }

  void expectVisible(WidgetTester tester, String tag) {
    final viewport = tester.getRect(getStrip());
    final selected = tester.getRect(chip(tag));
    expect(chip(tag).hitTestable(), findsOneWidget);
    expect(selected.left, greaterThanOrEqualTo(viewport.left - .5));
    expect(selected.right, lessThanOrEqualTo(viewport.right + .5));
  }

  testWidgets('long and short tags settle across narrow overflow boundaries', (
    tester,
  ) async {
    prepare(tester);
    const longTag = 'a very very long long very very long tag';
    for (final scale in [1.0, 1.05, 1.47]) {
      for (final width in [250.0, 270.0, 290.0, 310.0, 330.0, 350.0]) {
        await mount(
          tester,
          width: width,
          tags: const [longTag, 'i'],
          textScale: scale,
        );
        expect(chip(longTag).hitTestable(), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      }
    }
  });

  testWidgets('resizing and scaling keep the active tag completely visible', (
    tester,
  ) async {
    prepare(tester);
    await mount(tester, width: 1200, tags: tags);
    await mount(tester, width: 1200, tags: tags, selected: 'tag-20');
    for (final scale in [1.05, 1.47, .84]) {
      for (final width in [300.0, 530.0, 900.0, 1200.0]) {
        await mount(
          tester,
          width: width,
          tags: tags,
          selected: 'tag-20',
          textScale: scale,
        );
        expectVisible(tester, 'tag-20');
      }
    }
  });

  testWidgets(
    'restored selection and changed tag pools reveal the active tag',
    (tester) async {
      prepare(tester);
      await mount(tester, width: 900, tags: tags, selected: 'tag-20');
      expectVisible(tester, 'tag-20');
      await mount(
        tester,
        width: 900,
        tags: tags.sublist(15),
        selected: 'tag-20',
      );
      expectVisible(tester, 'tag-20');
      await mount(tester, width: 900, tags: tags, selected: 'tag-20');
      expectVisible(tester, 'tag-20');
    },
  );

  testWidgets('manual browsing is preserved through ordinary parent rebuilds', (
    tester,
  ) async {
    prepare(tester);
    await mount(tester, width: 300, tags: tags, selected: 'tag-20');
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(getStrip()),
        scrollDelta: const Offset(0, -5000),
      ),
    );
    await tester.pumpAndSettle();
    await mount(tester, width: 300, tags: [...tags], selected: 'tag-20');
    final scroll = tester.widget<SingleChildScrollView>(getStrip()).controller!;
    expect(scroll.offset, 0);
    expect(chip('tag-20').hitTestable(), findsNothing);
    await tester.drag(
      getStrip(),
      const Offset(-120, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(picked, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
