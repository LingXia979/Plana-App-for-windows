import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/net/remote_image.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/fade_in_once.dart';
import '../artist_models.dart';
import '../tag_models.dart';

/// 打码时预览只解出这么多像素宽,再按最近邻放大成方块。
const _kMosaicCells = 12;

/// 卡片预览图:无图 = 名称定色相的斜纹占位;http 走磁盘缓存;本机路径直读。
/// 加载完淡入,让预览逐张柔和显现而非硬蹦(只淡第一次,见 [FadeInOnce])。
/// 灵感页网格、选角色面板、角色卡头像共用。
class TagCardPreview extends StatelessWidget {
  const TagCardPreview({
    super.key,
    required this.url,
    required this.name,
    this.decodeWidth,
    this.placeholder,
    this.mosaic = false,
  });

  final String? url;
  final String name;

  /// 解码宽(逻辑像素);null = 远端按布局宽、本机图按原尺寸。
  /// 图像缓存存的是解码后的位图:角色卡头像只画 46dp,整张 832×1216 解出来
  /// 要占 4MB,所以本机图也按这个宽解。
  final double? decodeWidth;

  /// 无图 / 读图失败时的占位;null = 名称定色相的斜纹。
  final Widget? placeholder;

  /// 打成马赛克(忽略 [decodeWidth])。
  final bool mosaic;

  Widget get _empty => placeholder ?? _HueStripes(name: name);

  Widget _stripes(BuildContext context, Object error, StackTrace? stack) =>
      _empty;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final quality = mosaic ? FilterQuality.none : FilterQuality.medium;
    return switch (url) {
      null => _empty,
      final u => FadeInOnce(
        source: u,
        builder: (context, frame) => u.startsWith('http')
            ? RemoteImage(
                u,
                fit: BoxFit.cover,
                decodeWidth: mosaic ? _kMosaicCells / dpr : decodeWidth,
                filterQuality: quality,
                gaplessPlayback: true,
                frameBuilder: frame,
                errorBuilder: _stripes,
              )
            : Image.file(
                File(u),
                fit: BoxFit.cover,
                cacheWidth: mosaic
                    ? _kMosaicCells
                    : switch (decodeWidth) {
                        null => null,
                        final w => (w * dpr).round(),
                      },
                filterQuality: quality,
                gaplessPlayback: true,
                frameBuilder: frame,
                errorBuilder: _stripes,
              ),
      ),
    };
  }
}

/// 网格卡:预览图(无图=名称定色相的斜纹占位)+ 底部名称条 + 来源角标;
/// 左上选择圈,右上 ⋮(我的)/ ❤ 收藏(公共)。点卡选择,长按看详情。
/// 角上的按钮给了回调才画(选角色面板两样都不给)。
class TagCard extends StatelessWidget {
  const TagCard({
    super.key,
    required this.entry,
    this.previewUrl,
    required this.selected,
    required this.isPublic,
    this.collected = false,
    required this.onTap,
    required this.onLongPress,
    this.onCollect,
    this.onMenu,
    this.decodeWidth,
    this.showCheck = true,
    this.mosaic = false,
  });

  final TagEntry entry;

  /// 实际渲染的预览(可能是按 publicId 从公共库补的 http,覆盖 entry 自身)。
  final String? previewUrl;
  final bool selected;
  final bool isPublic;
  final bool collected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onCollect;
  final ValueChanged<String>? onMenu;

  /// 左上的选择圈。点一下就选定的场合(给单张角色卡换人)不画。
  final bool showCheck;

  /// 远端预览的解码宽(逻辑像素)。
  final double? decodeWidth;

  /// 预览打码,正中一枚闭眼标;点卡做什么由调用方定。
  final bool mosaic;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    // 捏到三四列以后卡片很小,角上两颗按钮和名字条照原尺寸画会把图盖满:收小
    // 一档,型号角标也收掉。按实测尺寸判,换档过渡途中越过门槛就换。
    builder: (context, c) =>
        _card(context, compact: c.maxWidth < 100 || c.maxHeight < 100),
  );

  Widget _card(BuildContext context, {required bool compact}) {
    final scheme = context.scheme;
    final modelGroups = artistModelGroups(entry.models);
    // 角上两颗按钮的边长与离边距离
    final btn = compact ? 30.0 : 40.0;
    final inset = compact ? 4.0 : 6.0;
    return AnimatedContainer(
      duration: Motion.fast,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16)),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.8 : 1,
        ),
      ),
      child: Material(
        color: scheme.surfaceContainer,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Stack(
            fit: StackFit.expand,
            children: [
              TagCardPreview(
                url: previewUrl,
                name: entry.name,
                decodeWidth: decodeWidth,
                mosaic: mosaic,
              ),
              if (mosaic)
                Center(
                  child: Container(
                    width: btn,
                    height: btn,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .42),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.visibility_off_outlined,
                      size: compact ? 17 : 21,
                      color: Colors.white,
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: compact
                      ? const EdgeInsets.fromLTRB(7, 10, 6, 5)
                      : const EdgeInsets.fromLTRB(10, 14, 8, 7),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: .62),
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 适用模型角标(按分档归并:标了 V5 Full + Curated 只出一个)。
                      // 没标注的不画 —— 「通用」是默认档,给每张卡都挂一个反而是噪音。
                      // 记了推荐参数的画风再挂一枚调参图标,同一排、同一款底。
                      if ((modelGroups.isNotEmpty || entry.recipe != null) &&
                          !compact) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (entry.recipe != null)
                              Container(
                                margin: const EdgeInsets.only(right: 4),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: .22),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Icon(
                                  Icons.tune,
                                  size: 10,
                                  color: Colors.white,
                                ),
                              ),
                            for (final g in modelGroups.take(2))
                              Container(
                                margin: const EdgeInsets.only(right: 4),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: .22),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  g.label,
                                  style: const TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            if (modelGroups.length > 2)
                              Text(
                                '+${modelGroups.length - 2}',
                                style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white70,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                      ],
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 11.5 : 13,
                          fontWeight: FontWeight.w800,
                          color: selected ? scheme.primary : Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (showCheck)
                Positioned(
                  top: compact ? 5 : 7,
                  left: compact ? 5 : 7,
                  child: AnimatedContainer(
                    duration: Motion.fast,
                    width: compact ? 20 : 24,
                    height: compact ? 20 : 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected
                          ? scheme.primary
                          : Colors.black.withValues(alpha: .3),
                      border: selected
                          ? null
                          : Border.all(color: Colors.white70, width: 1.5),
                    ),
                    child: selected
                        ? Icon(
                            Icons.check,
                            size: compact ? 13 : 16,
                            color: scheme.onPrimary,
                          )
                        : null,
                  ),
                ),
              // 公共卡:右上角收藏钮(40px 圆钮 + 半透明底,已收藏=实心红心);
              // 我的卡:右上角 ⋮ 菜单。
              if (isPublic && onCollect != null)
                Positioned(
                  right: inset,
                  top: inset,
                  child: Material(
                    color: collected
                        ? Colors.white.withValues(alpha: .92)
                        : Colors.black.withValues(alpha: .42),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: onCollect,
                      child: SizedBox(
                        width: btn,
                        height: btn,
                        child: Icon(
                          collected ? Icons.favorite : Icons.favorite_border,
                          size: compact ? 17 : 21,
                          color: collected ? scheme.error : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              if (!isPublic && onMenu != null)
                Positioned(
                  right: inset,
                  top: inset,
                  child: Material(
                    color: Colors.black.withValues(alpha: .42),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      width: btn,
                      height: btn,
                      child: PopupMenuButton<String>(
                        onSelected: onMenu,
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.more_vert,
                          size: compact ? 17 : 20,
                          color: Colors.white,
                        ),
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: _MenuRow(Icons.edit_outlined, '编辑'),
                          ),
                          const PopupMenuItem(
                            value: 'copy',
                            child: _MenuRow(Icons.copy, '复制提示词'),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: _MenuRow(
                              Icons.delete_outline,
                              '删除',
                              danger: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label, {this.danger = false});

  final IconData icon;
  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = danger ? context.scheme.error : context.scheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: danger ? c : null)),
      ],
    );
  }
}

/// 无预览图的占位:名称哈希定色相的深色渐变 + 斜纹 + 名称水印
/// (对齐 web HorizontalCard 的 hashHue 占位,同名恒同色)。
class _HueStripes extends StatelessWidget {
  const _HueStripes({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    var h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final hue = (h % 360).toDouble();
    return CustomPaint(
      painter: _HueStripePainter(hue),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            name.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 4,
              color: Colors.white.withValues(alpha: .2),
            ),
          ),
        ),
      ),
    );
  }
}

class _HueStripePainter extends CustomPainter {
  const _HueStripePainter(this.hue);

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final a = HSLColor.fromAHSL(1, hue, .38, .20).toColor();
    final b = HSLColor.fromAHSL(1, (hue + 24) % 360, .42, .13).toColor();
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [a, b],
        ).createShader(Offset.zero & size),
    );
    final stripe = Paint()..color = Colors.black.withValues(alpha: .16);
    const w = 14.0;
    for (double x = -size.height; x < size.width; x += w * 2.4) {
      final path = Path()
        ..moveTo(x, size.height)
        ..lineTo(x + size.height, 0)
        ..lineTo(x + size.height + w, 0)
        ..lineTo(x + w, size.height)
        ..close();
      canvas.drawPath(path, stripe);
    }
  }

  @override
  bool shouldRepaint(covariant _HueStripePainter old) => old.hue != hue;
}
