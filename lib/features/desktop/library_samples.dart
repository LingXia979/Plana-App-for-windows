import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Code-drawn examples live outside both libraries and generation state.
class LibrarySamples extends StatelessWidget {
  const LibrarySamples({super.key});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
        child: Text(
          '示例预览 · 用来查看卡片大小和不同画幅，导入素材后显示你的图片。',
          style: TextStyle(
            fontSize: 12,
            color: context.scheme.onSurfaceVariant,
          ),
        ),
      ),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(14),
          itemCount: 6,
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisExtent: 246,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
          ),
          itemBuilder: (context, i) => Material(
            color: context.scheme.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: context.scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ColoredBox(
                    color: context.scheme.surfaceContainerLow,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: [.68, 1.6, 1.0][i % 3],
                        child: CustomPaint(painter: _SamplePainter(i)),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 9, 10, 2),
                  child: Text(
                    ['蓝调小猫', '远山来信', '森林旅伴', '暮色小猫', '海风与晴空', '午后旅伴'][i],
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: Text(
                    '${['竖幅', '横幅', '方图'][i % 3]} · 布局示例',
                    style: TextStyle(
                      fontSize: 11,
                      color: context.scheme.outline,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

class _SamplePainter extends CustomPainter {
  const _SamplePainter(this.variant);
  final int variant;
  @override
  void paint(Canvas canvas, Size size) {
    final colors = [
      const Color(0xFF5D879D),
      const Color(0xFF799992),
      const Color(0xFF988BAD),
    ];
    final color = colors[variant % 3];
    final w = size.width, h = size.height;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Color.lerp(color, Colors.white, .84)!,
    );
    canvas.drawCircle(
      Offset(w * .74, h * .22),
      w * .18,
      Paint()..color = const Color(0xFFFFFBF0),
    );
    for (var j = 0; j < 3; j++) {
      final y = h * (.58 + .12 * j);
      final hill = Path()
        ..moveTo(0, y)
        ..quadraticBezierTo(w * .25, y - h * .23, w * .52, y)
        ..quadraticBezierTo(w * .78, y + h * .12, w, y - h * .07)
        ..lineTo(w, h)
        ..lineTo(0, h)
        ..close();
      canvas.drawPath(
        hill,
        Paint()..color = Color.lerp(color, Colors.white, .58 - j * .24)!,
      );
    }
    if (variant % 3 == 1) return;
    final center = Offset(w * .48, h * .49);
    final radius = w * .22;
    final cream = Paint()..color = const Color(0xFFF9F3E8);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(center.dx, h * .76),
        width: w * .49,
        height: h * .37,
      ),
      cream,
    );
    final ears = Path()
      ..moveTo(center.dx - radius, center.dy)
      ..lineTo(center.dx - radius * .92, center.dy - radius * 1.55)
      ..lineTo(center.dx, center.dy - radius * .55)
      ..lineTo(center.dx + radius * .92, center.dy - radius * 1.55)
      ..lineTo(center.dx + radius, center.dy)
      ..close();
    canvas.drawPath(ears, cream);
    canvas.drawCircle(center, radius, cream);
    final ink = Paint()..color = const Color(0xFF42515F);
    for (final dx in [-.38, .38]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: center + Offset(radius * dx, radius * .02),
          width: radius * .12,
          height: radius * .24,
        ),
        ink,
      );
    }
    canvas.drawCircle(
      center + Offset(0, radius * .3),
      radius * .065,
      Paint()..color = const Color(0xFFD5A4A3),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(center.dx, center.dy + radius),
          width: radius * 2,
          height: radius * .25,
        ),
        const Radius.circular(4),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _SamplePainter oldDelegate) =>
      oldDelegate.variant != variant;
}
