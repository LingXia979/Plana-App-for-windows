import 'package:flutter/material.dart';

import '../../../core/net/remote_image.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/fade_in_once.dart';
import 'codex_image_loading.dart';
import 'codex_models.dart';

/// 法典的共用卡片与图片渐显。
///
/// 单独成文件是为了**断开 import 环**:浏览器(codex_view)与弹层(codex_sheets)
/// 都要用它,而两者本来就是单向依赖(view → sheets)。把共用件留在任一侧,
/// 另一侧反过来 import 就成了环。

/// 网络图渐显:与灵感页画师/角色卡同款——帧到达前透明,到达后淡入。
Widget codexFadeIn(
  BuildContext context,
  Widget child,
  int? frame,
  bool wasSync,
) {
  if (wasSync) return child;
  return AnimatedOpacity(
    opacity: frame == null ? 0 : 1,
    duration: Motion.medium,
    curve: Curves.easeOut,
    child: child,
  );
}

/// 瀑布流卡:例图(cover)+ 底部渐变标题;无图退成配色块 + 居中标题。
/// 收藏夹也用它(那边给 [fixedAspect] 走等比网格,不做瀑布流)。
class CodexCard extends StatelessWidget {
  const CodexCard({
    super.key,
    required this.codex,
    required this.entry,
    required this.media,
    required this.onTap,
    this.fixedAspect,
    this.decodeWidth,
    this.desktop = false,
    this.favorite = false,
    this.onFavorite,
    this.imageLoading,
  });

  final CodexMeta codex;
  final CodexEntry entry;
  final CodexMedia media;
  final VoidCallback onTap;
  final bool desktop, favorite;
  final VoidCallback? onFavorite;
  final CodexImageLoadController? imageLoading;

  /// 覆盖词条自身比例(等比网格用);null = 按词条比例(瀑布流)。
  final double? fixedAspect;

  /// 例图的解码宽(逻辑像素);null = 按布局宽。能换列数的网格按落定的列宽给,
  /// 换档过渡途中不变 —— 按实时格宽解码的话,那几百毫秒里每一帧都是一路新解码。
  final double? decodeWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    // 捏到三四列以后卡片很窄:标题收成一行、小一号,不然两行字的渐变条能把
    // 横图整张盖住。按宽度判,同一屏卡片的字号一致。
    builder: (context, c) => desktop
        ? _desktopCard(context)
        : _card(context, compact: c.maxWidth < 130),
  );

  Widget _desktopCard(BuildContext context) {
    final scheme = context.scheme;
    final url = codexImageUrl(codex, entry, media);
    return Material(
      color: scheme.surfaceContainerLowest,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: scheme.surfaceContainerLow,
                    child: url == null
                        ? _placeholder(context)
                        : LayoutBuilder(
                            builder: (context, bounds) =>
                                _desktopPreview(context, url, bounds.maxHeight),
                          ),
                  ),
                  if (entry.path.isNotEmpty || entry.isNew)
                    Positioned(
                      left: 10,
                      top: 10,
                      right: 54,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surface.withValues(alpha: .94),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            entry.isNew ? 'NEW' : entry.path.last,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.texts.labelSmall,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: IconButton.filledTonal(
                      tooltip: favorite ? '取消收藏' : '收藏',
                      onPressed: onFavorite,
                      icon: Icon(
                        favorite ? Icons.star_rounded : Icons.star_outline,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.titleSmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    entry.fullText.replaceAll(RegExp(r'\s+'), ' '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodySmall!.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      Text(
                        '查看提示词',
                        style: context.texts.labelLarge!.copyWith(
                          color: scheme.primary,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        Icons.arrow_forward,
                        color: scheme.primary,
                        size: 18,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _desktopPreview(BuildContext context, String url, double height) {
    final scheme = context.scheme;
    Widget preview(RemoteImageProviderDecorator? decorator) => RemoteImage(
      url,
      fit: BoxFit.contain,
      decodeWidth: decodeWidth,
      decodeHeight: height,
      providerDecorator: decorator,
      gaplessPlayback: imageLoading != null,
      frameBuilder: (context, child, frame, wasSync) => wasSync || frame != null
          ? child
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.image_outlined,
                    color: scheme.outlineVariant,
                    size: 32,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '预览加载中…',
                    style: context.texts.bodySmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ],
              ),
            ),
      errorBuilder: (_, _, _) => _placeholder(context),
    );

    final controller = imageLoading;
    return controller == null
        ? preview(null)
        : CodexDeferredImage(
            key: ValueKey(url),
            controller: controller,
            builder: preview,
          );
  }

  Widget _card(BuildContext context, {required bool compact}) {
    final scheme = context.scheme;
    final url = codexImageUrl(codex, entry, media);
    final aspect = fixedAspect ?? (entry.aspect <= 0 ? 0.75 : entry.aspect);
    return Material(
      color: scheme.surfaceContainer,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            AspectRatio(
              aspectRatio: aspect,
              child: url == null
                  ? _placeholder(context)
                  : FadeInOnce(
                      source: url,
                      builder: (_, frame) => RemoteImage(
                        url,
                        fit: BoxFit.cover,
                        decodeWidth: decodeWidth,
                        gaplessPlayback: true,
                        frameBuilder: frame,
                        errorBuilder: (_, _, _) => _placeholder(context),
                      ),
                    ),
            ),
            if (url != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: compact
                      ? const EdgeInsets.fromLTRB(8, 12, 8, 6)
                      : const EdgeInsets.fromLTRB(10, 16, 10, 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: .66),
                      ],
                    ),
                  ),
                  child: Text(
                    entry.title,
                    maxLines: compact ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 11.5 : 12.5,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            if (entry.isNew)
              Positioned(
                left: 7,
                top: 7,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.tertiary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'NEW',
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.onTertiary,
                      fontWeight: FontWeight.w800,
                      fontSize: 9,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final scheme = context.scheme;
    return ColoredBox(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: Text(
            entry.title,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: context.texts.bodySmall!.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
