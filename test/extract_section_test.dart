// 编辑页多选「提取为新分区」。
//
// 容易坏的几处:角色会话里也冒出这颗(角色提示词没有分区);提取出来的
// 那格丢了权重 / 折叠;在负面页提取却进了正向;新格子没接在最后;编辑器里
// 撤销只还原了正文,新格子还在,同一批词两边各一份。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/editor_theme.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_state.dart';
import 'package:plana_app/features/editor/widgets/tag_panel.dart';
import 'package:plana_app/features/generate/generate_state.dart';

Future<void> _pumpPanel(WidgetTester tester, {VoidCallback? onExtract}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Theme(
            data: editorTheme(context),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: BatchPanel(
                  count: 2,
                  mult: 1,
                  canWeight: true,
                  canDisable: true,
                  anyEnabled: true,
                  onCopy: () {},
                  onExtract: onExtract,
                  onWrap: (_) {},
                  onStepMult: (_) {},
                  onClearWeight: () {},
                  onToggleDisabled: () {},
                  onDelete: () {},
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('复制旁边有「提取为新分区」;不给回调(角色会话)就不出现', (tester) async {
    var tapped = 0;
    await _pumpPanel(tester, onExtract: () => tapped++);
    expect(find.byTooltip('提取为新分区'), findsOneWidget);
    // 紧挨在复制左边
    final extract = tester.getCenter(find.byIcon(Icons.playlist_add));
    final copy = tester.getCenter(find.byIcon(Icons.content_copy));
    expect(extract.dx, lessThan(copy.dx));
    await tester.tap(find.byIcon(Icons.playlist_add));
    expect(tapped, 1);

    await _pumpPanel(tester);
    expect(find.byIcon(Icons.playlist_add), findsNothing);
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
  });

  group('提取的草稿:整组选中带走组权重,只取一部分不带', () {
    String draft(String text, Set<int> sel) =>
        extractUnitsDraft(text, const {}, sel);

    test('整组选中:组记号原样带走', () {
      const text = '1girl, 0.8::artist:a, artist:b::, smile';
      expect(draft(text, {1, 2}), '0.8::artist:a, artist:b::');
      expect(draft('1girl, {{a, b}}, smile', {1, 2}), '{{a, b}}');
      expect(draft('[a, b], c', {0, 1, 2}), '[a, b], c');
    });

    test('只取组里一部分:只取词本身', () {
      expect(draft('1girl, 0.8::artist:a, artist:b::, smile', {1}), 'artist:a');
      expect(draft('{a, b, c}', {0, 2}), 'a, c');
    });

    test('嵌套:内层整组带走,外层只选了一部分不带', () {
      const text = '1.2::x, {a, b}, y::';
      expect(draft(text, {1, 2}), '{a, b}');
      expect(draft(text, {0, 1, 2, 3}), text);
    });

    test('词自己的权重照旧带着;没收口的组不带', () {
      expect(draft('{{a}}, 1.3::b::, c', {0, 1}), '{{a}}, 1.3::b::');
      expect(draft('c, {a, b', {1, 2}), 'a, b');
    });
  });

  group('按草稿新建一格', () {
    late ProviderContainer c;
    late GenerateNotifier gen;
    setUp(() {
      c = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(AppStores.ephemeral())],
      );
      addTearDown(c.dispose);
      gen = c.read(generateProvider.notifier);
    });

    test('没分区时连主体一起建,新格子接在最后,权重和折叠原样带着', () {
      gen.setPrompts(positive: '1girl');
      final first = gen.addSectionFrom(
        '{rim light}, ~lens flare~, <#光影: backlighting, sunset#>',
        positive: true,
      );
      expect(first.name, '分区 1');
      final secs = gen.state.sections;
      expect([for (final s in secs) s.name], ['主体', '分区 1']);
      expect(secs.last.id, first.id);
      expect(secs.last.positive, '{rim light}, backlighting, sunset');
      expect(parseFolds(secs.last.positiveRaw).single.name, '光影');
      expect(secs.last.negative, isEmpty);
      expect(gen.addSectionFrom('x', positive: true).name, '分区 2');
      expect(gen.state.sections.last.name, '分区 2');
    });

    test('在负面页提取的进那一格的负面', () {
      gen.addSectionFrom('lowres, blurry', positive: false);
      final s = gen.state.sections.last;
      expect(s.positive, isEmpty);
      expect(s.negative, 'lowres, blurry');
    });

    test('编辑器里撤销这一步:正文回来,提取出的那一格一并拿掉', () {
      gen.setPrompts(positive: '1girl, rim light, lens flare');
      final editor = c.read(editorProvider.notifier);
      editor.load(
        positive: '1girl, rim light, lens flare',
        negative: '',
        startPositive: true,
      );
      final sec = gen.addSectionFrom('rim light, lens flare', positive: true);
      editor.editActive('1girl', structural: true, extracted: sec);
      editor.flushWriteBack();
      expect(gen.state.prompt, '1girl');
      expect([for (final s in gen.state.sections) s.name], ['主体', '分区 1']);

      editor.undo();
      editor.flushWriteBack();
      expect(gen.state.prompt, '1girl, rim light, lens flare');
      expect(gen.state.sections, isEmpty); // 只剩主体,回到没分区的样子
    });

    test('那一格之后改过词,撤销只还原正文、不替人扔掉它', () {
      gen.setPrompts(positive: '1girl, rim light');
      final editor = c.read(editorProvider.notifier);
      editor.load(
        positive: '1girl, rim light',
        negative: '',
        startPositive: true,
      );
      final sec = gen.addSectionFrom('rim light', positive: true);
      editor.editActive('1girl', structural: true, extracted: sec);
      editor.flushWriteBack();
      // 另开这一格写了别的,再回到主体撤销
      editor.load(
        positive: sec.positive,
        negative: '',
        startPositive: true,
        sectionId: sec.id,
      );
      editor.editActive('rim light, backlighting');
      editor.flushWriteBack();
      editor.load(positive: '1girl', negative: '', startPositive: true);
      editor.undo();
      editor.flushWriteBack();
      expect(gen.state.prompt, '1girl, rim light');
      expect(gen.state.sections.last.positive, 'rim light, backlighting');
    });
  });
}
