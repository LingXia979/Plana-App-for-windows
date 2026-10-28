// 正文里正在打的那个词不送去翻译。
//
// 打 from_side 会先后问出 from_s、from_si、from_sid —— 每个都让服务端调一次
// 模型,注音层还会闪出半截译文。光标落在哪枚词上,那枚就先扣下;打了逗号、
// 光标挪走或失焦再补上。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/editor/editor_page.dart';

/// 摆一个文本形态的编辑器,返回「每次请求问了哪些词」的记录。
/// 生造词:免得撞上本地词库或别的用例灌进全局反查缓存的译名。
Future<List<List<String>>> _pumpEditor(WidgetTester tester) async {
  final asked = <List<String>>[];
  final svc = TagTranslationService(
    enabled: true,
    baseUrl: 'https://x.test',
    client: MockClient((req) async {
      final tags = [for (final t in jsonDecode(req.body)['tags'] as List) '$t'];
      asked.add(tags);
      return http.Response(jsonEncode({'missing': tags}), 200);
    }),
  );
  addTearDown(svc.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appStoresProvider.overrideWithValue(AppStores.ephemeral()),
        tagTranslationServiceProvider.overrideWithValue(svc),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const EditorPage(positive: true),
      ),
    ),
  );
  await tester.pump();
  return asked;
}

/// 过翻译防抖(700ms)。
Future<void> _settle(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 1));

/// 收尾:编辑器回写 → 工作区落盘还有一道防抖,留到最后会被判「还有挂着的 Timer」。
Future<void> _drain(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 3));

Iterable<String> _all(List<List<String>> asked) => asked.expand((b) => b);

void main() {
  final field = find.byType(EditableText).first;

  testWidgets('逐字打的半截不问,打了逗号整词才问', (tester) async {
    final asked = await _pumpEditor(tester);

    for (final s in ['zqxw_t', 'zqxw_ty', 'zqxw_typ']) {
      await tester.enterText(field, s);
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _settle(tester);
    expect(asked, isEmpty, reason: '光标还在词上,一个半截都不该问');

    await tester.enterText(field, 'zqxw_typing, ');
    await _settle(tester);
    expect(_all(asked), ['zqxw typing']);
    await _drain(tester);
  });

  testWidgets('光标挪走后补问刚才那枚,接着打的新词仍扣下', (tester) async {
    final asked = await _pumpEditor(tester);

    await tester.enterText(field, 'zqxw_left, zqxw_rig');
    await _settle(tester);
    expect(_all(asked), ['zqxw left'], reason: '前一枚已打完,光标所在的不问');

    // 光标点回前一枚(它已问过),正在打的那枚离开了光标 → 补上
    final ctrl = tester.widget<EditableText>(field).controller;
    ctrl.selection = const TextSelection.collapsed(offset: 2);
    await _settle(tester);
    expect(_all(asked), ['zqxw left', 'zqxw rig']);
    await _drain(tester);
  });

  testWidgets('失焦后补问光标那枚', (tester) async {
    final asked = await _pumpEditor(tester);

    await tester.enterText(field, 'zqxw_blur');
    await _settle(tester);
    expect(asked, isEmpty);

    FocusManager.instance.primaryFocus?.unfocus();
    await _settle(tester);
    expect(_all(asked), ['zqxw blur']);
    await _drain(tester);
  });

  testWidgets('输入法组词及仅 composing 更新不发半截，提交分隔符后才问', (tester) async {
    final asked = await _pumpEditor(tester);
    await tester.showKeyboard(field);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zqxw_ime',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 0, end: 8),
      ),
    );
    await _settle(tester);
    expect(asked, isEmpty);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zqxw_ime',
        selection: TextSelection.collapsed(offset: 8),
      ),
    );
    await _settle(tester);
    expect(asked, isEmpty);
    await tester.enterText(field, 'zqxw_ime, ');
    await _settle(tester);
    expect(_all(asked), ['zqxw ime']);
    await _drain(tester);
  });

  testWidgets('选中完整词时补问，取消选区不会重复请求', (tester) async {
    final asked = await _pumpEditor(tester);
    const text = 'zqxw_selected';
    await tester.enterText(field, text);
    await _settle(tester);
    expect(asked, isEmpty);
    final ctrl = tester.widget<EditableText>(field).controller;
    ctrl.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: text.length,
    );
    await _settle(tester);
    expect(_all(asked), ['zqxw selected']);
    ctrl.selection = const TextSelection.collapsed(offset: text.length);
    await _settle(tester);
    expect(_all(asked), ['zqxw selected']);
    await _drain(tester);
  });
}
