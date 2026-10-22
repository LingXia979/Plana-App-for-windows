import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/desktop_popover.dart';

/// Browse the full tag pool horizontally with drag, wheel and arrow controls.
/// The searchable picker provides a shortcut to a specific tag.
class DesktopTagFilterBar extends StatefulWidget {
  const DesktopTagFilterBar({
    super.key,
    required this.tags,
    required this.selectedTag,
    required this.favoritesSelected,
    required this.onTagSelected,
    required this.onFavoritesSelected,
    required this.onManage,
  });

  final List<String> tags;
  final String? selectedTag;
  final bool favoritesSelected;
  final ValueChanged<String?> onTagSelected;
  final VoidCallback onFavoritesSelected;
  final ValueChanged<BuildContext> onManage;

  @override
  State<DesktopTagFilterBar> createState() => _DesktopTagFilterBarState();
}

class _DesktopTagFilterBarState extends State<DesktopTagFilterBar> {
  final _scroll = ScrollController();
  final _selectedChip = GlobalKey();
  double _stripWidth = 0;
  double? _viewportWidth;
  double? _contentWidth;
  bool _revealScheduled = false;
  bool _overflow = false;
  bool _canScrollBack = false;
  bool _canScrollForward = false;
  bool _pickerOpen = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncScrollControls);
    _revealSelection();
  }

  @override
  void didUpdateWidget(DesktopTagFilterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedTag != widget.selectedTag ||
        !listEquals(oldWidget.tags, widget.tags)) {
      _revealSelection();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _syncScrollControls() {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    final overflow =
        position.maxScrollExtent + position.viewportDimension >
        _stripWidth + .5;
    final back = overflow && position.pixels > position.minScrollExtent + .5;
    final forward = overflow && position.pixels < position.maxScrollExtent - .5;
    if (overflow == _overflow &&
        back == _canScrollBack &&
        forward == _canScrollForward) {
      return;
    }
    setState(() {
      _overflow = overflow;
      _canScrollBack = back;
      _canScrollForward = forward;
    });
  }

  void _revealSelection() {
    if (_revealScheduled || widget.selectedTag == null) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final target = _selectedChip.currentContext?.findRenderObject();
      if (target == null) return;
      _scroll.position.ensureVisible(
        target,
        alignment: .5,
        duration: Motion.fast,
        curve: Curves.easeOut,
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _metricsChanged(ScrollMetricsNotification notification) {
    final metrics = notification.metrics;
    final contentWidth = metrics.maxScrollExtent + metrics.viewportDimension;
    if (_viewportWidth != metrics.viewportDimension ||
        _contentWidth != contentWidth) {
      _viewportWidth = metrics.viewportDimension;
      _contentWidth = contentWidth;
      _revealSelection();
    }
    _syncScrollControls();
    return false;
  }

  void _scrollBy(int direction) {
    final position = _scroll.position;
    final target =
        (position.pixels + direction * position.viewportDimension * .8).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    _scroll.animateTo(target, duration: Motion.fast, curve: Curves.easeOut);
  }

  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final position = _scroll.position;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => _scroll.jumpTo(target),
    );
  }

  Future<void> _pickTag(BuildContext anchor) async {
    if (_pickerOpen) return;
    _pickerOpen = true;
    try {
      final picked = await showDesktopPopover<({String? tag})>(
        anchor,
        width: 360,
        maxHeight: 460,
        builder: (_) =>
            _TagPicker(tags: widget.tags, selectedTag: widget.selectedTag),
      );
      if (mounted && picked != null) widget.onTagSelected(picked.tag);
    } finally {
      _pickerOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // The tag strip takes all remaining width between the fixed filters
        // and actions. A narrow sidebar gives the strip a full row of its own.
        final filters = _filters(context);
        final actions = Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (widget.tags.isNotEmpty)
              Builder(
                builder: (anchor) => OutlinedButton(
                  key: const ValueKey('inspiration-all-tags'),
                  onPressed: () => _pickTag(anchor),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: const StadiumBorder(),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('全部标签 · ${widget.tags.length}'),
                      const SizedBox(width: 4),
                      const Icon(Icons.expand_more, size: 18),
                    ],
                  ),
                ),
              ),
            Builder(
              builder: (anchor) => TextButton.icon(
                key: const ValueKey('inspiration-manage-tags'),
                onPressed: () => widget.onManage(anchor),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('管理标签'),
              ),
            ),
          ],
        );
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        return SizedBox(
          width: box.maxWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: box.maxWidth < 520 * textScale
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [filters, const SizedBox(height: 6), actions],
                  )
                : Row(
                    children: [
                      Expanded(child: filters),
                      const SizedBox(width: 12),
                      actions,
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _filters(BuildContext context) {
    final fixed = Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _chip(
          context,
          label: '全部',
          selected: widget.selectedTag == null && !widget.favoritesSelected,
          onTap: () => widget.onTagSelected(null),
        ),
        _chip(
          context,
          label: '收藏',
          icon: Icons.star_rounded,
          selected: widget.favoritesSelected,
          onTap: widget.onFavoritesSelected,
        ),
      ],
    );
    if (widget.tags.isEmpty) return fixed;
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(13) / 13;
        if (constraints.maxWidth < 420 * textScale) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [fixed, const SizedBox(height: 6), _tagStrip(context)],
          );
        }
        return Row(
          children: [
            fixed,
            const SizedBox(width: 8),
            Expanded(child: _tagStrip(context)),
          ],
        );
      },
    );
  }

  Widget _tagStrip(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _stripWidth = constraints.maxWidth;
      // Keep chip widths independent of arrow visibility. Otherwise showing
      // the arrows can shrink the content enough to hide them again forever.
      // Reserve both arrows so a long chip also fits the smaller viewport.
      final labelWidth = (_stripWidth - 56 - 40).clamp(40.0, 220.0);
      return Row(
        children: [
          if (_overflow)
            _scrollArrow(
              key: const ValueKey('inspiration-tags-left'),
              tooltip: '向左查看更多标签',
              icon: Icons.chevron_left,
              enabled: _canScrollBack,
              direction: -1,
            ),
          Expanded(
            key: const ValueKey('inspiration-tag-viewport'),
            child: MouseRegion(
              cursor: _overflow
                  ? SystemMouseCursors.grab
                  : SystemMouseCursors.basic,
              child: Listener(
                onPointerSignal: _onWheel,
                child: NotificationListener<ScrollMetricsNotification>(
                  onNotification: _metricsChanged,
                  child: SizedBox(
                    height: MediaQuery.textScalerOf(context).scale(13) + 28,
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(
                        scrollbars: false,
                        dragDevices: {
                          ...ScrollConfiguration.of(context).dragDevices,
                          PointerDeviceKind.mouse,
                        },
                      ),
                      child: Scrollbar(
                        controller: _scroll,
                        thumbVisibility: _overflow,
                        interactive: true,
                        thickness: 3,
                        scrollbarOrientation: ScrollbarOrientation.bottom,
                        child: SingleChildScrollView(
                          key: const ValueKey('inspiration-tag-strip'),
                          controller: _scroll,
                          primary: false,
                          scrollDirection: Axis.horizontal,
                          physics: const ClampingScrollPhysics(),
                          child: SizedBox(
                            height:
                                MediaQuery.textScalerOf(context).scale(13) + 28,
                            child: Row(
                              children: [
                                for (final tag in widget.tags)
                                  Padding(
                                    key: widget.selectedTag == tag
                                        ? _selectedChip
                                        : null,
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Tooltip(
                                      message: tag,
                                      child: _chip(
                                        context,
                                        label: tag,
                                        labelWidth: labelWidth,
                                        selected: widget.selectedTag == tag,
                                        onTap: () => widget.onTagSelected(
                                          widget.selectedTag == tag
                                              ? null
                                              : tag,
                                        ),
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
              ),
            ),
          ),
          if (_overflow)
            _scrollArrow(
              key: const ValueKey('inspiration-tags-right'),
              tooltip: '向右查看更多标签',
              icon: Icons.chevron_right,
              enabled: _canScrollForward,
              direction: 1,
            ),
        ],
      );
    },
  );

  Widget _scrollArrow({
    required Key key,
    required String tooltip,
    required IconData icon,
    required bool enabled,
    required int direction,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: enabled ? () => _scrollBy(direction) : null,
    style: IconButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: const Size(28, 36),
      maximumSize: const Size(28, 36),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    icon: Icon(icon, size: 20),
  );

  Widget _chip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
    double? labelWidth,
  }) {
    final scheme = context.scheme;
    return ChoiceChip(
      label: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: labelWidth ?? double.infinity),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      avatar: icon == null ? null : Icon(icon, size: 15),
      iconTheme: IconThemeData(
        color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
      ),
      selected: selected,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      shape: const StadiumBorder(),
      labelStyle: context.texts.labelMedium!.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
      ),
      selectedColor: scheme.primary,
      backgroundColor: scheme.surfaceContainerHigh,
      side: BorderSide.none,
      showCheckmark: false,
    );
  }
}

class _TagPicker extends StatefulWidget {
  const _TagPicker({required this.tags, required this.selectedTag});

  final List<String> tags;
  final String? selectedTag;

  @override
  State<_TagPicker> createState() => _TagPickerState();
}

class _TagPickerState extends State<_TagPicker> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _searchTags(String value) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() => _query = value.trim().toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final hits = widget.tags
        .where((tag) => tag.toLowerCase().contains(_query))
        .toList();
    return Column(
      key: const ValueKey('inspiration-tag-picker'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Expanded(child: Text('按标签筛选', style: context.texts.titleSmall)),
              const CloseButton(),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            key: const ValueKey('inspiration-tag-search'),
            controller: _search,
            autofocus: true,
            onChanged: _searchTags,
            onSubmitted: (value) {
              final query = value.trim().toLowerCase();
              final index = widget.tags.indexWhere(
                (tag) => tag.toLowerCase().contains(query),
              );
              if (index >= 0) Navigator.pop(context, (tag: widget.tags[index]));
            },
            decoration: InputDecoration(
              hintText: '搜索标签…',
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      onPressed: () {
                        _search.clear();
                        _searchTags('');
                      },
                      icon: const Icon(Icons.close, size: 18),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        ListTile(
          key: const ValueKey('inspiration-tag-clear'),
          dense: true,
          title: const Text('不按标签筛选'),
          onTap: () => Navigator.pop(context, (tag: null)),
        ),
        const Divider(height: 1),
        Flexible(
          child: hits.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('没有匹配的标签', textAlign: TextAlign.center),
                )
              : Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: ListView.builder(
                    key: const ValueKey('inspiration-tag-list'),
                    controller: _scroll,
                    primary: false,
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: hits.length,
                    itemBuilder: (context, index) {
                      final tag = hits[index];
                      final selected = tag == widget.selectedTag;
                      return ListTile(
                        dense: true,
                        selected: selected,
                        leading: const Icon(Icons.sell_outlined, size: 18),
                        title: Text(tag),
                        trailing: selected
                            ? const Icon(Icons.check, size: 18)
                            : null,
                        onTap: () => Navigator.pop(context, (tag: tag)),
                      );
                    },
                  ),
                ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
