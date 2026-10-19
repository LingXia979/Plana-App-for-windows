import 'dart:typed_data';
import 'dart:ui' as ui;

import 'image_resources.dart';

/// 透明背景(NAI V5 的 transparency 能力)的公共判定与像素工具。
///
/// 透明**不是**一个开关,是模型能力:提示词里带 `transparent background`,V5 就
/// 直接吐带 alpha 的图。所以「适配透明」的绝大部分工作量不在发送侧 —— 图一旦
/// 生成,后面每一步都可能把它拍平:缩略图垫黑底、LSB 隐写把 alpha 全写成 255、
/// 图生图底图垫黑底。这些下游环节统一从这里取判据。
///
/// 对齐 web `utils/transparency.ts`。

/// 判「有真透明」的 alpha 阈值。
///
/// ⚠ NAI 的 LSB 隐写写在 **alpha 最低位**上,所以一张完全不透明的 NAI 图,alpha
/// 实际是 254/255 混着的。拿 `< 255` 判会把**每一张** NAI 图都当成透明图,
/// 必须卡在 254 以下。
const kOpaqueAlphaFloor = 254;

/// 这批 RGBA 里有没有真的透明部分。
bool rgbaHasAlpha(Uint8List rgba) {
  for (var i = 3; i < rgba.length; i += 4) {
    if (rgba[i] < kOpaqueAlphaFloor) return true;
  }
  return false;
}

/// 抹掉藏在 alpha 最低位里的 LSB 隐写数据,**但不把透明图拍成实心**。
///
/// 以前这里是把 alpha 一律推成 255 —— 对不透明图没差,却会把透明图直接拍实,
/// 用户存下来的透明 PNG 变成黑底。改成两端吸到端点、中间清最低位:
/// - `>= 254` → 255(全不透明还是全不透明,不会停在 254)
/// - `<= 1`   → 0  (全透明还是全透明,不会停在 1)
/// - 其余     → `& 0xfe`(抗锯齿边缘,差 1/255 看不出来)
///
/// 载荷照样废掉:清完之后按位读出来的是图自己的轮廓,不是 `stealth_pngcomp`。
/// 而对本来就不透明的图,这条规则退化成「254/255 都变 255」,与旧行为一模一样。
///
/// ⚠ 隐写写的是 **alpha** 不是 RGB,NAI 对透明图也照写不误 —— web 实测一张 66%
/// 全透明的 V5 图,透明区里有 5205 个像素 alpha=1,就是被写进去的位。
void clearAlphaLsb(Uint8List rgba) {
  for (var i = 3; i < rgba.length; i += 4) {
    final a = rgba[i];
    rgba[i] = a >= 254
        ? 255
        : a <= 1
        ? 0
        : a & 0xfe;
  }
}

/// 一张 PNG 有没有透明像素。
///
/// **缩到 96px 再看**:整图解码在 3000×3000 上要几十毫秒,而透明区域基本都是成片
/// 的背景,缩图后照样 alpha=0,抽样足够。降采样会把「一个像素宽的半透边缘」糊掉,
/// 但那种图判成不透明也无所谓 —— 这个结果只用来决定要不要保 alpha。
///
/// 解不开时返回 false(当不透明处理):拿不准就走旧行为,别把一条正常路径掐掉。
Future<bool> pngHasAlpha(Uint8List png) async {
  try {
    return await withDecodedImage(
      png,
      (image) async {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        return data != null && rgbaHasAlpha(data.buffer.asUint8List());
      },
      targetWidth: 96,
      allowUpscaling: false,
    );
  } catch (_) {
    return false;
  }
}

// ==================== 提示词侧 ====================

/// 触发透明输出的 tag,逐字对齐官方。
const kTransparentBackgroundTag = 'transparent background';

/// 把一个 tag 归一化到可比形式:脱掉强调括号、数值权重(`1.3::x::`)与首尾空白。
/// **认 tag 不认子串** —— `transparent background overlay` 不该命中。
String _normalizeTag(String raw) => raw
    .replaceAll(RegExp(r'[{}\[\]]'), '')
    .replaceFirst(RegExp(r'^\s*-?[\d.]+\s*::'), '')
    .replaceFirst(RegExp(r'::\s*$'), '')
    .trim()
    .toLowerCase();

/// 提示词里是否带 `transparent background`(按逗号 / 竖线 / 换行切开逐条比)。
bool promptHasTransparentBackground(String? prompt) {
  if (prompt == null || prompt.isEmpty) return false;
  return prompt
      .split(RegExp(r'[,，|\n]'))
      .any((seg) => _normalizeTag(seg) == kTransparentBackgroundTag);
}

/// base + 角色提示词里任意一处带 tag 就算 —— 多角色时角色词也会触发透明。
bool anyPromptHasTransparentBackground(
  String? base, [
  List<String?> characterPrompts = const [],
]) =>
    promptHasTransparentBackground(base) ||
    characterPrompts.any(promptHasTransparentBackground);
