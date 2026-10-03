import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../generate_state.dart';
import '../models.dart';
import 'common.dart';
import 'section_card.dart';

/// 重绘放大卡(anima 专属模块,对齐 web 桌面端 hires 模块):
/// 一段小图定构图 → 放大到目标尺寸 → 低 denoise 二段采样补细节。
/// 卡头电源键开关整块功能,关着也能改参数(配置常驻,不随开关蒸发)。
class HiresCard extends ConsumerWidget {
  const HiresCard({super.key, this.reorderIndex});

  final int? reorderIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(generateProvider.select((s) => s.params));
    final expanded = ref.watch(
      generateProvider.select((s) => s.openPanels.contains(Panel.hires)),
    );
    final notifier = ref.read(generateProvider.notifier);
    final h = p.hires;
    final (tw, th) = h.targetSize(p.width, p.height);

    return SectionCard(
      icon: Icons.bolt_outlined,
      title: '重绘放大',
      reorderIndex: reorderIndex,
      // 开着才报目标尺寸:收起状态下这一行就是「这次会出多大」的答案
      inline: [
        if (h.enabled)
          Text(
            '$tw×$th',
            style: mono(context, size: 12, color: context.scheme.primary),
          ),
      ],
      actions: [
        RefEnableToggle(
          enabled: h.enabled,
          onTooltip: '停用重绘放大',
          offTooltip: '启用重绘放大',
          onTap: () => notifier.updateHires(enabled: !h.enabled),
        ),
      ],
      expanded: expanded,
      onHeaderTap: () => notifier.togglePanel(Panel.hires),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LiveParamSlider(
            label: '放大倍率 Scale',
            help: Help.hiresScale,
            value: h.scale,
            min: 1.1,
            max: 2.0,
            divisions: 18, // step 0.05(对齐 web)
            valueTextOf: (v) => '${v.toStringAsFixed(2)}×',
            onCommit: (v) => notifier.updateHires(scale: v),
          ),
          const SizedBox(height: 10),
          _Field(
            label: '放大方式',
            help: Help.hiresUpscaler,
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('先超分后重绘')),
                ButtonSegment(value: false, label: Text('直接重绘')),
              ],
              selected: {h.useModel},
              onSelectionChanged: (s) =>
                  notifier.updateHires(useModel: s.first),
              showSelectedIcon: false,
              style: _segStyle,
            ),
          ),
          // 直接重绘走 lanczos 插值,没有超分模型可选,整块收走
          ExpandBody(
            expanded: h.useModel,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _Field(
                label: '超分模型',
                help: Help.hiresModel,
                child: SegmentedButton<HiresUpscaler>(
                  segments: [
                    for (final u in HiresUpscaler.values)
                      ButtonSegment(value: u, label: Text(u.label)),
                  ],
                  selected: {h.model},
                  onSelectionChanged: (s) =>
                      notifier.updateHires(model: s.first),
                  showSelectedIcon: false,
                  style: _segStyle,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          LiveParamSlider(
            label: '重绘强度 Denoise',
            help: Help.hiresDenoise,
            value: h.denoise,
            min: 0.2,
            max: 0.75,
            divisions: 11, // step 0.05(对齐 web)
            onCommit: (v) => notifier.updateHires(denoise: v),
          ),
          const SizedBox(height: 6),
          LiveParamSlider(
            label: '二段步数 Hires Steps',
            snapInputToDivisions: true,
            help: Help.hiresSteps,
            value: h.steps.toDouble(),
            max: kHiresStepsMax.toDouble(),
            divisions: kHiresStepsMax,
            // 0 = 跟随主步数;1~3 服务端会抬到 4,updateHires 已就地钳住
            valueTextOf: (v) => v.round() == 0
                ? '跟随主步数'
                : '${v.round().clamp(kHiresStepsMin, kHiresStepsMax)}',
            onCommit: (v) => notifier.updateHires(steps: v.round()),
          ),
        ],
      ),
    );
  }
}

/// 分段选择器:占满卡宽后每段均分,再把字号收到 12、内边距压到最小,
/// 「先超分后重绘」和三个超分模型名才不会被挤断。
const _segStyle = ButtonStyle(
  textStyle: WidgetStatePropertyAll(
    TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
  ),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
  // 只横向压紧;竖向留到 36dp,整条占满卡宽后太薄不好按
  visualDensity: VisualDensity(horizontal: -3, vertical: -1),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// 「标签(带说明)一行 + 控件占满下一行」,与滑杆的标签行/滑杆行同一节奏。
/// 不做成左标签右控件:三选的英文名一挤就断行。
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.help, required this.child});

  final String label;
  final ParamHelp help;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        HelpLabel(
          text: label,
          help: help,
          style: context.texts.bodySmall!.copyWith(
            color: context.scheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}
