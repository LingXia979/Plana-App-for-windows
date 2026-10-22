// 点角色卡上的名字改名。
//
// 两处容易一起坏:热区只包名字本身,外层那圈仍是「点开编辑器」,里层得先拿到
// 这一下;留空要回到默认的「角色 N」—— 真存个空名字,那一行就只剩电源开关和
// 站位徽章,谁是谁看不出来。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/editor_page.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/widgets/character_card.dart';

/// 摆两张角色卡的面板(addCharacter 自己会把面板展开)。
///
/// 存储走 `AppStores.ephemeral()`:`open()` 是真的读盘,在 testWidgets 的
/// fake-async 里那个 await 永远回不来,整个测试干等到超时。
Future<GenerateNotifier> _pumpCard(WidgetTester tester) async {
  final c = ProviderContainer(
    overrides: [appStoresProvider.overrideWithValue(AppStores.ephemeral())],
  );
  addTearDown(c.dispose);
  final gen = c.read(generateProvider.notifier);
  gen.addCharacter();
  gen.addCharacter();

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: SingleChildScrollView(child: CharacterCard()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return gen;
}

List<String> _names(GenerateNotifier gen) => [
  for (final c in gen.state.characters) c.name,
];

/// 工作区落盘是 800ms 防抖,计时器留到收尾会被判「还有挂着的 Timer」。
Future<void> _flushAutosave(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 1));

void main() {
  testWidgets('点名字弹改名,保存后卡上换成新名字', (tester) async {
    final gen = await _pumpCard(tester);

    await tester.tap(find.text('角色 2'));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.byType(EditorPage), findsNothing, reason: '里层先拿到这一下');

    await tester.enterText(find.byType(TextField), '  小夜  ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(_names(gen), ['角色 1', '小夜'], reason: '两头空白去掉,只改点到的那张');
    expect(find.text('小夜'), findsOneWidget);
    await _flushAutosave(tester);
  });

  testWidgets('留空回到默认的「角色 N」', (tester) async {
    final gen = await _pumpCard(tester);
    gen.updateCharacter(gen.state.characters[1].id, name: '小夜');
    await tester.pumpAndSettle();

    await tester.tap(find.text('小夜'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(_names(gen), ['角色 1', '角色 2']);
    await _flushAutosave(tester);
  });

  testWidgets('取消不动名字', (tester) async {
    final gen = await _pumpCard(tester);

    await tester.tap(find.text('角色 1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '小夜');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(_names(gen), ['角色 1', '角色 2']);
    await _flushAutosave(tester);
  });

  testWidgets('卡上直接删除,只移除选中的角色', (tester) async {
    final gen = await _pumpCard(tester);

    await tester.tap(find.byTooltip('删除角色').at(1));
    await tester.pumpAndSettle();
    expect(_names(gen), ['角色 1']);
    expect(find.byType(EditorPage), findsNothing);
    await _flushAutosave(tester);
  });

  testWidgets('名称和三个按钮共用顶行,尺寸和间距与角色栏一致', (tester) async {
    await _pumpCard(tester);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final width in [360.0, 320.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();
      final headerClear = tester.getRect(find.byTooltip('清空全部角色'));
      final headerLibrary = tester.getRect(find.byTooltip('角色库'));
      final headerAdd = tester.getRect(find.byTooltip('添加角色'));
      final position = tester.getRect(find.byTooltip('设置角色位置：AUTO').first);
      final toggle = tester.getRect(find.byTooltip('停用(保留配置)').first);
      final remove = tester.getRect(find.byTooltip('删除角色').first);
      final name = tester.getRect(find.text('角色 1'));

      expect(position.size, headerClear.size);
      expect(toggle.size, headerLibrary.size);
      expect(remove.size, headerAdd.size);
      expect(position.width, position.height);
      expect(toggle.height, position.height);
      expect(toggle.width, position.width);
      expect(remove.height, position.height);
      expect(remove.width, position.width);
      expect(toggle.center.dy, position.center.dy);
      expect(remove.center.dy, position.center.dy);
      expect(
        toggle.left - position.right,
        headerLibrary.left - headerClear.right,
      );
      expect(remove.left - toggle.right, headerAdd.left - headerLibrary.right);
      expect(name.center.dy, position.center.dy);
      expect(name.right, lessThan(position.left));
      expect(tester.takeException(), isNull);
    }
    await _flushAutosave(tester);
  });

  testWidgets('预览框保留边距,始终为832:1216且不随提示词拉长', (tester) async {
    final gen = await _pumpCard(tester);
    final id = gen.state.characters.first.id;
    final tile = find.byKey(ValueKey('char$id'));
    final avatar = find.descendant(of: tile, matching: find.byTooltip('从角色库选'));
    final emptyTile = tester.getRect(tile);
    final emptyAvatar = tester.getRect(avatar);
    expect(emptyAvatar.width / emptyAvatar.height, closeTo(832 / 1216, 1e-9));
    expect(emptyAvatar.left, emptyTile.left + 8);
    expect(emptyAvatar.top, emptyTile.top + 8);
    expect(emptyTile.bottom - emptyAvatar.bottom, greaterThanOrEqualTo(8));

    gen.updateCharacter(id, positive: '1girl', negative: 'bad hands, lowres');
    await tester.pumpAndSettle();
    final filledTile = tester.getRect(tile);
    final filledAvatar = tester.getRect(avatar);
    expect(filledAvatar.width / filledAvatar.height, closeTo(832 / 1216, 1e-9));
    expect(filledAvatar.size, emptyAvatar.size);
    expect(filledAvatar.left, filledTile.left + 8);
    expect(filledAvatar.top, filledTile.top + 8);
    expect(filledTile.bottom - filledAvatar.bottom, greaterThanOrEqualTo(8));
    await _flushAutosave(tester);
  });

  testWidgets('停用入口保留角色配置,可再次启用', (tester) async {
    final gen = await _pumpCard(tester);
    final char = gen.state.characters.first;
    gen.updateCharacter(char.id, positive: '1girl, blue hair', position: 'B2');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('停用(保留配置)').first);
    await tester.pumpAndSettle();
    final disabled = gen.state.characters.first;
    expect(disabled.enabled, isFalse);
    expect(disabled.positive, '1girl, blue hair');
    expect(disabled.position, 'B2');

    await tester.tap(find.byTooltip('启用'));
    await tester.pumpAndSettle();
    expect(gen.state.characters.first.enabled, isTrue);
    await _flushAutosave(tester);
  });
}
