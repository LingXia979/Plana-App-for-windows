import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/ui/scroll_memory.dart';

/// 滚动记忆:列表被拆掉重建后回原位;key 随作用域变时各记各的
/// (灵感页换分类 / 分段、标签库 ↔ 法典、换法典都靠这条)。
void main() {
  Widget list(ScrollController c, Key key) => MaterialApp(
    home: ListView.builder(
      key: key,
      controller: c,
      itemExtent: 100,
      itemCount: 100,
      itemBuilder: (_, i) => Text('$i'),
    ),
  );

  testWidgets('列表拆掉再建回来:落在上次的位置', (tester) async {
    ScrollMemory.forget('t.rebuild');
    final c = MemoScrollController('t.rebuild');
    addTearDown(c.dispose);

    await tester.pumpWidget(list(c, const ValueKey(1)));
    c.jumpTo(1200);
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: Text('空')));
    await tester.pumpWidget(list(c, const ValueKey(1)));

    expect(c.offset, 1200);
  });

  testWidgets('作用域换来换去:各自的位置都在', (tester) async {
    ScrollMemory.forget('t.scope.a');
    ScrollMemory.forget('t.scope.b');
    var scope = 'a';
    final c = MemoScrollController.keyed(() => 't.scope.$scope');
    addTearDown(c.dispose);

    await tester.pumpWidget(list(c, ValueKey(scope)));
    c.jumpTo(800);
    await tester.pump();

    scope = 'b';
    await tester.pumpWidget(list(c, ValueKey(scope)));
    expect(c.offset, 0);
    c.jumpTo(300);
    await tester.pump();

    scope = 'a';
    await tester.pumpWidget(list(c, ValueKey(scope)));
    expect(c.offset, 800);

    scope = 'b';
    await tester.pumpWidget(list(c, ValueKey(scope)));
    expect(c.offset, 300);
  });

  // 换分类时作用域当场就变了,旧列表要等重建才换下;中间它还在惯性滚。
  testWidgets('作用域刚换、旧列表还没换下:它这时的滚动记回旧作用域', (tester) async {
    ScrollMemory.forget('t.race.a');
    ScrollMemory.forget('t.race.b');
    var scope = 'a';
    final c = MemoScrollController.keyed(() => 't.race.$scope');
    addTearDown(c.dispose);

    await tester.pumpWidget(list(c, const ValueKey('a')));
    c.jumpTo(500);
    scope = 'b'; // 还没重建
    c.jumpTo(900);
    expect(ScrollMemory.read('t.race.a'), 900);
    expect(ScrollMemory.read('t.race.b'), isNull);

    await tester.pumpWidget(list(c, const ValueKey('b')));
    expect(c.offset, 0);
    c.jumpTo(200);
    expect(ScrollMemory.read('t.race.b'), 200);
  });
}
