import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'prompt_presets.dart';

/// Native prompt_presets.json, a JSON list, or a single custom preset.
/// Validate the complete file before changing the existing library.
List<PromptPreset> parsePresetFile(String text) {
  final decoded = jsonDecode(text.replaceFirst(RegExp(r'^\uFEFF'), ''));
  final Object? entries = decoded is Map
      ? decoded['custom'] ?? decoded['presets'] ?? [decoded]
      : decoded;
  if (entries is! List || entries.isEmpty) {
    throw const FormatException('文件中没有提示词预设');
  }
  final result = <String, PromptPreset>{};
  for (final entry in entries) {
    if (entry is! Map<String, dynamic> ||
        (!entry.containsKey('positive') && !entry.containsKey('negative'))) {
      throw const FormatException('预设需要 positive 或 negative 提示词字段');
    }
    for (final key in [
      'id',
      'name',
      'positive',
      'negative',
      'scope',
      'positivePlacement',
    ]) {
      if (entry[key] != null && entry[key] is! String) {
        throw FormatException('预设的 $key 字段必须是文本');
      }
    }
    if (entry['createdAt'] != null && entry['createdAt'] is! int) {
      throw const FormatException('预设创建时间格式不正确');
    }
    if (entry['scope'] != null &&
        entry['scope'] != 'v5' &&
        entry['scope'] != 'legacy') {
      throw const FormatException('预设适用模型应为 v5、legacy 或 null');
    }
    if (entry['positivePlacement'] != null &&
        entry['positivePlacement'] != 'prefix' &&
        entry['positivePlacement'] != 'suffix') {
      throw const FormatException('预设拼接位置应为 prefix 或 suffix');
    }
    if (entry['isDefault'] != null && entry['isDefault'] is! bool) {
      throw const FormatException('预设的 isDefault 字段必须是布尔值');
    }
    final id = (entry['id'] as String? ?? '').trim();
    if (entry['isDefault'] == true ||
        kDefaultPromptPresets.any((preset) => preset.id == id)) {
      continue;
    }
    final positive = entry['positive'] as String? ?? '';
    final negative = entry['negative'] as String? ?? '';
    final name = (entry['name'] as String? ?? '').trim();
    final normalized = <String, dynamic>{
      ...entry,
      'id': id,
      'name': name.isEmpty ? '导入的预设' : name,
      'positive': positive,
      'negative': negative,
    };
    if (id.isEmpty) {
      final digest = sha256.convert(
        utf8.encode(
          jsonEncode([
            normalized['name'],
            positive,
            negative,
            entry['scope'],
            entry['positivePlacement'] ?? 'prefix',
          ]),
        ),
      );
      normalized['id'] = 'import_${digest.toString()}';
    }
    final preset = PromptPreset.fromJson(normalized);
    result[preset.id] = preset;
  }
  return result.values.toList();
}
