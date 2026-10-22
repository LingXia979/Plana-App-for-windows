// 权重面板弹出把正文视口压矮时,刚点的那一处留在视野里(KeepInViewTracker)。
//
// 骨架同 chrome_scroll_test:正文滚动视图 + 底下一块会展开的面板,展开动画
// 真跑 —— 视口是一帧一帧变矮的,判定得跟着每一帧走。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/editor/chrome_scroll.dart';

const _content = Key('content');

class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final keep = KeepInViewTracker();
  final target = GlobalKey();
  bool panel = false;

  void openPanel() => setState(() => panel = true);

  @override
  Widget build(BuildContext context) {
    // 测试画布 800×600:面板 150;正文 1000 + 末尾 40 高的目标
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: NotificationListener<Notification>(
                onNotification: (n) {
                  if (keep.update(n)) {
                    final b = target.currentContext!.findRenderObject()!;
                    b.showOnScreen();
                  }
                  return false;
                },
                child: SingleChildScrollView(
                  key: _content,
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: Column(
                    children: [
                      const SizedBox(height: 1000, width: double.infinity),
                      SizedBox(key: target, height: 40, width: double.infinity),
                    ],
                  ),
                ),
              ),
            ),
            ClipRect(
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topCenter,
                heightFactor: panel ? 1 : 0,
                child: const SizedBox(height: 150, width: double.infinity),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

_HarnessState _state(WidgetTester tester) =>
    tester.state<_HarnessState>(find.byType(_Harness));

/// 摆好并滚到最底:目标贴着视口底边。
Future<void> _pumpAtBottom(WidgetTester tester) async {
  await tester.pumpWidget(const _Harness());
  final p = tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byKey(_content),
          matching: find.byType(Scrollable),
        ),
      )
      .position;
  p.jumpTo(p.maxScrollExtent);
  await tester.pump();
  expect(_targetVisible(tester), isTrue);
}

Future<void> _openPanel(WidgetTester tester) async {
  _state(tester).openPanel();
  await tester.pumpAndSettle();
}

/// 目标底边没被吃掉:不低于正文视口底边。
bool _targetVisible(WidgetTester tester) {
  final target = find.byKey(_state(tester).target);
  return tester.getRect(target).bottom <=
      tester.getRect(find.byKey(_content)).bottom + 0.5;
}

void main() {
  testWidgets('点了底下那一处,面板展开:跟着往上让', (tester) async {
    await _pumpAtBottom(tester);
    _state(tester).keep.arm();
    await _openPanel(tester);
    expect(_targetVisible(tester), isTrue);
  });

  testWidgets('没点过:面板展开不动滚动位置', (tester) async {
    await _pumpAtBottom(tester);
    await _openPanel(tester);
    expect(_targetVisible(tester), isFalse);
  });

  testWidgets('点了之后自己又滚过:不往回拽', (tester) async {
    await _pumpAtBottom(tester);
    _state(tester).keep.arm();
    await tester.drag(find.byKey(_content), const Offset(0, -30));
    await tester.pumpAndSettle();
    await _openPanel(tester);
    expect(_targetVisible(tester), isFalse);
  });
}
