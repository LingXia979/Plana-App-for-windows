import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/scroll_memory.dart';
import 'gen_modules.dart';
import 'generate_state.dart';
import 'widgets/anima_nl_card.dart';
import 'widgets/bottom_action_bar.dart';
import 'widgets/char_ref_card.dart';
import 'widgets/character_card.dart';
import 'widgets/hires_card.dart';
import 'widgets/img2img_card.dart';
import 'widgets/krea_prompt_card.dart';
import 'widgets/krea_style_ref_card.dart';
import 'widgets/lora_card.dart';
import 'widgets/prompt_card.dart';
import 'widgets/top_bar.dart';
import 'widgets/vibe_card.dart';

/// 创作页:顶栏 + 提示词卡 + 功能模块卡(按模块配置显隐,卡头长按拖拽调序)
/// + 吸底操作栏
class GeneratePage extends ConsumerWidget {
  const GeneratePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mods =
        ref.watch(genModulesProvider).value ?? const GenModuleSettings();
    // 可见集随模型走:切到不支持某模块的型号(如 4.0 之于角色参考)整卡自动收走
    final model = ref.watch(generateProvider.select((s) => s.params.model));
    final visible = mods.visibleFor(model);
    return Column(
      children: [
        const GenerateTopBar(),
        Expanded(
          child: Stack(
            children: [
              ScrollMemo(
                memoKey: 'generate',
                builder: (context, scrollCtrl) => CustomScrollView(
                  controller: scrollCtrl,
                  slivers: [
                    const SliverPadding(
                      padding: EdgeInsets.fromLTRB(14, 4, 14, 0),
                      sliver: SliverToBoxAdapter(child: PromptCard()),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                      sliver: SliverReorderableList(
                        itemCount: visible.length,
                        onReorderItem: (from, to) =>
                            _moveVisible(ref, model, from, to),
                        proxyDecorator: (child, index, animation) => Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          elevation: 3,
                          child: child,
                        ),
                        // 稳定 key 在 item 根上:调序/开关不丢卡片内部状态
                        itemBuilder: (context, i) => Padding(
                          key: ValueKey('mod-${visible[i].name}'),
                          padding: const EdgeInsets.only(top: 9),
                          child: buildGenerateModuleCard(visible[i], i),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 步数 / CFG / 张数的浮动控件浮在列表上方(紧贴吸底栏):
              // 不占布局,开合不推动任何东西。三者**共用这一处**,
              // 谁开着由 floatingPillProvider 说了算,不会叠在一起。
              const Positioned(
                left: 14,
                right: 14,
                bottom: 10,
                child: FloatingPillOverlay(),
              ),
            ],
          ),
        ),
        const BottomActionBar(),
      ],
    );
  }

  /// 可见序列内的拖拽调序映射回所属父类组的完整 order:不可见模块原槽位不动。
  void _moveVisible(WidgetRef ref, String model, int from, int to) {
    ref.read(genModulesProvider.notifier).patch((x) {
      final p = providerOfModel(model);
      final moved = x.visibleFor(model);
      if (from < 0 || from >= moved.length || to < 0 || to >= moved.length) {
        return x;
      }
      moved.insert(to, moved.removeAt(from));
      var j = 0;
      final full = [
        for (final m in x.orderOf(p)) x.isVisibleFor(m, model) ? moved[j++] : m,
      ];
      return x.copyWith(order: {...x.order, p: full});
    });
  }
}

Widget buildGenerateModuleCard(GenModule m, int? index) => switch (m) {
  GenModule.character => CharacterCard(reorderIndex: index),
  GenModule.vibe => VibeCard(reorderIndex: index),
  GenModule.charRef => CharRefCard(reorderIndex: index),
  GenModule.img2img => Img2ImgCard(reorderIndex: index),
  // anima 与 krea 的 LoRA 是两个模块 key(启用位各存各的),但卡片是同一张 ——
  // 挂载语义完全一致,差别只在库和载荷去处。
  GenModule.lora || GenModule.kreaLora => LoraCard(reorderIndex: index),
  GenModule.hires => HiresCard(reorderIndex: index),
  GenModule.animaNl => AnimaNlCard(reorderIndex: index),
  GenModule.kreaStyleRef => KreaStyleRefCard(reorderIndex: index),
  GenModule.kreaPrompt => KreaPromptCard(reorderIndex: index),
};
