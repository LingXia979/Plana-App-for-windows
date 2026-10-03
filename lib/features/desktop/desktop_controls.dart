part of 'desktop_workspace.dart';

class _DesktopControls extends ConsumerStatefulWidget {
  const _DesktopControls();

  @override
  ConsumerState<_DesktopControls> createState() => _DesktopControlsState();
}

class _DesktopControlsState extends ConsumerState<_DesktopControls> {
  final _scroll = ScrollController(debugLabel: 'Desktop controls');
  final _parameters = GlobalKey<_DesktopParametersState>();
  final _img2img = GlobalKey();
  int? _scheduledImg2ImgReveal;

  void _scheduleImg2ImgReveal(int request) {
    if (_scheduledImg2ImgReveal == request) return;
    _scheduledImg2ImgReveal = request;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _img2img.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: 0,
            duration: Motion.medium,
            curve: Motion.standard,
          ),
        );
      }
      ref.read(desktopImg2ImgRevealProvider.notifier).handled(request);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(generateProvider);
    final reveal = ref.watch(desktopImg2ImgRevealProvider);
    if (reveal != null) _scheduleImg2ImgReveal(reveal);
    final modules =
        (ref.watch(genModulesProvider).value ?? const GenModuleSettings())
            .visibleFor(s.params.model);
    // Desktop keeps image-to-image next to character prompts. Other modules
    // keep their existing relative order and visibility preferences.
    if (modules.remove(GenModule.img2img)) {
      modules.insert(
        modules.indexOf(GenModule.character) + 1,
        GenModule.img2img,
      );
    }
    return Material(
      color: context.scheme.surfaceContainerLow,
      child: Column(
        children: [
          const GenerateTopBar(),
          Expanded(
            child: Scrollbar(
              key: const ValueKey('desktop-controls-scrollbar'),
              controller: _scroll,
              thumbVisibility: true,
              interactive: true,
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(
                  context,
                ).copyWith(scrollbars: false),
                // There are only a handful of modules, but their heights differ
                // greatly. Lay them out together so thumb dragging never uses
                // a lazy list's changing estimate of the total content height.
                child: SingleChildScrollView(
                  key: const PageStorageKey('desktop-controls-scroll'),
                  controller: _scroll,
                  primary: false,
                  padding: const EdgeInsets.fromLTRB(12, 3, 12, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _DesktopPrompt(),
                      const SizedBox(height: 12),
                      for (final module in modules) ...[
                        KeyedSubtree(
                          key: ValueKey('desktop-module-${module.name}'),
                          child: KeyedSubtree(
                            key: module == GenModule.img2img ? _img2img : null,
                            child: buildGenerateModuleCard(module, null),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      const SizedBox(height: 4),
                      _DesktopParameters(key: _parameters),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          BottomActionBar(
            desktop: true,
            onSettingTap: (target) => _parameters.currentState?.reveal(target),
          ),
        ],
      ),
    );
  }
}
