part of 'desktop_workspace.dart';

class _DesktopParameters extends ConsumerStatefulWidget {
  const _DesktopParameters({super.key});
  @override
  ConsumerState<_DesktopParameters> createState() => _DesktopParametersState();
}

class _DesktopParametersState extends ConsumerState<_DesktopParameters> {
  static const _expandedKey = 'desktop_generation_settings_expanded';
  late bool expanded = ref.read(prefsStoreProvider).get(_expandedKey) != '0';
  final _anchors = {
    for (final target in GenerationSettingTarget.values) target: GlobalKey(),
  };
  GenerationSettingTarget? _highlight;
  Timer? _highlightTimer;

  Future<void> reveal(GenerationSettingTarget target) async {
    _highlightTimer?.cancel();
    setState(() {
      expanded = true;
      _highlight = target;
    });
    unawaited(
      ref.read(prefsStoreProvider).write(key: _expandedKey, value: '1'),
    );
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final anchor = _anchors[target]?.currentContext;
    if (anchor != null && anchor.mounted) {
      await Scrollable.ensureVisible(
        anchor,
        alignment: .16,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted) return;
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlight = null);
    });
  }

  Widget _setting(GenerationSettingTarget target, Widget child) =>
      AnimatedContainer(
        key: _anchors[target],
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: _highlight == target
              ? context.scheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: child,
      );

  void _toggleExpanded() {
    setState(() => expanded = !expanded);
    unawaited(
      ref
          .read(prefsStoreProvider)
          .write(key: _expandedKey, value: expanded ? '1' : '0'),
    );
  }

  late final seed = TextEditingController(
    text: ref.read(generateProvider).params.seed,
  );
  @override
  void dispose() {
    _highlightTimer?.cancel();
    seed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(generateProvider).params;
    ref.listen(generateProvider.select((s) => s.params.seed), (_, value) {
      if (seed.text != value) seed.text = value;
    });
    void apply(GenParams value) =>
        ref.read(generateProvider.notifier).applyParams(value);
    final anima = isAnimaModel(p.model);
    final krea = isKreaModel(p.model);
    final modal = anima || krea;
    final cfg = anima
        ? p.animaCfg
        : krea
        ? p.kreaCfg
        : p.cfg;
    final sampler = anima
        ? p.animaSampler
        : krea
        ? p.kreaSampler
        : p.sampler;
    final options = anima
        ? animaSamplers
        : krea
        ? kreaSamplers
        : null;
    final minSteps = anima
        ? animaStepsRange.min
        : krea
        ? kreaStepsRange.min
        : 1;
    final maxSteps = anima
        ? animaStepsRange.max
        : krea
        ? kreaStepsRange.max
        : 50;
    final cfgMin = anima
        ? animaCfgRange.min
        : krea
        ? kreaCfgRange.min
        : 0.0;
    final cfgMax = anima
        ? animaCfgRange.max
        : krea
        ? kreaCfgRange.max
        : 25.0;
    return Material(
      color: context.scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: context.scheme.outlineVariant.withValues(alpha: .6),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            key: const ValueKey('desktop-generation-settings'),
            onTap: _toggleExpanded,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, size: 18),
                  const SizedBox(width: 9),
                  const Expanded(
                    child: Text(
                      '生成设置',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
              child: Column(
                children: [
                  _setting(
                    GenerationSettingTarget.steps,
                    ParamSlider(
                      key: const ValueKey('desktop-steps'),
                      snapInputToDivisions: true,
                      label: '步数',
                      value: p.activeSteps.toDouble().clamp(
                        minSteps.toDouble(),
                        maxSteps.toDouble(),
                      ),
                      min: minSteps.toDouble(),
                      max: maxSteps.toDouble(),
                      divisions: maxSteps - minSteps,
                      valueText: '${p.activeSteps}',
                      dense: true,
                      onChanged: (v) => apply(p.withActiveSteps(v.round())),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _setting(
                    GenerationSettingTarget.guidance,
                    ParamSlider(
                      key: const ValueKey('desktop-guidance'),
                      label: '提示词引导',
                      value: cfg.clamp(cfgMin, cfgMax),
                      min: cfgMin,
                      max: cfgMax,
                      divisions: ((cfgMax - cfgMin) * 10).round(),
                      valueText: cfg.toStringAsFixed(1),
                      dense: true,
                      onChanged: (v) => apply(
                        anima
                            ? p.copyWith(animaCfg: v)
                            : krea
                            ? p.copyWith(kreaCfg: v)
                            : p.copyWith(cfg: v),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _setting(
                    GenerationSettingTarget.seed,
                    TextField(
                      key: const ValueKey('desktop-seed'),
                      controller: seed,
                      style: const TextStyle(fontSize: 12),
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: '种子',
                        hintText: '留空为随机',
                        isDense: true,
                        suffixIcon: IconButton(
                          tooltip: '随机种子',
                          onPressed: () => apply(p.copyWith(seed: '')),
                          icon: const Icon(Icons.casino_outlined, size: 18),
                        ),
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (v) => apply(p.copyWith(seed: v)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    key: ValueKey('desktop-sampler-${p.model}-$sampler'),
                    initialValue: sampler,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '采样器',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: options == null
                        ? [
                            for (final s in samplers)
                              DropdownMenuItem(
                                value: s,
                                child: Text(
                                  s,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ]
                        : [
                            for (final s in options)
                              DropdownMenuItem(
                                value: s.id,
                                child: Text(
                                  s.label,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                    onChanged: (v) {
                      if (v != null) {
                        apply(
                          anima
                              ? p.copyWith(animaSampler: v)
                              : krea
                              ? p.copyWith(kreaSampler: v)
                              : p.copyWith(sampler: v),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 14),
                  if (modal)
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        'desktop-scheduler-${p.model}-${anima ? p.animaScheduler : p.kreaScheduler}',
                      ),
                      initialValue: anima ? p.animaScheduler : p.kreaScheduler,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '调度器',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final s
                            in anima ? animaSchedulers : kreaSchedulers)
                          DropdownMenuItem(
                            value: s.id,
                            child: Text(
                              s.label,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          apply(
                            anima
                                ? p.copyWith(animaScheduler: v)
                                : p.copyWith(kreaScheduler: v),
                          );
                        }
                      },
                    ),
                  if (!modal) ...[
                    const Divider(height: 1),
                    const SizedBox(height: 14),
                    ParamSlider(
                      key: const ValueKey('desktop-rescale'),
                      label: '引导重缩放',
                      value: p.cfgRescale,
                      dense: true,
                      divisions: 100,
                      onChanged: (v) => apply(p.copyWith(cfgRescale: v)),
                    ),
                    if (!isNai5Model(p.model)) ...[
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        key: ValueKey('desktop-noise-${p.noiseSchedule}'),
                        initialValue: p.noiseSchedule,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '噪声调度',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final n in noiseSchedules)
                            DropdownMenuItem(
                              value: n,
                              child: Text(
                                n,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) apply(p.copyWith(noiseSchedule: v));
                        },
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: p.varietyPlus,
                        title: const Text(
                          'Variety+',
                          style: TextStyle(fontSize: 12),
                        ),
                        onChanged: (v) => apply(p.copyWith(varietyPlus: v)),
                      ),
                    ],
                  ],
                  if (p.batchable) ...[
                    const SizedBox(height: 12),
                    ParamSlider(
                      label: '每次张数',
                      value: p.batchCount.toDouble(),
                      min: 1,
                      max: kBatchMax.toDouble(),
                      divisions: kBatchMax - 1,
                      valueText: '${p.batchCount}',
                      dense: true,
                      onChanged: (v) =>
                          apply(p.copyWith(batchCount: v.round())),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
