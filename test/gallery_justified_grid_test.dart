// 图库等高行几何(JustifiedGridLayout):断行、铺满、段尾不拉伸,
// 以及 SliverGrid 按首末下标建子项时不漏格。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/justified_grid.dart';

ResultImage _r(int i, int w, int h) =>
    ResultImage(id: 'gen$i', width: w, height: h, seed: 0);

JustifiedGridLayout _layout(List<ResultImage> items, {int cols = 3}) =>
    JustifiedGridLayout(items, cols: cols, width: 356, gap: 6, inset: 10);

void main() {
  test('changing spacing or border inset invalidates cached row geometry', () {
    final items = [for (var i = 0; i < 9; i++) _r(i, 832, 1216)];
    const constraints = SliverConstraints(
      axisDirection: AxisDirection.down,
      growthDirection: GrowthDirection.forward,
      userScrollDirection: ScrollDirection.idle,
      scrollOffset: 0,
      precedingScrollExtent: 0,
      overlap: 0,
      remainingPaintExtent: 600,
      crossAxisExtent: 356,
      crossAxisDirection: AxisDirection.right,
      viewportMainAxisExtent: 600,
      remainingCacheExtent: 600,
      cacheOrigin: 0,
    );
    for (final (gap, inset) in [(6.0, 10.0), (12.0, 10.0), (12.0, 4.0)]) {
      final actual = JustifiedGridDelegate(
        items,
        cols: 3,
        gap: gap,
        inset: inset,
      ).getLayout(constraints);
      final expected = JustifiedGridLayout(
        items,
        cols: 3,
        width: 356,
        gap: gap,
        inset: inset,
      );
      for (var i = 0; i < items.length; i++) {
        final a = actual.getGeometryForChildIndex(i);
        final e = expected.getGeometryForChildIndex(i);
        expect(a.crossAxisOffset, e.crossAxisOffset);
        expect(a.crossAxisExtent, e.crossAxisExtent);
        expect(a.scrollOffset, e.scrollOffset);
        expect(a.mainAxisExtent, e.mainAxisExtent);
      }
    }
  });

  test('全是 2:3 竖图:一行正好 cols 张,铺满整行', () {
    final items = [for (var i = 0; i < 9; i++) _r(i, 832, 1216)];
    final l = _layout(items);
    for (var row = 0; row < 3; row++) {
      final first = l.getGeometryForChildIndex(row * 3);
      final last = l.getGeometryForChildIndex(row * 3 + 2);
      expect(first.crossAxisOffset, 0);
      expect(last.crossAxisOffset + last.crossAxisExtent, closeTo(356, 1e-6));
      expect(last.scrollOffset, first.scrollOffset);
    }
    expect(
      l.getGeometryForChildIndex(3).scrollOffset,
      greaterThan(l.getGeometryForChildIndex(2).trailingScrollOffset),
    );
  });

  test('图本身保持长宽比(去掉四周 inset 之后)', () {
    final items = [
      _r(0, 1216, 832),
      _r(1, 832, 1216),
      _r(2, 1024, 1024),
      _r(3, 832, 1216),
    ];
    final l = _layout(items);
    for (var i = 0; i < items.length; i++) {
      final g = l.getGeometryForChildIndex(i);
      expect(
        (g.crossAxisExtent - 10) / (g.mainAxisExtent - 10),
        closeTo(items[i].aspect, 1e-9),
      );
    }
  });

  test('段尾没满的那行按目标行高靠左,不拉伸', () {
    final items = [for (var i = 0; i < 4; i++) _r(i, 832, 1216)];
    final l = _layout(items);
    final full = l.getGeometryForChildIndex(0);
    final tail = l.getGeometryForChildIndex(3);
    expect(tail.crossAxisOffset, 0);
    expect(tail.mainAxisExtent, closeTo(full.mainAxisExtent, 1e-6));
    expect(tail.crossAxisExtent, closeTo(full.crossAxisExtent, 1e-6));
  });

  test('超宽图单独一行也不超出可用宽', () {
    final l = _layout([_r(0, 4000, 500), _r(1, 832, 1216)]);
    final g = l.getGeometryForChildIndex(0);
    expect(
      g.crossAxisOffset + g.crossAxisExtent,
      lessThanOrEqualTo(356 + 1e-6),
    );
  });

  test('随机比例:每格都在可用宽内,首末下标覆盖所有相交格', () {
    final rnd = math.Random(7);
    const sizes = [(832, 1216), (1216, 832), (1024, 1024), (640, 1536)];
    for (final cols in [2, 3, 4, 5]) {
      final items = [
        for (var i = 0; i < 300; i++)
          (() {
            final (w, h) = sizes[rnd.nextInt(sizes.length)];
            return _r(i, w, h);
          })(),
      ];
      final l = _layout(items, cols: cols);
      for (var i = 0; i < items.length; i++) {
        final g = l.getGeometryForChildIndex(i);
        expect(g.crossAxisOffset, greaterThanOrEqualTo(-1e-6));
        expect(
          g.crossAxisOffset + g.crossAxisExtent,
          lessThanOrEqualTo(356 + 1e-6),
        );
      }
      final end = l.computeMaxScrollOffset(items.length);
      for (var a = 0.0; a < end; a += 37) {
        final b = a + 600;
        final lo = l.getMinChildIndexForScrollOffset(a);
        final hi = l.getMaxChildIndexForScrollOffset(b);
        for (var i = 0; i < items.length; i++) {
          final g = l.getGeometryForChildIndex(i);
          if (g.scrollOffset < b && g.trailingScrollOffset > a) {
            expect(i >= lo && i <= hi, isTrue, reason: '[$a, $b) 第 $i 格');
          }
        }
      }
    }
  });
}
