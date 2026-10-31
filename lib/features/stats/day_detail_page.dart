import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/backend_client.dart';
import '../../core/store/app_stores.dart';
import '../../core/theme/app_theme.dart';
import 'key_ledger.dart';
import 'stats_providers.dart';
import 'stats_widgets.dart';
import 'wallet_page.dart';
import '../../core/ui/settings_scaffold.dart';

enum DayDetailMode {
  points('点数详情'),
  gens('生成详情');

  const DayDetailMode(this.title);
  final String title;
}

/// 某一天的逐笔明细。
///
/// - 点数:Bot 取服务端 `points_spent` 逐笔(reason 解析成功能类型 + 参数);
///   Key 合并本机的计费生成与 Vibe 编码 / 超分操作。
/// - 生成:Key 有本机逐笔;Bot 取 `/api/user/stats/calls`(本次为此新增的
///   后端接口,含分辨率/步数/模型)。后端尚未部署该接口时降级为只显示次数。
class DayDetailPage extends ConsumerWidget {
  const DayDetailPage({
    super.key,
    required this.bot,
    required this.day,
    required this.label,
    required this.mode,
  });

  final bool bot;

  /// 当天 00:00。
  final DateTime day;

  /// 标题里的日期文案(今天 / 07-24)。
  final String label;
  final DayDetailMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallet = bot ? ref.watch(walletSummaryProvider) : null;
    final walletMode =
        bot && mode == DayDetailMode.points && wallet?.asData?.value != null;
    return SettingsScaffold(
      appBar: AppBar(
        title: Text('$label · ${walletMode ? '钱包流水' : mode.title}'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          const SettingsPageHeader(),
          ...(bot ? _botBody(context, ref) : _keyBody(context, ref)),
        ],
      ),
    );
  }

  // ── Bot:服务端明细 ────────────────

  List<Widget> _botBody(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(walletSummaryProvider);
    if (summary.asData?.value != null) {
      return mode == DayDetailMode.points
          ? _botWallet(context, ref)
          : _botGens(context, ref);
    }
    if (summary.asData != null) return _legacyBotBody(context, ref);
    if (summary.isLoading) return _skeletonRows(4);
    return [
      StatsCard(
        child: Column(
          children: [
            const Text('暂时无法取得钱包信息'),
            TextButton(
              onPressed: () => ref.invalidate(walletSummaryProvider),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    ];
  }

  /// 当天的钱包流水:扣款 / 入账两个合计 + 逐笔。
  List<Widget> _botWallet(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final async = ref.watch(dayWalletLedgerProvider(day));
    final w = async.asData?.value;
    final loading = async.isLoading && w == null;

    if (!async.isLoading && w == null) {
      return const [StatsCard(child: Text('当天的流水暂时查不到,稍后再试'))];
    }

    // 扣款和入账分开合计:两件事,轧差没有意义(那是余额的事)
    var charged = 0, credited = 0, nCharge = 0, nCredit = 0;
    for (final e in w?.items ?? const <WalletEntry>[]) {
      if (e.amountFen < 0) {
        charged -= e.amountFen;
        nCharge++;
      } else if (e.amountFen > 0) {
        credited += e.amountFen;
        nCredit++;
      }
    }

    return [
      StatsCard(
        child: Row(
          children: [
            Expanded(
              child: StatTile(
                icon: Icons.remove_circle_outline,
                label: w?.nextCursor != null ? '已加载扣款' : '当日扣款',
                value: w == null ? null : fmtFen(charged, sign: false),
                suffix: nCharge > 0 ? '$nCharge 笔' : null,
                loading: loading,
              ),
            ),
            Expanded(
              child: StatTile(
                icon: Icons.add_circle_outline,
                label: w?.nextCursor != null ? '已加载入账' : '当日入账',
                value: w == null ? null : fmtFen(credited, sign: false),
                suffix: nCredit > 0 ? '$nCredit 笔' : null,
                loading: loading,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      StatsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '逐笔流水',
              style: context.texts.bodyMedium!.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            if (w == null)
              ..._skeletonRows(4)
            else if (w.items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '当天没有钱包流水',
                  style: context.texts.bodySmall!.copyWith(
                    color: scheme.outline,
                  ),
                ),
              )
            else ...[
              for (final e in w.items)
                WalletEntryRow(entry: e, withDate: false),
              // 翻页到上限还没到底(见 dayWalletLedgerProvider):合计也只算了列出来的这些
              if (w.nextCursor != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Text(
                    '仅取得 ${fmtInt(w.items.length)} 笔，合计为已显示记录；可稍后重试。',
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    ];
  }

  /// 当天的逐笔生成(`/api/user/stats/calls`):合计按逐笔现算。
  List<Widget> _botGens(BuildContext context, WidgetRef ref) {
    final callsAsync = ref.watch(dayCallsProvider(day));
    final calls = callsAsync.asData?.value;
    final loading = callsAsync.isLoading && calls == null;

    return [
      StatsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    icon: Icons.image_outlined,
                    label: '当日生图',
                    value: calls == null ? null : fmtInt(calls.length),
                    loading: loading,
                  ),
                ),
                Expanded(
                  child: StatTile(
                    icon: Icons.toll_outlined,
                    label: '点数消耗',
                    value: calls == null
                        ? null
                        : fmtInt(calls.fold(0, (s, c) => s + c.anlas)),
                    loading: loading,
                  ),
                ),
              ],
            ),
            if (calls != null) ...[
              const CardDivider(),
              Row(
                children: [
                  Expanded(
                    child: StatTile(
                      icon: Icons.redeem_outlined,
                      label: '免费张数',
                      value: fmtInt(calls.where((c) => c.anlas == 0).length),
                    ),
                  ),
                  Expanded(
                    child: StatTile(
                      icon: Icons.straighten,
                      label: '平均步数',
                      value: () {
                        final ok = calls.where((c) => c.steps > 0).toList();
                        return ok.isEmpty
                            ? '—'
                            : fmtInt(
                                ok.fold(0, (s, c) => s + c.steps) / ok.length,
                              );
                      }(),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 10),
      StatsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '逐笔生成',
              style: context.texts.bodyMedium!.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            ..._callRows(context, calls, callsAsync.isLoading, calls?.length),
          ],
        ),
      ),
    ];
  }

  List<Widget> _legacyBotBody(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dayDetailsProvider(day));
    final d = async.value;
    final loading = async.isLoading;

    if (!loading && d == null) {
      return const [StatsCard(child: Text('该日明细取不到,可能是会话过期或后端未开放'))];
    }

    final callsAsync = ref.watch(dayCallsProvider(day));
    final calls = callsAsync.value;

    return [
      StatsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    icon: Icons.image_outlined,
                    label: '当日生图',
                    value: d == null ? null : fmtInt(d.imageCalls),
                    loading: loading,
                  ),
                ),
                Expanded(
                  child: StatTile(
                    icon: Icons.toll_outlined,
                    label: '点数消耗',
                    value: d == null ? null : fmtInt(d.points),
                    loading: loading,
                  ),
                ),
              ],
            ),
            // 两个磁贴报的是**全部**出图与全部点数;V5 与自建后端各自占了多少
            // 单起一行 —— V5 扣点是 V4.5 的 1.5 倍,张数看不出真实消耗;
            // anima/krea 那些图确实出了,只是不进 NAI 分摊,不写会被当成漏算。
            if (d != null && (d.v5Calls > 0 || d.localCalls > 0))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  [
                    if (d.v5Calls > 0)
                      '其中 V5 ${fmtInt(d.v5Calls)} 张 · ${fmtInt(d.v5Points)} 点',
                    if (d.localCalls > 0)
                      'anima/krea ${fmtInt(d.localCalls)} 张(不进分摊)',
                  ].join(' · '),
                  style: context.texts.labelSmall!.copyWith(
                    color: context.scheme.outline,
                  ),
                ),
              ),
            if (mode == DayDetailMode.points &&
                (loading || (d?.breakdown.isNotEmpty ?? false))) ...[
              const CardDivider(),
              ..._breakdownRows(context, d?.breakdown, loading),
            ],
            if (mode == DayDetailMode.gens && calls != null) ...[
              const CardDivider(),
              Row(
                children: [
                  Expanded(
                    child: StatTile(
                      icon: Icons.redeem_outlined,
                      label: '免费张数',
                      value: fmtInt(calls.where((c) => c.anlas == 0).length),
                    ),
                  ),
                  Expanded(
                    child: StatTile(
                      icon: Icons.straighten,
                      label: '平均步数',
                      value: () {
                        final ok = calls.where((c) => c.steps > 0).toList();
                        return ok.isEmpty
                            ? '—'
                            : fmtInt(
                                ok.fold(0, (s, c) => s + c.steps) / ok.length,
                              );
                      }(),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 10),
      StatsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              mode == DayDetailMode.points ? '逐笔消耗' : '逐笔生成',
              style: context.texts.bodyMedium!.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            if (mode == DayDetailMode.points)
              ..._pointRows(context, d?.records, loading)
            else
              ..._callRows(context, calls, callsAsync.isLoading, d?.imageCalls),
          ],
        ),
      ),
    ];
  }

  /// 逐笔生成行:时间 · 分辨率 · 步数 · 模型 · 扣点/免费。
  List<Widget> _callRows(
    BuildContext context,
    List<CallRecord>? calls,
    bool loading,
    int? dayCount,
  ) {
    final scheme = context.scheme;
    if (loading && calls == null) return _skeletonRows(4);
    if (calls == null) {
      // 后端还没部署 /api/user/stats/calls
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            dayCount == null
                ? '逐笔生成明细不可用'
                : '该日共 ${fmtInt(dayCount)} 次生成;逐笔明细需后端更新后可见',
            style: context.texts.bodySmall!.copyWith(color: scheme.outline),
          ),
        ),
      ];
    }
    if (calls.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            '该日无生成记录',
            style: context.texts.bodySmall!.copyWith(color: scheme.outline),
          ),
        ),
      ];
    }
    return [
      for (final c in calls)
        LedgerRow(
          icon: c.img2img ? Icons.brush_outlined : Icons.image_outlined,
          title: c.hasParams
              ? '${c.width}×${c.height}'
                    '${c.steps > 0 ? ' · ${c.steps} 步' : ''}'
                    '${c.img2img ? ' · 图生图' : ''}'
                    '${c.charRefs > 0 ? ' · 角色参考×${c.charRefs}' : ''}'
              : '生成',
          sub: [
            if (c.time != null) _hhmm(c.time!),
            if (c.model.isNotEmpty) modelLabel(c.model),
          ].join(' · '),
          trailing: c.anlas > 0 ? '-${fmtInt(c.anlas)} 点' : '免费',
          trailingColor: c.anlas > 0 ? scheme.primary : scheme.tertiary,
        ),
    ];
  }

  List<Widget> _breakdownRows(
    BuildContext context,
    List<({String reason, int points, int count, int v5Points, int v5Count})>?
    bd,
    bool loading,
  ) {
    if (loading && bd == null) {
      return [
        for (var i = 0; i < 2; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: SkeletonText(
              sample: '生图 000 点 · 00 笔',
              style: context.texts.bodySmall!,
              width: 150,
            ),
          ),
      ];
    }
    // 提前返回而不是 `bd ?? const []`:后者推不出类型实参,会把 b 退化成 dynamic,
    // record 字段改名/改类型时编译器不报错,运行时才炸。
    if (bd == null || bd.isEmpty) return const [];
    final max = bd.fold(1, (m, b) => b.points > m ? b.points : m);
    return [
      for (final b in bd)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 96,
                child: Text(
                  // 组内标出 V5 占了多少,而不是按模型再拆一组 —— reason 里已经
                  // 写了尺寸步数,拆开会把同一类消耗切成两行。
                  '${parseReason(b.reason).type} ×${b.count}'
                  '${b.v5Count > 0 ? '(V5 ${b.v5Count})' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.labelMedium!.copyWith(
                    color: context.scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: b.points / max,
                    minHeight: 6,
                    backgroundColor: context.scheme.surfaceContainerHigh,
                    color: context.scheme.primary,
                  ),
                ),
              ),
              SizedBox(
                width: 66,
                child: Text(
                  '${fmtInt(b.points)} 点',
                  textAlign: TextAlign.right,
                  style: mono(context, size: 11),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  /// 逐笔消耗行:功能类型 + 该功能的参数(分辨率/步数/倍率)。
  List<Widget> _pointRows(
    BuildContext context,
    List<PointRecord>? records,
    bool loading,
  ) {
    final scheme = context.scheme;
    if (loading && records == null) return _skeletonRows(4);
    if (records == null || records.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            '该日无计费记录',
            style: context.texts.bodySmall!.copyWith(color: scheme.outline),
          ),
        ),
      ];
    }
    return [
      for (final r in records)
        () {
          final p = parseReason(r.reason);
          return LedgerRow(
            icon: p.icon,
            // V5 标在标题上而不是塞进副行:副行那串是「时间 · 尺寸步数」,
            // 混进去一眼扫不出来,而这正是解释「同尺寸为什么贵了一半」的那半句。
            title: r.isV5 ? '${p.type} · V5' : p.type,
            sub: [
              if (r.time != null) _hhmm(r.time!),
              if (p.detail.isNotEmpty) p.detail,
            ].join(' · '),
            trailing: '-${fmtInt(r.points)} 点',
          );
        }(),
    ];
  }

  List<Widget> _skeletonRows(int n) => [
    for (var i = 0; i < n; i++)
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            SkeletonBox(width: 30, height: 30, radius: 9),
            SizedBox(width: 10),
            Expanded(child: SkeletonBox(width: 120, height: 12)),
          ],
        ),
      ),
  ];

  // ── Key:本机逐笔 ────────────────

  List<Widget> _keyBody(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final ledger = ref.watch(appStoresProvider).ledger;
    final key = KeyLedgerStore.dayKey(day);
    final agg = ledger.days[key];
    final gens = ledger.gensForDay(key);
    final ops = ledger.opsForDay(key);

    final rows = <Widget>[];
    if (mode == DayDetailMode.gens) {
      for (final g in gens) {
        rows.add(
          LedgerRow(
            icon: g.inpaint ? Icons.brush_outlined : Icons.image_outlined,
            title:
                '${g.width}×${g.height}'
                '${g.steps > 0 ? ' · ${g.steps} 步' : ''}'
                '${g.inpaint ? ' · 重绘' : ''}',
            sub:
                '${_hhmm(DateTime.fromMillisecondsSinceEpoch(g.ts))}'
                '${g.model.isEmpty ? '' : ' · ${g.model}'}',
            trailing: g.pts > 0 ? '-${fmtInt(g.pts)} 点' : '免费',
            trailingColor: g.pts > 0 ? scheme.primary : scheme.tertiary,
          ),
        );
      }
    } else {
      // 点数详情:计费生成 + 单笔操作,按时间倒序合并
      final merged = <({int ts, Widget row})>[
        for (final g in gens)
          if (g.pts > 0)
            (
              ts: g.ts,
              row: LedgerRow(
                icon: g.inpaint ? Icons.brush_outlined : Icons.image_outlined,
                title:
                    '生图 ${g.width}×${g.height}'
                    '${g.steps > 0 ? ' · ${g.steps} 步' : ''}',
                sub: _hhmm(DateTime.fromMillisecondsSinceEpoch(g.ts)),
                trailing: '-${fmtInt(g.pts)} 点',
              ),
            ),
        for (final o in ops)
          (
            ts: o.ts,
            row: LedgerRow(
              icon: o.type == 'upscale'
                  ? Icons.zoom_in
                  : Icons.palette_outlined,
              title: o.type == 'upscale' ? '超分 4x' : 'Vibe 编码',
              sub: _hhmm(DateTime.fromMillisecondsSinceEpoch(o.ts)),
              trailing: '-${fmtInt(o.pts)} 点',
            ),
          ),
      ]..sort((a, b) => b.ts.compareTo(a.ts));
      rows.addAll(merged.map((e) => e.row));
    }

    final opsPts = ops.fold(0, (s, o) => s + o.pts);
    // 明细窗口只保留最近若干条,老日子可能只剩聚合数
    final rolled = (agg?.images ?? 0) > 0 && gens.isEmpty;

    return [
      StatsCard(
        child: Row(
          children: [
            Expanded(
              child: StatTile(
                icon: Icons.image_outlined,
                label: '当日生图',
                value: fmtInt(agg?.images ?? 0),
                suffix: (agg?.free ?? 0) > 0 ? '免费 ${agg!.free}' : null,
              ),
            ),
            Expanded(
              child: StatTile(
                icon: Icons.toll_outlined,
                label: '估算消耗',
                value: fmtInt((agg?.pts ?? 0) + opsPts),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      StatsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              mode == DayDetailMode.points ? '逐笔消耗' : '逐笔生成',
              style: context.texts.bodyMedium!.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  rolled ? '该日明细已超出保留窗口,仅剩汇总' : '该日无记录',
                  style: context.texts.bodySmall!.copyWith(
                    color: scheme.outline,
                  ),
                ),
              )
            else
              ...rows,
          ],
        ),
      ),
    ];
  }
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 服务端模型 id → 展示名(`nai-diffusion-4-5-full` → `NAI 4.5 Full`)。
String modelLabel(String id) {
  final s = id.toLowerCase();
  if (!s.startsWith('nai-diffusion')) return id;
  // 5.0 用 startsWith 判:contains('5') 会误吞 4-5 系,这是唯一稳的写法。
  // 不加这行,nai-diffusion-5-* 会一路漏到 '3' 分支错标成「NAI 3 Full」。
  final ver = s.startsWith('nai-diffusion-5')
      ? '5.0'
      : s.contains('4-5')
      ? '4.5'
      : s.contains('4')
      ? '4.0'
      : '3';
  final tier = s.contains('curated') ? ' Curated' : ' Full';
  return 'NAI $ver${s.contains('-3') && ver == '3' ? '' : tier}';
}

/// 服务端 reason 解析成 (功能类型, 参数细节, 图标)。
/// 已知格式:
///  - `web生图(生图832x1216_28步=20, 角色参考x1=5)`
///  - `vibe编码`
///  - `超分辨率(1024x1024, 4x)`
({String type, String detail, IconData icon}) parseReason(String reason) {
  final inner = RegExp(r'\(([^)]*)\)').firstMatch(reason)?.group(1) ?? '';

  if (reason.contains('超分')) {
    return (
      type: '超分',
      detail: inner.replaceAll('x', '×'),
      icon: Icons.zoom_in,
    );
  }
  if (reason.toLowerCase().contains('vibe') || reason.contains('编码')) {
    return (type: 'Vibe 编码', detail: inner, icon: Icons.palette_outlined);
  }
  if (reason.contains('生图')) {
    // 括号里逐项:`生图832x1216_28步=20`、`角色参考x1=5`
    final parts = <String>[];
    var hasCharRef = false;
    for (final seg in inner.split(',')) {
      final t = seg.trim();
      final m = RegExp(r'生图(\d+)x(\d+)_(\d+)步').firstMatch(t);
      if (m != null) {
        parts.add('${m.group(1)}×${m.group(2)} · ${m.group(3)} 步');
        continue;
      }
      final cr = RegExp(r'角色参考x(\d+)').firstMatch(t);
      if (cr != null) {
        hasCharRef = true;
        parts.add('角色参考×${cr.group(1)}');
      }
    }
    return (
      type: '生图',
      detail: parts.join(' · '),
      icon: hasCharRef ? Icons.person_outline : Icons.image_outlined,
    );
  }
  return (type: reason.isEmpty ? '未知' : reason, detail: '', icon: Icons.bolt);
}
