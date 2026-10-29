import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/rendering.dart';

import '../models.dart';

/// 图库网格的等高行几何:同一行的图一样高,宽按各自长宽比,整行铺满可用宽。
///
/// 目标行高按 [cols] 定:一行正好放下 [cols] 张 2:3 竖图。逐张往行里加,行高
/// 掉到目标以下时,在「加上这张」与「不加」之间取离目标近的那个断行。每段最后
/// 一行不拉伸,沿用上一行的行高靠左。
///
/// 每格四周还有 [inset](缩略图的描边 + 让位):图本身按长宽比,格子再加回这一圈。
class JustifiedGridLayout extends SliverGridLayout {
  factory JustifiedGridLayout(
    List<ResultImage> items, {
    required int cols,
    required double width,
    required double gap,
    required double inset,
  }) {
    final n = items.length;
    final left = Float64List(n), top = Float64List(n);
    final w = Float64List(n), h = Float64List(n);
    final cell = (width - gap * (cols - 1)) / cols;
    final target = math.max(1.0, (cell - inset) * 1.5);
    final maxH = target * _maxStretch;

    // k 张、长宽比之和 s 时,铺满一行的图高
    double fill(int k, double s) =>
        math.max(1.0, (width - inset * k - gap * (k - 1)) / s);

    var y = 0.0;
    var start = 0;
    double? lastH;
    while (start < n) {
      var sum = 0.0;
      var end = start;
      double? rowH;
      while (end < n) {
        final s2 = sum + _aspect(items[end]);
        final h2 = fill(end - start + 1, s2);
        if (h2 >= target) {
          sum = s2;
          end++;
          continue;
        }
        final hPrev = end == start ? double.infinity : fill(end - start, sum);
        if (target / h2 <= hPrev / target) {
          sum = s2;
          end++;
          rowH = h2;
        } else {
          rowH = hPrev;
        }
        break;
      }
      // 段尾那行没满(铺满的话会高过目标):沿用上一行的行高,靠左
      rowH = math.min(
        rowH ?? math.min(fill(end - start, sum), lastH ?? target),
        maxH,
      );
      lastH = rowH;
      var x = 0.0;
      for (var i = start; i < end; i++) {
        left[i] = x;
        top[i] = y;
        w[i] = _aspect(items[i]) * rowH + inset;
        h[i] = rowH + inset;
        x += w[i] + gap;
      }
      y += rowH + inset + gap;
      start = end;
    }
    return JustifiedGridLayout._(left, top, w, h);
  }

  const JustifiedGridLayout._(this._left, this._top, this._w, this._h);

  /// 单行最多比目标行高高出多少。只在极端比例的图挤在一起时才会碰到。
  static const _maxStretch = 1.6;

  /// 超长 / 超宽图按这个范围算格子,桌面端在格子里 contain，保留整张图。
  static double _aspect(ResultImage r) {
    final a = r.aspect;
    return a.isFinite && a > 0 ? a.clamp(.5, 2.5) : 1.0;
  }

  final Float64List _left;

  /// 各格顶边与底边都**单调不减**:一行一样高,行与行依次往下排。
  final Float64List _top;
  final Float64List _w;
  final Float64List _h;

  /// 第一格底边越过 [offset] 的下标(再往前的都整个在它上方)。
  int _firstReachingPast(double offset) {
    var lo = 0, hi = _top.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_top[mid] + _h[mid] > offset) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  /// 第一格顶边不早于 [offset] 的下标(从它起都整个在它下方)。
  int _firstStartingAt(double offset) {
    var lo = 0, hi = _top.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_top[mid] < offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) =>
      _firstReachingPast(scrollOffset);

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    if (_top.isEmpty) return 0;
    return math.min(
      _top.length - 1,
      math.max(
        _firstStartingAt(scrollOffset) - 1,
        _firstReachingPast(scrollOffset),
      ),
    );
  }

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    // 越界的下标 RenderSliverGrid 只拿来试探「还有没有下一个」,给个末尾的空格子
    if (index >= _top.length) {
      return SliverGridGeometry(
        scrollOffset: computeMaxScrollOffset(_top.length),
        crossAxisOffset: 0,
        mainAxisExtent: 0,
        crossAxisExtent: 0,
      );
    }
    return SliverGridGeometry(
      scrollOffset: _top[index],
      crossAxisOffset: _left[index],
      mainAxisExtent: _h[index],
      crossAxisExtent: _w[index],
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) =>
      _top.isEmpty ? 0 : _top.last + _h.last;
}

/// 几何按(列数, 可用宽, 间隔, 内缩)缓存在条目列表上:滚动时每帧都要取,换列过渡每帧要
/// 起点、目标两套。列表一换(重建时分组重算)旧缓存随之回收。
final _layouts =
    Expando<Map<(int, double, double, double), JustifiedGridLayout>>();

class JustifiedGridDelegate extends SliverGridDelegate {
  const JustifiedGridDelegate(
    this.items, {
    required this.cols,
    required this.gap,
    required this.inset,
  });

  final List<ResultImage> items;
  final int cols;
  final double gap;
  final double inset;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final width = constraints.crossAxisExtent;
    return (_layouts[items] ??= {})[(
      cols,
      width,
      gap,
      inset,
    )] ??= JustifiedGridLayout(
      items,
      cols: cols,
      width: width,
      gap: gap,
      inset: inset,
    );
  }

  @override
  bool shouldRelayout(JustifiedGridDelegate old) =>
      old.cols != cols ||
      old.gap != gap ||
      old.inset != inset ||
      !identical(old.items, items);
}
