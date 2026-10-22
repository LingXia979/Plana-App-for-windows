import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../editor/editor_models.dart' show outputOf;
import '../../inspiration/public_tags.dart';
import '../../inspiration/tag_editor_page.dart';
import '../../inspiration/tag_library.dart';
import '../../inspiration/tag_models.dart';
import '../../inspiration/widgets/char_pick_sheet.dart' show kPanelTagCats;
import '../generate_state.dart';
import '../models.dart' show PromptSection;
import 'common.dart';

/// 这一格存进灵感库的词:实际出图的那份(停用的不算、折叠展开)。主体只存正向,
/// 卡上负面那行是整张卡的。
({String positive, String negative}) sectionSaveText(
  PromptSection s,
  String mainPrompt,
) => s.isMain
    ? (positive: mainPrompt.trim(), negative: '')
    : (positive: s.positive.trim(), negative: s.negative.trim());

/// 存进灵感库时默认落的分类:画风格是画风;名字就叫「画风」「角色」「场景」的
/// 落那一类;别的不猜。
TagCategory? sectionSaveCategory(PromptSection s) {
  if (s.artist) return TagCategory.artist;
  final name = s.name.trim();
  for (final c in kPanelTagCats) {
    if (tagCategoryDef(c).label == name) return c;
  }
  return null;
}

/// 自己起的分区名,存进灵感库时直接当条目名。主体、「分区 N」、分类名、
/// 「法典」这类默认名不算。
String? customSectionName(PromptSection s) {
  final name = s.name.trim();
  if (name.isEmpty ||
      name == '主体' ||
      name == '法典' ||
      RegExp(r'^分区 \d+$').hasMatch(name) ||
      kTagCategoryDefs.any((d) => d.label == name)) {
    return null;
  }
  return name;
}

/// 库里同分类已有同样词的那条(逗号两边的空白不算)。
TagEntry? sameLibraryEntry(
  Iterable<TagEntry> entries,
  TagCategory category,
  String positive,
  String negative,
) {
  String norm(String s) => outputOf(s)
      .split(RegExp(r'[,，]'))
      .map((x) => x.trim())
      .where((x) => x.isNotEmpty)
      .join(',');
  final p = norm(positive), n = norm(negative);
  for (final e in entries) {
    if (e.category == category &&
        norm(e.positive) == p &&
        norm(e.negative) == n) {
      return e;
    }
  }
  return null;
}

/// 多选栏「存到灵感库」:这一格进灵感页的新建页,词、分类、画风编号都填好,
/// 封面、标签在那页补,存不存也由那页定。分类猜不出来时先从 [anchor](那颗钮)
/// 底下弹分类下拉。同分类里已有一样的词就不新建,提示是哪一条。
/// 进了新建页(或碰到已有的)返回 true,调用方据此退出多选。
Future<bool> saveSectionToLibrary(
  BuildContext anchor,
  WidgetRef ref,
  PromptSection section,
) async {
  final text = sectionSaveText(section, ref.read(generateProvider).prompt);
  if (text.positive.isEmpty) return false;
  final cat = sectionSaveCategory(section) ?? await _pickCategory(anchor);
  if (cat == null || !anchor.mounted) return false;
  final lib = await ref.read(tagLibraryProvider.future);
  if (!anchor.mounted) return false;
  // 调用方随后退出多选,这颗钮就没了:导航先拿在手里
  final nav = Navigator.of(anchor);
  final editorContext = nav.context;
  if (!editorContext.mounted) return false;
  if (sameLibraryEntry(lib.entries, cat, text.positive, text.negative)
      case final e?) {
    hintSnack(
      anchor,
      '灵感库里已有「${e.name}」',
      actionLabel: '编辑',
      onAction: () => editorContext.mounted
          ? showTagEditor(editorContext, cat: e.category, edit: e)
          : null,
    );
    return true;
  }
  // 画风编号避开本地和公共库里的名字(公共库没拉到就只看本地,同新建页的「编号」)
  final code = cat == TagCategory.artist
      ? suggestArtistCode({
          for (final e in lib.of(TagCategory.artist)) e.name,
          for (final e
              in ref.read(publicTagsProvider(TagCategory.artist)).value ??
                  const <TagEntry>[])
            e.name,
        })
      : null;
  unawaited(
    showTagEditor(
      editorContext,
      cat: cat,
      draft: (
        name: customSectionName(section) ?? code ?? '',
        positive: text.positive,
        negative: text.negative,
      ),
    ),
  );
  return true;
}

/// 分类下拉,样式同灵感页切分类那个,从 [anchor] 底下弹出来。
Future<TagCategory?> _pickCategory(BuildContext anchor) {
  final scheme = anchor.scheme;
  final box = anchor.findRenderObject()! as RenderBox;
  final overlay =
      Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
  // 同 PopupMenuButton 的 offset:往下挪一个钮高再空 6,菜单落在钮下面
  final down = Offset(0, box.size.height + 6);
  return showMenu<TagCategory>(
    context: anchor,
    position: RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(down, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(down), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    items: [
      for (final c in kPanelTagCats)
        PopupMenuItem(
          value: c,
          child: Row(
            children: [
              Icon(
                tagCategoryDef(c).icon,
                size: 19,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Text(
                tagCategoryDef(c).label,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
    ],
  );
}
