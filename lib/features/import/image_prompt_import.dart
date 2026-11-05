import '../generate/canvas_models.dart';
import '../generate/models.dart';
import '../generate/prompt_sections.dart' show withMainRow;

/// 图片元数据和反推结果共用；与助手的去重导入独立。
enum ImagePromptImportMode {
  replaceAll('完全覆盖', '清空全部分区，将勾选的提示词写入主体。'),
  addSection('额外添加', '保留主体和已有分区，新建「图片导入1、2……」分区。'),
  replaceMain('替换主体', '只替换主体中勾选的提示词，保留全部分区。');

  const ImagePromptImportMode(this.label, this.description);
  final String label;
  final String description;
}

/// null 表示未勾选该侧。完整保留图片里的词，不按已有分区去重。
/// 「完全覆盖」明确删除全部分区，但不改未勾选的主体提示词。
CanvasPrompts importImagePromptsInto(
  CanvasPrompts current,
  ImagePromptImportMode mode, {
  String? positive,
  String? negative,
  required String Function() newId,
}) {
  if (positive == null && negative == null) return current;
  if (mode == ImagePromptImportMode.addSection) {
    if ((positive ?? '').trim().isEmpty && (negative ?? '').trim().isEmpty) {
      return current;
    }
    var next = 1;
    final pattern = RegExp(r'^图片导入\s*(\d+)$');
    for (final section in current.sections) {
      final match = pattern.firstMatch(section.name.trim());
      final number = match == null ? null : int.tryParse(match[1]!);
      if (number != null && number >= next) next = number + 1;
    }
    final rows = current.sections.isEmpty
        ? const [PromptSection.main()]
        : withMainRow(current.sections, current.prompt);
    return current.copyWith(
      sections: [
        ...rows,
        PromptSection(
          id: newId(),
          name: '图片导入$next',
          positive: positive ?? '',
          negative: negative ?? '',
        ),
      ],
    );
  }
  return current.copyWith(
    prompt: positive,
    promptRaw: positive == null ? null : '',
    negativePrompt: negative,
    negativePromptRaw: negative == null ? null : '',
    sections: mode == ImagePromptImportMode.replaceAll
        ? const []
        : positive != null && positive.trim().isNotEmpty
        ? [
            for (final section in current.sections)
              if (section.isMain && !section.enabled)
                section.copyWith(enabled: true)
              else
                section,
          ]
        : current.sections,
  );
}
