import 'dart:convert';

import 'package:crypto/crypto.dart';
import '../../core/util/canonical_number.dart';

/// .naiv4vibe / .naiv4vibebundle 编解码与 NAI 官方哈希口径。
/// 纯函数无 IO;字段结构对齐 web `utils/storage.ts` 的 Naiv4VibeFile。
///
/// 互通要点:
/// - encodings 的 hashKey = SHA256("information_extracted:" + IE 值),
///   其中 IE 值按 **JS Number 字符串**格式(1 而非 1.0)——见 [jsNum]。
/// - 文件 id = SHA256(image 的 base64 **文本**),与 app 内部缓存键用的
///   原始字节哈希是两个不同口径,不可混用。

/// NAI 模型 id → 文件 encodings 键(web MODEL_TO_ENCODING_KEY 同表)。
const kModelToEncodingKey = <String, String>{
  'nai-diffusion-4-full': 'v4full',
  'nai-diffusion-4-curated': 'v4curated',
  'nai-diffusion-4-curated-preview': 'v4curated',
  'nai-diffusion-4-5-full': 'v4-5full',
  'nai-diffusion-4-5-curated': 'v4-5curated',
  'nai-diffusion-3': 'v3',
};

/// encodings 键 → NAI 模型 id(web ENCODING_KEY_TO_MODEL 同表)。
const kEncodingKeyToModel = <String, String>{
  'v4full': 'nai-diffusion-4-full',
  'v4curated': 'nai-diffusion-4-curated',
  'v4-5full': 'nai-diffusion-4-5-full',
  'v4-5curated': 'nai-diffusion-4-5-curated',
  'v3': 'nai-diffusion-3',
};

/// encodings 键 → 短显示名(编码清单/卡片徽标用)。
const kEncodingKeyLabel = <String, String>{
  'v4full': 'V4',
  'v4curated': 'V4 Cur',
  'v4-5full': 'V4.5',
  'v4-5curated': 'V4.5 Cur',
  'v3': 'V3',
};

/// 按 JS `String(Number)` 语义转字符串:整数值不带小数点(1.0 → "1")。
/// Dart `1.0.toString()` 是 "1.0",直接拼进 hashKey 会与 web/官方算出不同哈希。
String jsNum(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString();

/// encodings 条目的 hashKey:SHA256("information_extracted:" + jsNum(ie))。
String vibeEncodingHashKey(double infoExtracted) => sha256
    .convert(utf8.encode('information_extracted:${jsNum(infoExtracted)}'))
    .toString();

/// NAI 官方 vibe id:SHA256(图片 base64 文本)。
String naiVibeIdOfBase64(String imageBase64) =>
    sha256.convert(utf8.encode(imageBase64)).toString();

/// 文件里的一条编码(拍扁后):模型键 + IE(params 缺失为 null)+ 编码串。
typedef VibeEncodingItem = ({
  String modelKey,
  double? infoExtracted,
  String encoding,
});

/// 一条已解析的 vibe。持有原始 JSON([raw]),读字段全走 getter——
/// 回写/导出时序列化 raw,第三方文件里的未知字段原样保留(文件即真相)。
class ParsedVibe {
  ParsedVibe(this.raw);

  final Map<String, dynamic> raw;

  String? get imageBase64 {
    final v = raw['image'];
    return v is String && v.isNotEmpty ? v : null;
  }

  String get id => raw['id'] is String ? raw['id'] as String : '';

  String get name => raw['name'] is String ? raw['name'] as String : '';

  String? get thumbnailDataUrl {
    final v = raw['thumbnail'];
    return v is String && v.startsWith('data:') ? v : null;
  }

  int get createdAt =>
      raw['createdAt'] is num ? (raw['createdAt'] as num).toInt() : 0;

  Map<String, dynamic>? get _importInfo => raw['importInfo'] is Map
      ? (raw['importInfo'] as Map).cast<String, dynamic>()
      : null;

  double? get defaultStrength => (_importInfo?['strength'] as num?)?.toDouble();

  double? get defaultInfoExtracted =>
      (_importInfo?['information_extracted'] as num?)?.toDouble();

  List<String> get tags => raw['tags'] is List
      ? [
          for (final t in raw['tags'] as List)
            if (t is String) t,
        ]
      : const [];

  /// encodings 里出现过的模型键(展示「支持的模型」)。
  List<String> get supportedModelKeys => raw['encodings'] is Map
      ? (raw['encodings'] as Map).keys.cast<String>().toList()
      : const [];

  /// 拍扁全部编码条目。
  List<VibeEncodingItem> get encodingItems {
    final encs = raw['encodings'];
    if (encs is! Map) return const [];
    final out = <VibeEncodingItem>[];
    for (final e in encs.entries) {
      final modelKey = e.key;
      final group = e.value;
      if (modelKey is! String || group is! Map) continue;
      for (final g in group.values) {
        if (g is! Map) continue;
        final enc = g['encoding'];
        if (enc is! String || enc.isEmpty) continue;
        final params = g['params'];
        final ie = params is Map
            ? (params['information_extracted'] as num?)?.toDouble()
            : null;
        out.add((modelKey: modelKey, infoExtracted: ie, encoding: enc));
      }
    }
    return out;
  }
}

/// 解析 .naiv4vibe(单条)或 .naiv4vibebundle(多条),按 identifier 自动分流。
/// 格式不对抛 [FormatException]。
List<ParsedVibe> parseVibeFileText(String text) {
  final Object? j;
  try {
    j = jsonDecode(text);
  } catch (_) {
    throw const FormatException('不是有效的 JSON 文件');
  }
  return parseVibeJson(j);
}

/// 同 [parseVibeFileText],但吃已解析好的 JSON —— 整包可能上百 MB(图是
/// base64),流式读文件时用这个,免得整份文本再在内存里存一份。
List<ParsedVibe> parseVibeJson(Object? j) {
  if (j is! Map<String, dynamic>) throw const FormatException('不是有效的 vibe 文件');
  switch (j['identifier']) {
    case 'novelai-vibe-transfer':
      return [ParsedVibe(j)];
    case 'novelai-vibe-transfer-bundle':
      final vibes = j['vibes'];
      if (vibes is! List) return const [];
      return [
        for (final v in vibes)
          if (v is Map<String, dynamic> &&
              v['identifier'] == 'novelai-vibe-transfer')
            ParsedVibe(v),
      ];
    default:
      throw const FormatException('无效的 vibe 文件格式');
  }
}

/// 新建「图片 vibe」的文件 JSON(encodings 为空,编码始终另存内容寻址缓存,
/// 导出时再合并回文件)。
Map<String, dynamic> newImageVibeRaw({
  required String imageBase64,
  required String name,
  required String thumbnailDataUrl,
  required int createdAtMs,
}) => {
  'identifier': 'novelai-vibe-transfer',
  'version': 1,
  'type': 'image',
  'image': imageBase64,
  'id': naiVibeIdOfBase64(imageBase64),
  'encodings': <String, dynamic>{},
  'name': name,
  'thumbnail': thumbnailDataUrl,
  'createdAt': createdAtMs,
};

/// 把一条编码合并进 raw 的 encodings(导出/回写用)。就地修改。
void mergeEncodingIntoRaw(
  Map<String, dynamic> raw, {
  required String modelKey,
  required double infoExtracted,
  required String encoding,
}) {
  final encs = raw['encodings'] is Map
      ? (raw['encodings'] as Map).cast<String, dynamic>()
      : <String, dynamic>{};
  final group = encs[modelKey] is Map
      ? (encs[modelKey] as Map).cast<String, dynamic>()
      : <String, dynamic>{};
  group[vibeEncodingHashKey(infoExtracted)] = {
    'encoding': encoding,
    'params': {'information_extracted': canonicalNumber(infoExtracted)},
  };
  encs[modelKey] = group;
  raw['encodings'] = encs;
}

/// Repair known numeric/hash fields at the export boundary, preserving encoded
/// bytes and unknown metadata. Imported files may contain hashes of "1.00";
/// the website looks up the hash of "1" after JSON has parsed that number.
Map<String, dynamic> canonicalVibeExport(Map<String, dynamic> raw) {
  final result = Map<String, dynamic>.of(raw);
  if (raw['importInfo'] case final Map info) {
    final normalized = Map<String, dynamic>.from(info);
    for (final key in ['strength', 'information_extracted']) {
      if (normalized[key] case final num value) {
        normalized[key] = canonicalNumber(value);
      }
    }
    result['importInfo'] = normalized;
  }
  if (raw['encodings'] case final Map encodings) {
    final output = <String, dynamic>{};
    for (final model in encodings.entries) {
      if (model.key is! String) continue;
      if (model.value is! Map) {
        output[model.key as String] = model.value;
        continue;
      }
      final group = <String, dynamic>{};
      for (final item in (model.value as Map).entries) {
        final key = item.key;
        final value = item.value;
        if (key is! String) continue;
        if (value is Map &&
            value['params'] is Map &&
            (value['params'] as Map)['information_extracted'] is num) {
          final params = Map<String, dynamic>.from(value['params'] as Map);
          final ie = (params['information_extracted'] as num).toDouble();
          params['information_extracted'] = canonicalNumber(ie);
          final canonicalKey = vibeEncodingHashKey(ie);
          // Prefer an already canonical record over a legacy duplicate.
          if (!group.containsKey(canonicalKey) || key == canonicalKey) {
            group[canonicalKey] = {...value, 'params': params};
          }
        } else {
          group[key] = value; // No reliable IE: preserve, never guess.
        }
      }
      output[model.key as String] = group;
    }
    result['encodings'] = output;
  }
  return result;
}

String buildVibeText(Map<String, dynamic> raw) =>
    jsonEncode(canonicalVibeExport(raw));

/// 组装 .naiv4vibebundle 文本。
String buildBundleText(List<Map<String, dynamic>> vibeRaws) => jsonEncode({
  'identifier': 'novelai-vibe-transfer-bundle',
  'version': 1,
  'vibes': vibeRaws.map(canonicalVibeExport).toList(),
});
