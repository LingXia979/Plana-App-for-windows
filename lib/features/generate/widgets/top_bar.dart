import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_mode.dart';
import '../../../core/auth/bot_session_store.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/platform/desktop.dart';
import '../../../core/util/haptics.dart';
import '../generate_state.dart';
import '../gpu_rental.dart';
import '../models.dart' as m;
import 'anlas_panel.dart';
import 'common.dart' show hintSnack;
import 'rental_panel.dart';

/// 顶栏:模型选择胶囊(左)+ 余额 / 额度胶囊(右)
class GenerateTopBar extends ConsumerWidget {
  const GenerateTopBar({super.key});

  Future<void> _pickModel(BuildContext context, WidgetRef ref) async {
    final current = ref.read(generateProvider).params.model;
    final picked = await showModalBottomSheet<String>(
      context: context,
      // 定高七成屏(与高级设置那张 .86 同一路数)。不按内容高:各类条目数不同,
      // 贴内容会让弹层随分类横滑抽动;而默认的 9/16 封顶在矮屏/大字号机型上
      // 又会从底部静默裁掉选项(实机反馈:部分机型最后一个模型被挡)。
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .7,
        // anima / krea 都走服务端 Modal 后端,仅 Bot 授权模式提供
        // (对齐 web isAnimaAvailable / isKreaAvailable:token 直连模式没有服务端会话)。
        //
        // watch 而不是 read:NAI 页右上角能就地切生成方式,切完这两页要当场
        // 进出。分组数变了就换 key 整块重建 —— TabController 的 length 定死在
        // 构造时,重建 State 比手工换控制器干净(新的照样停在当前型号那一类)。
        child: Consumer(
          builder: (context, ref, _) {
            final modalOk = ref.watch(authModeProvider).value == AuthMode.bot;
            return _ModelSheet(
              key: ValueKey(modalOk),
              current: current,
              groups: [
                m.GenProvider.nai,
                if (modalOk) ...[m.GenProvider.anima, m.GenProvider.krea],
              ],
              // NAI 5 已上线,直连线与 bot 线都可用:直连 buildNaiPayload 已支持
              // V5 载荷(v4_prompt + params_version 4),bot 线由后端构造 —— 两档常列。
              nai5: true,
            );
          },
        ),
      ),
    );
    if (picked != null) ref.read(generateProvider.notifier).setModel(picked);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(generateProvider);
    final rentalActive = ref.watch(gpuRentalProvider).active;
    final scheme = context.scheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      // 右边那枚胶囊撑到多宽由它自己说了算(NAI 5 时点数+额度两个数并排),
      // 所以让模型名这边先让步:spaceBetween 把右胶囊钉在右边,模型胶囊拿余量
      // 且只在真放不下时才打省略号 —— 换成 Spacer 会跟 Flexible 对半分余量。
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 模型选择
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ref.watch(desktopModeProvider)
                  ? const _DesktopModelDropdown()
                  : Material(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(19),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => _pickModel(context, ref),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 14, right: 8),
                          child: SizedBox(
                            height: 42,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: AnimatedSwitcher(
                                    duration: Motion.fast,
                                    child: Text(
                                      state.params.model,
                                      key: ValueKey(state.params.model),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: context.texts.bodyMedium!.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: scheme.onSurface,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 2),
                                Icon(
                                  Icons.expand_more,
                                  size: 20,
                                  color: scheme.outline,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          // 右侧那个位置给谁,看当前模型花的是哪种钱:
          //  - Anima / Krea 不扣 Anlas,余额摆在那儿是个永远不动的死数 ——
          //    换成算力来源(免费共享 / 独享实例,运行中直接报计时与费用);
          //  - NAI 但实例还活着:那台在烧 ¥4/时,比余额紧急,也让位;
          //  - 其余交给余额胶囊 —— 它自己再按模型分:NAI 5 花的是按时间回充的
          //    额度电池,报百分比;别的报 Anlas。
          // 单独取出来再判:写成 `isModal || rental.active` 会因为短路
          // 让 NAI 之外的路径**不订阅** gpuRentalProvider —— 那样冷启动时
          // 没人把它建起来,也就不会去问「我上次那台还在不在跑」。
          if (m.isModalModel(state.params.model) || rentalActive)
            const RentalSourceChip(height: 42)
          else
            // 余额 / NAI 5 额度(点开是「点数与额度」弹层)
            const AnlasChip(height: 42),
        ],
      ),
    );
  }
}

/// 模型选择弹层(定高七成屏):下划线 Tab + 可左右滑的分页,每页是该大类的型号列表。
///
/// 三类平铺成一张长表要滚两屏,选型时还得先认清自己看的是哪一段;分页之后
/// 每页只有 2-4 项,一眼到底,还能直接横滑翻类。
///
/// 只列**当前可用**的大类:Anima / Krea 走服务端 Modal 后端,token 直连模式
/// 没有服务端会话,列出来也点不动 —— 摆一排点不动的 tab 比不摆更让人费解。
/// 于是只剩一类时连 Tab 条一起收走(孤零零一个 tab 是纯噪声)。
class _ModelSheet extends StatefulWidget {
  const _ModelSheet({
    super.key,
    required this.current,
    required this.groups,
    this.nai5 = false,
  });

  final String current;
  final List<m.GenProvider> groups;

  /// NAI 组是否追加 NAI 5 两档(已上线,直连 + Bot 双线恒 true;留参数
  /// 是为下一个未上线模型的预载再用同一开关)。
  final bool nai5;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet>
    with SingleTickerProviderStateMixin {
  /// 进来就停在当前型号所属的那一类;那类当前不可用(如停在 Anima 却切回了
  /// token 模式)就落到第一类 —— 停在一个选不了的分组上没有意义。
  late final TabController _tab = TabController(
    length: widget.groups.length,
    // 进来就停在当前型号所属的那一类;那类当前不可用(如停在 Anima 却切回了
    // token 模式)就落到第一类 —— 停在一个选不了的分组上没有意义。
    initialIndex: widget.groups
        .indexOf(m.providerOfModel(widget.current))
        .clamp(0, widget.groups.length - 1),
    vsync: this,
  );

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
            child: SizedBox(
              // 定高:胶囊随分页进出,行高不能跟着变,否则切 tab 整个列表上下抽
              height: 34,
              child: Row(
                children: [
                  Text(
                    '模型',
                    style: context.texts.titleMedium!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  // 右上角这一格两枚胶囊轮值,跟着 tab 动画淡入淡出 ——
                  // 横滑到一半时它们也在半路上,不是「啪」地切换:
                  //  - Anima / Krea 页 → 算力来源(那两条线才有实例可言);
                  //  - NAI 页 → 生成方式速切(直连 Token / Bot 账户)。
                  AnimatedBuilder(
                    animation: _tab.animation!,
                    builder: (context, _) {
                      final i = _tab.animation!.value.round().clamp(
                        0,
                        widget.groups.length - 1,
                      );
                      final nai = widget.groups[i] == m.GenProvider.nai;
                      return Stack(
                        alignment: Alignment.centerRight,
                        children: [
                          _slot(show: !nai, child: const RentalSourceChip()),
                          _slot(show: nai, child: const _AuthModeChip()),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          // 下划线 Tab + 可左右滑的分页:不做成一排按钮,列表本身也跟着滑。
          if (widget.groups.length > 1)
            TabBar(
              controller: _tab,
              tabs: [
                for (final g in widget.groups)
                  Tab(height: 42, text: m.providerLabel(g)),
              ],
              labelColor: scheme.primary,
              unselectedLabelColor: scheme.onSurfaceVariant,
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: scheme.outlineVariant.withValues(alpha: .5),
            ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [for (final g in widget.groups) _modelList(g)],
            ),
          ),
        ],
      ),
    );
  }

  /// 轮值格里的一枚:淡出的那枚不吃点击。两枚都留在树里,格宽按较宽的那枚
  /// 定死,换页时标题行不会跟着变宽变窄。
  Widget _slot({required bool show, required Widget child}) => AnimatedOpacity(
    opacity: show ? 1 : 0,
    duration: Motion.fast,
    child: IgnorePointer(ignoring: !show, child: child),
  );

  Widget _modelList(m.GenProvider g) => ListView(
    padding: const EdgeInsets.only(top: 4, bottom: 8),
    children: [
      for (final model in m.modelsOf(g, nai5: widget.nai5)) _modelTile(model),
    ],
  );

  Widget _modelTile(String model) {
    final desc = m.modelDescriptions[model];
    return ListTile(
      onTap: () => Navigator.pop(context, model),
      title: Text(model, style: context.texts.bodyMedium),
      // 副标题恒单行:文案本身已按一行裁,但系统字号调大/窄屏仍会折行 ——
      // 折了这张表就一页两套行高,ellipsis 兜住。
      subtitle: desc == null
          ? null
          : Text(
              desc,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.bodySmall!.copyWith(
                color: context.scheme.onSurfaceVariant,
              ),
            ),
      trailing: model == widget.current
          ? Icon(Icons.check, size: 18, color: context.scheme.primary)
          : null,
      dense: true,
    );
  }
}

/// 生成方式速切(只在模型弹层的 NAI 页露面):直连 Token ↔ Bot 账户,点开选。
///
/// NAI 两条线都能出图,来回换是常事(直连那边额度见底、或想省 Anlas 走 Bot),
/// 原先只有「我的 → 账号与接入」一处切得动,挑模型挑到一半得整个退出去。
///
/// 下拉而不是点一下对切(与并排的 [RentalSourceChip]、统计页的数据源下拉同一
/// 套):两个去处摊开摆着,不用先按一下才知道另一边是什么。没授权 Bot 时那行
/// 压暗但照样点得动 —— 点它给的是「去哪授权」的指路,禁用了反倒只剩一条说不出
/// 所以然的灰杠。而「选了 Bot 却没授权」那种坏状态,回 Token 这行永远亮着。
class _AuthModeChip extends ConsumerWidget {
  const _AuthModeChip();

  /// 与并排轮值的 [RentalSourceChip] 同高。
  static const _height = 32.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final mode = ref.watch(authModeProvider).value ?? AuthMode.token;
    final bot = mode == AuthMode.bot;
    // 会话还在读盘时按「没有」办:只影响能不能换去 Bot,读完自己会重建
    final canSwitch = bot || ref.watch(botSessionProvider).value != null;
    final fg = scheme.onSurfaceVariant;

    PopupMenuItem<AuthMode> item(AuthMode v, IconData icon, String label) {
      final dim = v == AuthMode.bot && !canSwitch;
      return PopupMenuItem(
        value: v,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: dim ? scheme.outline : null),
          title: Text(
            label,
            style: dim ? TextStyle(color: scheme.outline) : null,
          ),
          trailing: v == mode
              ? Icon(Icons.check, size: 18, color: scheme.primary)
              : null,
        ),
      );
    }

    // Material 在外、菜单按钮在内:水波纹才会被裁成胶囊,而不是方角糊出来。
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(_height / 2),
      clipBehavior: Clip.antiAlias,
      child: PopupMenuButton<AuthMode>(
        tooltip: '生成方式',
        position: PopupMenuPosition.under,
        onSelected: (v) {
          if (v == mode) return;
          if (v == AuthMode.bot && !canSwitch) {
            hintSnack(
              context,
              '尚未授权 Bot,去「我的 → 账号与接入」授权后可切',
              icon: Icons.smart_toy_outlined,
            );
            return;
          }
          Haptics.selection();
          ref.read(authModeProvider.notifier).set(v);
        },
        itemBuilder: (_) => [
          item(AuthMode.token, Icons.vpn_key, '直连 Token'),
          item(AuthMode.bot, Icons.smart_toy_outlined, 'Bot 账户'),
        ],
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
          child: SizedBox(
            height: _height,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  bot ? Icons.smart_toy_outlined : Icons.vpn_key,
                  size: 15,
                  color: fg,
                ),
                const SizedBox(width: 6),
                Text(
                  bot ? 'Bot 账户' : '直连 Token',
                  style: context.texts.labelMedium!.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Icon(Icons.expand_more, size: 17, color: scheme.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopModelDropdown extends ConsumerWidget {
  const _DesktopModelDropdown();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = ref.watch(generateProvider.select((s) => s.params.model));
    final bot = ref.watch(authModeProvider).value == AuthMode.bot;
    return MenuAnchor(
      key: const ValueKey('desktop-model-dropdown'),
      style: MenuStyle(
        maximumSize: const WidgetStatePropertyAll(Size(360, 480)),
        minimumSize: const WidgetStatePropertyAll(Size(280, 0)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Text(
                '生成方式',
                style: context.texts.labelMedium!.copyWith(
                  color: context.scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              const _AuthModeChip(),
            ],
          ),
        ),
        const Divider(height: 8),
        for (final group in [
          m.GenProvider.nai,
          if (bot) ...[m.GenProvider.anima, m.GenProvider.krea],
        ]) ...[
          if (bot)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
              child: Text(
                m.providerLabel(group),
                style: context.texts.labelSmall,
              ),
            ),
          for (final value in m.modelsOf(group, nai5: true))
            MenuItemButton(
              autofocus: value == model,
              onPressed: () =>
                  ref.read(generateProvider.notifier).setModel(value),
              trailingIcon: value == model
                  ? const Icon(Icons.check, size: 16)
                  : null,
              child: SizedBox(
                width: 262,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(value, style: const TextStyle(fontSize: 13)),
                      if (m.modelDescriptions[value]
                          case final String description)
                        Text(
                          description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: context.scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ],
      builder: (context, controller, _) => Material(
        color: context.scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(19),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              height: 42,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      model,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  const Icon(Icons.expand_more, size: 18),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
