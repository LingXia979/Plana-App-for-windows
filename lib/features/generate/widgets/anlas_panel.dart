import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/desktop.dart';
import '../../../core/ui/desktop_popover.dart';

import '../../../core/auth/auth_mode.dart';
import '../../../core/net/anlas_provider.dart';
import '../../../core/net/backend_client.dart' show NaiQuota;
import '../../../core/net/nai_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/haptics.dart';
import '../../stats/stats_providers.dart' show fmtInt;
import '../generate_state.dart';
import '../models.dart' as m;

/// 创作页顶栏右侧那枚余额胶囊,以及它点开的「点数与额度」弹层。
///
/// 点数常驻,后面接一格额度百分比 —— 两种接入方式那格的含义不同:
///  - token 直连:**切到 NAI 5 时才出现**,是自己账户的 Opus 充电式额度。
///    额度用尽后免费尺寸图会转扣 Anlas,所以点数和额度两个数得同时在场。
///  - bot 授权:**常驻**,是我们发给你的个人配额(还能出几张)。常驻是因为
///    它决定「要不要切到 V5 去画」,只有切过去才看得见就晚了。管理员显示 ∞。
///    共享号池的全平台水位不在这儿 —— 那是运维视角,摆在个人胶囊里会被误读成
///    「我还有 87%」,而自己可能只剩几张。
///
/// 与算力来源胶囊同一路数:胶囊只报一眼能读完的那一段,详情全在弹层里。
class AnlasChip extends ConsumerWidget {
  const AnlasChip({super.key, this.height = 42});

  /// 顶栏用 42(与模型胶囊、算力来源胶囊同高)。
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final sub = ref.watch(anlasProvider).asData?.value;
    final bot = ref.watch(authModeProvider).value == AuthMode.bot;
    final model = ref.watch(generateProvider.select((s) => s.params.model));
    final quota = bot ? ref.watch(naiQuotaProvider).asData?.value : null;
    final usage = (!bot && m.isNai5Model(model)) ? sub?.usage : null;

    // 第二格:bot 线报自己的配额,直连线报账户电池。两者都拿不到就不摆这一格
    // (画个「—%」比不画更像出了故障)。
    final (String?, Color?) badge = switch ((quota, usage)) {
      (final NaiQuota q, _) => (
        q.isAdmin ? '∞' : '${quotaPct(q).round()}%',
        quotaColor(context, q),
      ),
      (_, final NaiUsage u) => (
        '${u.batteryPct.round()}%',
        usageColor(context, u),
      ),
      _ => (null, null),
    };

    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(height / 2),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showAnlasSheet(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 0, 6, 0),
          child: SizedBox(
            height: height,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.toll, size: 17, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  // 顶栏只报**合计**:胶囊常驻在那儿,一眼要的是「还剩多少」。
                  // 「订阅额+已购额」的拆分留给弹层里的 Anlas 那行 —— 想分清
                  // 哪截月底会重置的人,本来就会点进去看。
                  sub == null ? '—' : fmtInt(sub.anlas),
                  style: mono(
                    context,
                    size: 14,
                    weight: FontWeight.w700,
                  ).copyWith(color: scheme.primary),
                ),
                if (badge.$1 case final text?) ...[
                  // 竖线分隔:两个数一个是点数一个是百分比,不隔开会连读成一串
                  Container(
                    width: 1,
                    height: 15,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    color: scheme.outlineVariant,
                  ),
                  Text(
                    text,
                    style: mono(
                      context,
                      size: 14,
                      weight: FontWeight.w700,
                    ).copyWith(color: badge.$2),
                  ),
                ],
                Icon(Icons.expand_more, size: 17, color: scheme.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 点数读数(**弹层内**用):手里有已购额时摊开成「订阅额+已购额」,订阅额在前;
/// 没有就一个数。
///
/// 两笔钱花起来一样,但一笔月底重置、一笔是买断的 —— 合成一个数看着宽裕,
/// 月底才发现能留下的只有后面那截。摊开一眼就分得清。
///
/// 顶栏胶囊**不**用它,只报合计 [NaiSubscription.anlas]:那个位置要的是一眼
/// 看个余额,摊开的两截数字在窄胶囊里反而要人分辨中间那个加号。
String fmtAnlas(NaiSubscription s) => s.purchasedAnlas > 0
    ? '${fmtInt(s.fixedAnlas)}+${fmtInt(s.purchasedAnlas)}'
    : fmtInt(s.anlas);

/// 额度配色:满/够用走主题主色,低电量转橙,耗尽转错误色。
///
/// 只染这一处 —— 胶囊常驻顶栏,底色一染就成了长期挂着的装饰色块;
/// 一条彩色的电池条足够说明「还剩多少」了。
Color usageColor(BuildContext context, NaiUsage u) => u.isNegative
    ? context.scheme.error
    : (u.isLowOrEmpty ? FixedSemantic.warn : context.scheme.primary);

/// 我的额度水位(0~100)。上限拿不到(0)时按 0 —— 只有赠送额时进度条是空的,
/// 张数那边照样报得出来,不会因此看不见余额。
double quotaPct(NaiQuota q) =>
    q.limit > 0 ? (q.balance / q.limit * 100).clamp(0.0, 100.0) : 0;

/// 我的额度配色:与池子电池同一套语义(够用主色 / 低电橙 / 空错误色),
/// 免额度窗口开着时压过一切走强调色 —— 那会儿电量多少都不扣。
Color quotaColor(BuildContext context, NaiQuota q) {
  final scheme = context.scheme;
  if (q.freeMode || q.isAdmin) return scheme.tertiary;
  if (q.available < 1) return scheme.error;
  return quotaPct(q) <= 20 ? FixedSemantic.warn : scheme.primary;
}

/// 额度电池条。实心段 = 现在,后面那截半透明 = **24 小时后回充到的位置**
/// (这就是「回充速率」那个数看得见的样子)。
///
/// 已耗尽时不画后面那截:接口只说「跌破 0」,没说跌了多深,一天回 1.4%
/// 未必能爬回正数,画出来就是在许一个算不出的诺。
///
/// 多号合并时读数会超过 100%(5 个号满值 500%),**刻度不压缩**:一圈仍是
/// 100%,超出的部分换个颜色叠画在上面(374% = 底下三整圈 + 上面第四圈 74%)。
/// 把 500% 压成满刻度的话,「一个号见底另一个满仓」和「两个号各剩一半」画出来
/// 一模一样,看不出池子其实已经瘸了一条腿。
class UsageBar extends StatelessWidget {
  const UsageBar({super.key, required this.usage, this.height = 10});

  final NaiUsage usage;
  final double height;

  /// 一圈 100%:把合计读数切成每圈的宽度(%),末圈是余数。
  /// 上限兜底 8 圈 —— 圈数本来就等于号数,到不了,纯粹防死循环。
  static List<double> _laps(double value) {
    final out = <double>[];
    for (var left = value; left > 0 && out.length < 8; left -= 100) {
      out.add(min(100.0, left));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final color = usageColor(context, usage);
    final pct = usage.batteryPct;
    final ghost = usage.isNegative
        ? pct
        : (pct + usage.refillPctPerDay).clamp(0.0, usage.fullPct);
    final solid = _laps(pct);
    final faint = _laps(ghost);

    // 第 2 圈起换色,从主题里挑跟电量色(主色/橙/错误色)拉得开的两个轮着来。
    // 号数再多也只是循环,而相邻两圈永远不同色 —— 分得清就够了。
    Color tone(int i) =>
        i == 0 ? color : [scheme.tertiary, scheme.secondary][(i - 1) % 2];

    return _Bar(
      height: height,
      // 按圈交替铺:同一圈内先淡后实,圈序即层序 —— 淡的那截(24 小时后的预测)
      // 才不会被上面那圈的实心条盖掉。
      fills: [
        for (var i = 0; i < faint.length; i++) ...[
          // 第 2 圈起的预测段压在下面那圈的**实心**条上,.32 会被底色吃掉看不见,
          // 所以只有第一圈用 .32(它压的是空槽)。
          (faint[i] / 100, tone(i).withValues(alpha: i == 0 ? .32 : .5)),
          if (i < solid.length && solid[i] > 0) (solid[i] / 100, tone(i)),
        ],
      ],
    );
  }
}

/// 一根条:底槽 + 若干层靠左填充(按传入顺序叠,后面的画在上面)。
/// 电池条和额度条共用同一个形状 —— 各画一根的话,圆角和高度迟早只改对一处。
class _Bar extends StatelessWidget {
  const _Bar({required this.fills, this.height = 10});

  /// (占比 0~1, 颜色)。
  final List<(double, Color)> fills;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: context.scheme.outlineVariant.withValues(alpha: .55),
            ),
          ),
          for (final (factor, color) in fills)
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: factor.clamp(0.0, 1.0),
                child: ColoredBox(color: color),
              ),
            ),
        ],
      ),
    ),
  );
}

/// 点数与额度弹层。顶栏那枚胶囊点的就是它 —— 订阅档位、Anlas 余额、
/// NAI 5 额度电池与回充节奏都在这一处,不在两个地方各摆一半。
Future<void> showAnlasSheet(BuildContext context) {
  if (ProviderScope.containerOf(
    context,
    listen: false,
  ).read(desktopModeProvider)) {
    return showDesktopPopover(
      context,
      width: 370,
      maxHeight: 460,
      builder: (_) => const _AnlasSheet(desktop: true),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) => const _AnlasSheet(),
  );
}

class _AnlasSheet extends ConsumerStatefulWidget {
  const _AnlasSheet({this.desktop = false});
  final bool desktop;

  @override
  ConsumerState<_AnlasSheet> createState() => _AnlasSheetState();
}

class _AnlasSheetState extends ConsumerState<_AnlasSheet> {
  double _turns = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 开就拉一次:额度是按秒回充的,弹层里这几个读数搁旧一分钟就不准了。
    // refresh 本身是静默的(不置 loading),拉失败保留旧值,不会闪空。
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!mounted || _busy) return;
    setState(() {
      _busy = true;
      _turns += 1;
    });
    // 两条各拉各的:配额端点要会话、点数端点不要,一条挂了不该拖累另一条
    await Future.wait([
      ref.read(anlasProvider.notifier).refresh(),
      ref.read(naiQuotaProvider.notifier).refresh(),
    ]);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final sub = ref.watch(anlasProvider).asData?.value;
    final usage = sub?.usage;
    final bot = ref.watch(authModeProvider).value == AuthMode.bot;
    final quota = bot ? ref.watch(naiQuotaProvider).asData?.value : null;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, widget.desktop ? 10 : 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 0, 6),
              child: Row(
                children: [
                  Text(
                    '点数与额度',
                    style: context.texts.titleMedium!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () {
                      Haptics.selection();
                      _refresh();
                    },
                    visualDensity: VisualDensity.compact,
                    tooltip: '刷新',
                    icon: AnimatedRotation(
                      turns: _turns,
                      duration: Motion.slow,
                      curve: Motion.standard,
                      child: Icon(
                        Icons.refresh,
                        size: 20,
                        color: scheme.outline,
                      ),
                    ),
                  ),
                  if (widget.desktop)
                    IconButton(
                      tooltip: '关闭',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                ],
              ),
            ),
            // bot 线只摆**自己的**配额:池子那块是全平台水位,属于运维视角,
            // 放在个人弹层里会让人误以为「我还有 87%」,而自己可能只剩几张。
            // 它在全平台统计页(那儿才是看全局的地方)。
            if (bot && quota != null)
              _MyQuotaCard(quota: quota)
            else if (!bot && usage != null)
              UsageCard(usage: usage),
            _row(
              context,
              '订阅档位',
              bot ? 'Bot 授权' : (sub == null ? '—' : naiTierName(sub.tier)),
            ),
            _divider(context),
            _row(context, 'Anlas 点数', sub == null ? '—' : fmtAnlas(sub)),
            if (bot) ...[
              // 这两行讲的是**自己的**配额(池子那套不在这个弹层里)。
              // 拿不到时照样把行摆出来报「—」,不要静默少一块。
              _divider(context),
              _row(
                context,
                '回充速率',
                quota == null ? '—' : '${_fmtPct(quota.refillPerDay)} 张 / 天',
              ),
              _divider(context),
              _row(
                context,
                '全平台额度',
                usage == null ? '—' : '${_fmtPct(usage.batteryPct)}%',
              ),
            ] else if (usage != null) ...[
              // 按小时报:一天回多少是个抽象的数,一小时回几张才对得上「等一会儿
              // 再画」这个念头。百分比与张数同一行 —— 小时量级的数都短,放得下。
              _divider(context),
              _row(
                context,
                '回充速率',
                usage.refillPctPerHour <= 0
                    ? '—'
                    : '${_fmtRate(usage.refillPctPerHour)}% / '
                          '${fmtInt(usage.imagesPerHour)} 张 / 时',
              ),
              _divider(context),
              _row(context, '距充满', _fmtDaysToFull(usage)),
            ] else ...[
              // 电池缺席时**说明白为什么**,不要静默少一块。两种缺席原因对用户的
              // 意思完全不同:非 Opus 是没这项权益、Opus 却拿不到则说明接口那三个
              // 字段名对不上了(它们是从官方前端扒的,官方没承诺过)—— 后一条
              // 得让人看见。
              _divider(context),
              _row(
                context,
                'NAI 5 额度',
                sub == null ? '—' : (sub.tier == 3 ? '接口未下发' : '仅 Opus'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 我的额度卡(bot 线):`余额 / 上限` + 进度条 + 回满预计。
///
/// 刻意和池子那张 [_UsageCard] 长得像但**表达不同**:那张报百分比(多个服务号
/// 合并的水位),这张报张数(自己一个人的配额,有明确上限)。混成同一种表达
/// 会让人以为是同一个数。
///
/// 赠送额度挂在标题旁而不是并进进度条:它**不受上限封顶**(可以超过 200),
/// 塞进 0~100% 的条里既画不下,也会让「上限」这个概念失真。
class _MyQuotaCard extends StatelessWidget {
  const _MyQuotaCard({required this.quota});

  final NaiQuota quota;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final q = quota;
    final color = quotaColor(context, q);
    final bal = q.balance.floor();
    final extra = q.extra.floor();
    // 没资格:报 0/200 会被读成「用完了等回充」,那是完全不同的处境 ——
    // 等多久都不会有,只能去找管理员。这一句必须说出来。
    final noAccess = !q.activated && !q.isAdmin;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '我的 NAI 5 额度',
                style: context.texts.bodyMedium!.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (extra > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '+$extra 赠',
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.tertiary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const Spacer(),
              if (noAccess)
                Text(
                  '无资格',
                  style: context.texts.titleSmall!.copyWith(
                    color: FixedSemantic.warn,
                    fontWeight: FontWeight.w700,
                  ),
                )
              else ...[
                Text(
                  q.isAdmin ? '∞' : '$bal',
                  style: mono(
                    context,
                    size: 26,
                    weight: FontWeight.w700,
                  ).copyWith(color: color, height: 1),
                ),
                if (!q.isAdmin)
                  Text(
                    ' / ${q.limit}',
                    style: mono(
                      context,
                      size: 15,
                      weight: FontWeight.w700,
                    ).copyWith(color: scheme.outline),
                  ),
              ],
            ],
          ),
          if (!noAccess && !q.isAdmin) ...[
            const SizedBox(height: 10),
            _Bar(fills: [(quotaPct(q) / 100, color)]),
          ],
          const SizedBox(height: 9),
          Text(
            noAccess
                // 「其它模型照常」是这句里最要紧的一半:没有它,用户会以为
                // 整个 bot 线都用不了了。
                ? 'V5 额度只发给上线前用过 bot 出图的老用户,可找管理员开通;'
                      '其它模型不受影响'
                : q.freeMode
                // 免额度窗口开着时额度照显示但不扣 —— 不说明的话用户不会去用,
                // 这机制就白做了
                ? '当前无限制额度,暂不扣减'
                : q.isAdmin
                ? '管理员不受额度限制'
                : bal >= q.limit
                ? '已回满'
                : '每天回 ${_fmtPct(q.refillPerDay)} 张 · '
                      '约 ${_fmtHours(_hoursToFull(q))}回满',
            style: context.texts.bodySmall!.copyWith(
              color: noAccess ? scheme.onSurfaceVariant : scheme.outline,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// 回满还要几小时;不回充或已满时为 0(调用方据此不报这一段)。
double _hoursToFull(NaiQuota q) {
  if (q.refillPerDay <= 0 || q.balance >= q.limit) return 0;
  return (q.limit - q.balance) / q.refillPerDay * 24;
}

/// 小时数 → 人话。不足 1 小时报分钟,免得永远显示「约 0 小时」。
String _fmtHours(double h) {
  if (h <= 0) return '';
  if (h < 1) return '${max(1, (h * 60).round())} 分钟';
  if (h < 24) return '${_fmtPct(h)} 小时';
  return '${_fmtPct(h / 24)} 天';
}

/// 额度卡:大号百分比 + 电池条 + 折算张数。弹层里唯一带底色的一块 ——
/// 它是这张表的主角,其余都是配它的读数。
///
/// 导出给「全平台统计」页复用 —— bot 线下池子水位从个人弹层挪去了那里,
/// 两处必须长得一模一样,不然会被当成两个不同的指标。
class UsageCard extends StatelessWidget {
  const UsageCard({super.key, required this.usage});

  final NaiUsage usage;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final color = usageColor(context, usage);
    final tomorrow = (usage.batteryPct + usage.refillPctPerDay).clamp(
      0.0,
      usage.fullPct,
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                // bot 线是多个服务号合出来的一块:标上号数,不然「87%」看着像
                // 一个账户的水位,而下面那个张数却是好几个号的总量,对不上。
                usage.accounts > 1
                    ? 'NAI 5 额度 · ${usage.accounts} 号'
                    : 'NAI 5 额度',
                style: context.texts.bodyMedium!.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                _fmtPct(usage.batteryPct),
                style: mono(
                  context,
                  size: 26,
                  weight: FontWeight.w700,
                ).copyWith(color: color, height: 1),
              ),
              Text(
                '%',
                style: mono(
                  context,
                  size: 15,
                  weight: FontWeight.w700,
                ).copyWith(color: color),
              ),
            ],
          ),
          const SizedBox(height: 10),
          UsageBar(usage: usage, height: 10),
          const SizedBox(height: 9),
          Row(
            children: [
              Text(
                '约 ${fmtInt(usage.imagesRemaining)} 张',
                style: context.texts.bodySmall!.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                // 已耗尽时不报「明天到几成」:只知道跌破了 0,不知道跌了多深。
                usage.isNegative
                    ? '已用尽 · 免费尺寸图改扣 Anlas'
                    : (usage.refillPctPerDay <= 0
                          ? '已充满'
                          : '24 小时后 ${_fmtPct(tomorrow)}%'),
                style: context.texts.bodySmall!.copyWith(
                  color: usage.isNegative ? color : scheme.outline,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Widget _row(BuildContext context, String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
  child: Row(
    children: [
      Text(
        label,
        style: context.texts.bodyMedium!.copyWith(
          color: context.scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(width: 12),
      // 值这边**不能**再摆 Spacer:它跟 Flexible 一样是弹性子项,两者会把余量
      // 对半分,值只拿到一半宽度 —— 明明放得下也提前打省略号。让 Flexible 独占
      // 余量、文字自己右对齐就行。
      Expanded(
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right,
          style: context.texts.bodyMedium!.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  ),
);

Widget _divider(BuildContext context) => Divider(
  height: 1,
  thickness: 1,
  indent: 4,
  endIndent: 4,
  color: context.scheme.outlineVariant.withValues(alpha: .4),
);

/// 百分比:按位数取整后**抹掉尾随的零**,免得一列读数里只有它拖着个空转的小数位。
String _fmtPct(double v, {int digits = 1}) {
  var s = v.toStringAsFixed(digits);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s;
}

/// 回充速率专用:小时量级的数常在 0.6 这一档,一位小数不够用(0.04 会显示成 0),
/// 所以小于 1 时给两位。大于 1 照常一位。
String _fmtRate(double v) => _fmtPct(v, digits: v >= 1 ? 1 : 2);

/// 距充满:满电直说满电,不到一天报小时,否则报天。
String _fmtDaysToFull(NaiUsage u) {
  if (u.batteryPct >= u.fullPct) return '已充满';
  final d = u.daysToFull;
  if (d == null) return '—';
  if (d < 1) return '约 ${(d * 24).round()} 小时';
  return '约 ${_fmtPct(d)} 天';
}
