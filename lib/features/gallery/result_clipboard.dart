/// 把作品写进系统剪贴板(桌面端专有)。
///
/// Flutter 自带的 [Clipboard] 只有文本,图片那半截在原生侧,见
/// [DesktopClipboard]。这里只管「取字节 → 交付 → 报回执」这一段:取字节的路子
/// 与保存/分享一致(内存里有就直接用,没有才去库里读),回执也跟保存一个格式。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/clipboard_image.dart';
import '../../core/store/app_stores.dart';
import '../generate/widgets/common.dart' show hintSnack;
import 'models.dart';

/// 复制一张图库作品。
Future<void> copyResultToClipboard(
  BuildContext context,
  WidgetRef ref,
  ResultImage result,
) async {
  final bytes =
      result.bytes ??
      await ref.read(appStoresProvider).gallery.readImage(result.id);
  if (!context.mounted) return;
  if (bytes == null || bytes.isEmpty) {
    hintSnack(context, '图片还没读出来，稍后再试', icon: Icons.error_outline);
    return;
  }
  await copyBytesToClipboard(context, bytes);
}

/// 复制一段现成的图片字节(对话里那张图、参考图预览等)。
Future<void> copyBytesToClipboard(BuildContext context, Uint8List bytes) async {
  final ok = await DesktopClipboard.writeImage(bytes);
  if (!context.mounted) return;
  if (ok) {
    hintSnack(context, '图片已复制到剪贴板', icon: Icons.check_circle_outline);
    return;
  }
  // 说清楚是哪一种失败:Linux 上还没接原生侧,移动端压根不该走到这儿。
  hintSnack(context, '复制失败：当前系统不支持图片剪贴板', icon: Icons.error_outline);
}
