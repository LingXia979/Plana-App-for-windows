/// 助手设置弹层。版式与编辑器设置同源([SettingSheet] / [SettingRow])——
/// 同一个 app 里两处设置长得不一样,用户会以为自己进错了地方。
///
/// 「自动」那几项都是把默认的手动改成自动,默认一律关着:这套流程的地基是
/// 「AI 碰创作页、花点数出图,两件事都得用户按一下」,打开哪一项都是用户明知
/// 自己在放权,不能替他决定。
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/desktop.dart';
import '../../../core/ui/setting_row.dart';
import '../../generate/widgets/common.dart' show dropFocusSoon, hintSnack;
import '../agent_model.dart' show assistantBotAuthorizedProvider;
import '../assistant_settings.dart';
import '../assistant_state.dart';
import '../preset_rules.dart';
import '../rules_page.dart';

Future<void> showAssistantSettings(BuildContext context) async {
  if (ProviderScope.containerOf(
    context,
    listen: false,
  ).read(desktopModeProvider)) {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭助手设置',
      barrierColor: Colors.black.withValues(alpha: .12),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) => const _DesktopSettingsPanel(),
      transitionBuilder: (_, animation, _, child) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(begin: const Offset(.08, 0), end: Offset.zero)
              .animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
          child: child,
        ),
      ),
    );
    dropFocusSoon();
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // 抓手和圆角由 SettingSheet 自己画(与编辑器设置同一套),
    // 所以这儿把系统那份关掉、底色让给它。
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .18),
    builder: (_) => const _SettingsSheet(),
  );
  dropFocusSoon();
}

class _DesktopSettingsPanel extends ConsumerWidget {
  const _DesktopSettingsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(assistantSettingsProvider).value;
    final n = ref.read(assistantSettingsProvider.notifier);
    final authorized = ref.watch(assistantBotAuthorizedProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget section(String title, List<Widget> rows) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Material(
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: .65),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: scheme.outlineVariant.withValues(alpha: .45),
                    ),
                  rows[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
    Widget page(List<Widget> children) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );

    return SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            key: const ValueKey('desktop-assistant-settings'),
            width: 440,
            height: 620,
            child: Theme(
              data: theme.copyWith(
                textTheme: theme.textTheme.copyWith(
                  bodyLarge: theme.textTheme.bodyLarge?.copyWith(fontSize: 13),
                  labelLarge: theme.textTheme.labelLarge?.copyWith(
                    fontSize: 12,
                  ),
                  labelSmall: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Material(
                color: scheme.surface,
                elevation: 10,
                shadowColor: Colors.black26,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: DefaultTabController(
                  length: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(9),
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.tune,
                                color: scheme.onPrimaryContainer,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '助手设置',
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  SizedBox(height: 3),
                                  Text(
                                    '调整对话与创作习惯',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '关闭助手设置',
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close, size: 20),
                            ),
                          ],
                        ),
                      ),
                      const TabBar(
                        labelStyle: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        tabs: [
                          Tab(text: '对话'),
                          Tab(text: '生成'),
                          Tab(text: '资料与规则'),
                        ],
                      ),
                      Expanded(
                        child: s == null
                            ? const Center(child: CircularProgressIndicator())
                            : TabBarView(
                                children: [
                                  page([
                                    section('阅读与回复', [
                                      SettingStepperRow(
                                        icon: Icons.format_size,
                                        title: '消息字号',
                                        desc: '对话消息的文字大小',
                                        value: s.fontSize,
                                        min: AssistantSettings.fontSizeMin,
                                        max: AssistantSettings.fontSizeMax,
                                        step: AssistantSettings.fontSizeStep,
                                        format: (v) => v.toStringAsFixed(0),
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(fontSize: v),
                                        ),
                                      ),
                                      SettingRow(
                                        icon: Icons.keyboard_outlined,
                                        title: '流式输出',
                                        desc: '逐字显示回复',
                                        value: s.stream,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(stream: v),
                                        ),
                                      ),
                                      SettingRow(
                                        icon: Icons.image_outlined,
                                        title: '在对话内显示图片',
                                        desc: '生成图片仍会保存至图库',
                                        value: s.inlineImage,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(inlineImage: v),
                                        ),
                                      ),
                                    ]),
                                    section('对话记忆', [
                                      SettingStepperRow(
                                        icon: Icons.history,
                                        title: '上下文轮数',
                                        desc: '每次发送带上最近几轮对话',
                                        value: s.historyTurns.toDouble(),
                                        min: AssistantSettings.historyTurnsMin
                                            .toDouble(),
                                        max: AssistantSettings.historyTurnsMax
                                            .toDouble(),
                                        step: 1,
                                        format: (v) => v.toStringAsFixed(0),
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(
                                            historyTurns: v.round(),
                                          ),
                                        ),
                                      ),
                                    ]),
                                  ]),
                                  page([
                                    section('提示词结果', [
                                      SettingRow(
                                        icon: Icons.notes,
                                        title: '纯文本格式',
                                        desc: '提示词只显示为文本，不导入也不出图',
                                        value: s.noDraw,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(noDraw: v),
                                        ),
                                      ),
                                    ]),
                                    section('自动操作', [
                                      SettingRow(
                                        icon: Icons.draw_outlined,
                                        title: '自动写入创作页',
                                        desc: '生成的提示词自动写回创作页',
                                        enabled: !s.noDraw,
                                        value: s.autoImport,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(autoImport: v),
                                        ),
                                      ),
                                      SettingRow(
                                        icon: Icons.bolt_outlined,
                                        title: '生成提示词后自动出图',
                                        desc: '提示词完成后立即生成图片',
                                        enabled: !s.noDraw,
                                        value: s.autoGenerate,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(autoGenerate: v),
                                        ),
                                      ),
                                    ]),
                                    if (s.noDraw)
                                      Text(
                                        '纯文本格式已开启，自动写入与自动出图暂不生效。',
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.6,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                  ]),
                                  page([
                                    section('参考资料', [
                                      Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              '资料库范围',
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              '查询画师串与角色时使用的资料来源',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                            const SizedBox(height: 12),
                                            DropdownButtonFormField<
                                              LibraryScope
                                            >(
                                              key: ValueKey(
                                                'assistant-library-${s.libraryScope}-$authorized',
                                              ),
                                              initialValue:
                                                  effectiveLibraryScope(
                                                    s.libraryScope,
                                                    botAuthorized: authorized,
                                                  ),
                                              isExpanded: true,
                                              style: theme.textTheme.bodyMedium!
                                                  .copyWith(
                                                    fontSize: 13,
                                                    color: scheme.onSurface,
                                                  ),
                                              decoration: const InputDecoration(
                                                isDense: true,
                                                border: OutlineInputBorder(),
                                              ),
                                              items: [
                                                for (final scope
                                                    in LibraryScope.values)
                                                  DropdownMenuItem(
                                                    value: scope,
                                                    enabled:
                                                        libraryScopeAllowed(
                                                          scope,
                                                          botAuthorized:
                                                              authorized,
                                                        ),
                                                    child: Text(
                                                      '${libraryScopeLabel(scope)}${libraryScopeAllowed(scope, botAuthorized: authorized) ? '' : '（需要 Bot 授权）'}',
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                              ],
                                              onChanged: (v) {
                                                if (v != null) {
                                                  n.patch(
                                                    (o) => o.copyWith(
                                                      libraryScope: v,
                                                    ),
                                                  );
                                                }
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    ]),
                                    section('创作规则', [
                                      SettingNavRow(
                                        icon: Icons.rule_outlined,
                                        title: '规则预设',
                                        desc: '生成提示词时遵循的规则',
                                        value: _rulesValue(ref),
                                        onTap: () => Navigator.of(context).push(
                                          MaterialPageRoute<void>(
                                            builder: (_) =>
                                                const RulesPresetPage(),
                                          ),
                                        ),
                                      ),
                                    ]),
                                    section('记录', [
                                      SettingNavRow(
                                        icon: Icons.file_download_outlined,
                                        title: '导出对话记录',
                                        desc: '保存当前对话的请求与回复',
                                        value: '',
                                        onTap: () => _exportTrace(context, ref),
                                      ),
                                    ]),
                                  ]),
                                ],
                              ),
                      ),
                      Divider(
                        height: 1,
                        color: scheme.outlineVariant.withValues(alpha: .5),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          '修改后自动保存',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsSheet extends ConsumerWidget {
  const _SettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(assistantSettingsProvider).value;
    final n = ref.read(assistantSettingsProvider.notifier);
    final authorized = ref.watch(assistantBotAuthorizedProvider);
    return SettingSheet(
      title: '助手设置',
      children: [
        if (s == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          settingSection(context, '显示'),
          SettingStepperRow(
            icon: Icons.format_size,
            title: '消息字号',
            desc: '对话消息的文字显示大小',
            value: s.fontSize,
            min: AssistantSettings.fontSizeMin,
            max: AssistantSettings.fontSizeMax,
            step: AssistantSettings.fontSizeStep,
            format: (v) => v.toStringAsFixed(0),
            onChanged: (v) => n.patch((o) => o.copyWith(fontSize: v)),
          ),
          SettingRow(
            icon: Icons.keyboard_outlined,
            title: '流式输出',
            desc: '逐字显示回复',
            value: s.stream,
            onChanged: (v) => n.patch((o) => o.copyWith(stream: v)),
          ),
          settingSection(context, '出图'),
          SettingRow(
            icon: Icons.notes,
            title: '纯文本格式',
            desc: '提示词只显示为文本,不导入也不出图',
            value: s.noDraw,
            onChanged: (v) => n.patch((o) => o.copyWith(noDraw: v)),
          ),
          settingSection(context, '自动'),
          // 纯文本格式开着时这两项不会发生,淡显
          SettingRow(
            icon: Icons.bolt_outlined,
            title: '生成提示词后自动出图',
            desc: '提示词生成完成后立即开始出图',
            enabled: !s.noDraw,
            value: s.autoGenerate,
            onChanged: (v) => n.patch((o) => o.copyWith(autoGenerate: v)),
          ),
          SettingRow(
            icon: Icons.image_outlined,
            title: '在对话内显示图片',
            desc: '生成的图片显示在对话内,同时保存至图库',
            value: s.inlineImage,
            onChanged: (v) => n.patch((o) => o.copyWith(inlineImage: v)),
          ),
          SettingRow(
            icon: Icons.draw_outlined,
            title: '自动写入创作页',
            desc: '生成的提示词自动写回创作页,无需手动导入',
            enabled: !s.noDraw,
            value: s.autoImport,
            onChanged: (v) => n.patch((o) => o.copyWith(autoImport: v)),
          ),
          settingSection(context, '对话'),
          SettingStepperRow(
            icon: Icons.history,
            title: '上下文轮数',
            desc: '每次发送带上最近几轮对话',
            value: s.historyTurns.toDouble(),
            min: AssistantSettings.historyTurnsMin.toDouble(),
            max: AssistantSettings.historyTurnsMax.toDouble(),
            step: 1,
            format: (v) => v.toStringAsFixed(0),
            onChanged: (v) =>
                n.patch((o) => o.copyWith(historyTurns: v.round())),
          ),
          settingSection(context, '资料'),
          SettingChoiceRow<LibraryScope>(
            icon: Icons.library_books_outlined,
            title: '资料库范围',
            desc: '查询画师串与角色时使用的资料来源',
            value: effectiveLibraryScope(
              s.libraryScope,
              botAuthorized: authorized,
            ),
            options: LibraryScope.values,
            labelOf: libraryScopeLabel,
            optionEnabled: (o) =>
                libraryScopeAllowed(o, botAuthorized: authorized),
            optionNote: (o) => libraryScopeAllowed(o, botAuthorized: authorized)
                ? libraryScopeDesc(o)
                : '需要 Bot 授权',
            onChanged: (v) => n.patch((o) => o.copyWith(libraryScope: v)),
          ),
          settingSection(context, '规则'),
          SettingNavRow(
            icon: Icons.rule_outlined,
            title: '规则预设',
            desc: '生成提示词时遵循的规则',
            value: _rulesValue(ref),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RulesPresetPage()),
            ),
          ),
          settingSection(context, '调试'),
          SettingNavRow(
            icon: Icons.bug_report_outlined,
            title: '导出对话记录',
            desc: '当前对话每一轮发给 AI 的内容和返回',
            value: switch (ref.read(assistantProvider.notifier).traceCount) {
              0 => '',
              final n => '$n 轮',
            },
            onTap: () => _exportTrace(context, ref),
          ),
        ],
      ],
    );
  }
}

/// 导出成一个文本文件,存到用户选的位置。内容见 `renderTraceExport`。
Future<void> _exportTrace(BuildContext context, WidgetRef ref) async {
  if (ref.read(assistantProvider).msgs.isEmpty) {
    hintSnack(context, '当前对话是空的', icon: Icons.info_outline);
    return;
  }
  try {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final path = await FilePicker.platform.saveFile(
      fileName: 'plana-assistant-$stamp.txt',
      bytes: utf8.encode(ref.read(assistantProvider.notifier).exportTrace()),
    );
    if (path != null && context.mounted) {
      hintSnack(context, '已导出对话记录', icon: Icons.check_circle_outline);
    }
  } catch (e) {
    if (context.mounted) {
      hintSnack(context, '导出失败:$e', icon: Icons.error_outline);
    }
  }
}

/// 规则那一行右边的状态:两个模型都用默认规则就是「默认」;都用同一份导入的预设
/// 就报它的名字;两边各用各的只说「自定义」,名字留给点进去的那一页。
String _rulesValue(WidgetRef ref) {
  final lib = ref.watch(rulesLibraryProvider).value;
  if (lib == null) return '';
  final used = [for (final f in RulesFamily.values) lib.activeFor(f)];
  if (used.every((p) => p.isDefault)) return '默认';
  if (used.every((p) => p.id == used.first.id)) return used.first.name;
  return '自定义';
}
