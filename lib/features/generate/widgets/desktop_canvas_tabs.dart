import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../canvas_state.dart';
import 'common.dart';

/// A compact canvas switcher above the desktop prompt controls.
class DesktopCanvasTabs extends ConsumerStatefulWidget {
  const DesktopCanvasTabs({super.key});

  @override
  ConsumerState<DesktopCanvasTabs> createState() => DesktopCanvasTabsState();
}

class DesktopCanvasTabsState extends ConsumerState<DesktopCanvasTabs> {
  final _scroll = ScrollController(debugLabel: 'Desktop canvas tabs');
  final _tabsFocus = FocusNode(debugLabel: 'Canvas commands');
  final _nameFocus = FocusNode(debugLabel: 'Canvas name');
  final _name = TextEditingController();
  final _menu = MenuController();
  final _menuAnchor = GlobalKey();
  String? _renamingId;
  bool _confirmingDelete = false;
  List<double> _extents = const [];
  int _activeIndex = 0;
  double? _viewportWidth;
  bool _revealScheduled = false;
  int _revealGeneration = 0;

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(_nameFocusChanged);
  }

  void _nameFocusChanged() {
    if (!_nameFocus.hasFocus) _finishRename();
  }

  @override
  void dispose() {
    _nameFocus.removeListener(_nameFocusChanged);
    _nameFocus.dispose();
    _name.dispose();
    _tabsFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _select(String id) {
    _finishRename();
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(canvasWorkspaceProvider.notifier).select(id);
    _tabsFocus.requestFocus();
    _scheduleReveal();
  }

  void createCanvas({bool duplicate = false}) {
    _menu.close();
    _finishRename();
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(canvasWorkspaceProvider.notifier).create(duplicate: duplicate);
    _tabsFocus.requestFocus();
    _scheduleReveal();
  }

  void renameActiveCanvas() {
    _menu.close();
    final workspace = ref.read(canvasWorkspaceProvider);
    if (workspace.activeId == workspace.defaultId || _renamingId != null) {
      return;
    }
    _name.value = TextEditingValue(
      text: workspace.active.name,
      selection: TextSelection(
        baseOffset: 0,
        extentOffset: workspace.active.name.length,
      ),
    );
    setState(() => _renamingId = workspace.activeId);
    _scheduleReveal();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _renamingId != workspace.activeId) return;
      _nameFocus.requestFocus();
      _name.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _name.text.length,
      );
    });
  }

  void _finishRename({bool save = true, bool focusTabs = false}) {
    final id = _renamingId;
    if (id == null) return;
    setState(() => _renamingId = null);
    if (save) ref.read(canvasWorkspaceProvider.notifier).rename(id, _name.text);
    if (focusTabs) _tabsFocus.requestFocus();
  }

  Future<void> deleteActiveCanvas() =>
      _deleteCanvas(ref.read(canvasWorkspaceProvider).activeId);

  Future<void> _deleteCanvas(String id) async {
    _menu.close();
    final workspace = ref.read(canvasWorkspaceProvider);
    if (id == workspace.defaultId || _confirmingDelete) return;
    _finishRename();
    final canvas = ref.read(canvasWorkspaceProvider).find(id);
    if (canvas == null) return;
    _confirmingDelete = true;
    final ok = await confirmDialog(
      context,
      title: '删除「${canvas.name}」？',
      message: '移除这张画布的提示词和参数，已生成的图片会保留。',
      confirmLabel: '删除',
    );
    _confirmingDelete = false;
    if (!mounted) return;
    _tabsFocus.requestFocus();
    if (!ok) return;
    final canvases = ref.read(canvasWorkspaceProvider.notifier);
    final removed = canvases.remove(canvas.id);
    if (removed == null) return;
    hintSnack(
      context,
      '已删除画布',
      actionLabel: '撤销',
      onAction: () => canvases.restore(
        removed.canvas,
        removed.index,
        activate: removed.wasActive,
      ),
    );
  }

  void _showMenu(String id, Offset position) {
    _select(id);
    _menu.close();
    final box = _menuAnchor.currentContext!.findRenderObject()! as RenderBox;
    _menu.open(position: box.globalToLocal(position));
  }

  void _showSharedInfo() {
    _menu.close();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('画布与参考图'),
        content: const Text(
          '每张画布分别保存提示词、角色、预设和采样参数。\n\nVibe、角色参考、图生图、重绘和 LoRA 在画布之间共享。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _nameEditor(TextStyle style) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          _finishRename(save: false, focusTabs: true),
      const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
          _finishRename(focusTabs: true),
    },
    child: TextSelectionTheme(
      data: TextSelectionTheme.of(
        context,
      ).copyWith(selectionColor: context.scheme.primary.withValues(alpha: .30)),
      child: TextField(
        key: const ValueKey('desktop-canvas-name-editor'),
        controller: _name,
        focusNode: _nameFocus,
        style: style.copyWith(color: context.scheme.onSurface),
        maxLength: kCanvasNameMax,
        maxLengthEnforcement: MaxLengthEnforcement.truncateAfterCompositionEnds,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          isDense: true,
          counterText: '',
          contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 7),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
        ),
        onSubmitted: (_) => _finishRename(focusTabs: true),
        onTapOutside: (_) => _finishRename(),
      ),
    ),
  );

  void _scheduleReveal() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    final generation = ++_revealGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted ||
          generation != _revealGeneration ||
          !_scroll.hasClients ||
          _extents.isEmpty) {
        return;
      }
      final position = _scroll.position;
      final left =
          10.0 + _extents.take(_activeIndex).fold(0.0, (a, b) => a + b);
      final right = left + _extents[_activeIndex];
      final target = left < position.pixels
          ? left
          : right > position.pixels + position.viewportDimension
          ? right - position.viewportDimension
          : position.pixels;
      if ((target - position.pixels).abs() < .5) return;
      _scroll
          .animateTo(
            target.clamp(0.0, _maxOffset),
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          )
          .then((_) {
            // Lazy, variable-width tabs can correct their scroll extent during the
            // animation. Check once they settle so long active names stay visible.
            if (mounted && generation == _revealGeneration) _scheduleReveal();
          });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  double get _maxOffset =>
      (20.0 +
              _extents.fold(0.0, (a, b) => a + b) -
              _scroll.position.viewportDimension)
          .clamp(0.0, double.infinity);

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    _revealGeneration++;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    final target = (_scroll.offset + delta).clamp(0.0, _maxOffset);
    if (target == _scroll.offset) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => _scroll.jumpTo(target),
    );
  }

  @override
  Widget build(BuildContext context) {
    final workspace = ref.watch(canvasWorkspaceProvider);
    final canvases = ref.read(canvasWorkspaceProvider.notifier);
    final labelStyle = context.texts.labelLarge!;
    ref.listen(canvasWorkspaceProvider.select((w) => w.activeId), (_, id) {
      if (_renamingId == null || _renamingId == id) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _renamingId != null && _renamingId != id) {
          _finishRename();
        }
      });
    });
    // Use the same measured widths for layout and revealing offscreen tabs.
    final extents = [
      for (final canvas in workspace.canvases)
        _tabExtent(
          context,
          canvas.name,
          labelStyle,
          closable: canvas.id != workspace.defaultId,
        ),
    ];
    final activeIndex = workspace.canvases.indexWhere(
      (canvas) => canvas.id == workspace.activeId,
    );
    if (activeIndex != _activeIndex || !listEquals(extents, _extents)) {
      _activeIndex = activeIndex;
      _extents = extents;
      _scheduleReveal();
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f2, includeRepeats: false):
            renameActiveCanvas,
        const SingleActivator(
          LogicalKeyboardKey.keyN,
          control: true,
          shift: true,
          includeRepeats: false,
        ): createCanvas,
        const SingleActivator(
          LogicalKeyboardKey.keyD,
          control: true,
          includeRepeats: false,
        ): deleteActiveCanvas,
      },
      child: Focus(
        focusNode: _tabsFocus,
        child: MenuAnchor(
          key: _menuAnchor,
          controller: _menu,
          childFocusNode: _tabsFocus,
          menuChildren: [
            MenuItemButton(
              onPressed: createCanvas,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyN,
                control: true,
                shift: true,
              ),
              child: const Text('新建画布'),
            ),
            MenuItemButton(
              onPressed: () => createCanvas(duplicate: true),
              child: const Text('复制当前画布'),
            ),
            MenuItemButton(
              onPressed: workspace.activeId == workspace.defaultId
                  ? null
                  : renameActiveCanvas,
              shortcut: const SingleActivator(LogicalKeyboardKey.f2),
              child: const Text('重命名'),
            ),
            MenuItemButton(
              onPressed: workspace.activeId == workspace.defaultId
                  ? null
                  : deleteActiveCanvas,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyD,
                control: true,
              ),
              child: const Text('删除当前画布'),
            ),
            const Divider(height: 8),
            MenuItemButton(
              onPressed: _showSharedInfo,
              child: const Text('画布与参考图'),
            ),
          ],
          child: SizedBox(
            key: const ValueKey('desktop-canvas-tabs'),
            height: 44,
            child: Row(
              children: [
                Expanded(
                  child: NotificationListener<ScrollMetricsNotification>(
                    onNotification: (notification) {
                      if (_viewportWidth !=
                          notification.metrics.viewportDimension) {
                        _viewportWidth = notification.metrics.viewportDimension;
                        _scheduleReveal();
                      }
                      return false;
                    },
                    child: Listener(
                      onPointerSignal: _wheel,
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(
                          context,
                        ).copyWith(scrollbars: false),
                        child: Scrollbar(
                          controller: _scroll,
                          thumbVisibility: true,
                          interactive: true,
                          thickness: 3,
                          radius: const Radius.circular(2),
                          scrollbarOrientation: ScrollbarOrientation.bottom,
                          child: ReorderableListView.builder(
                            scrollController: _scroll,
                            scrollDirection: Axis.horizontal,
                            buildDefaultDragHandles: false,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            itemExtentBuilder: (index, _) => extents[index],
                            // Build an inert preview: moving a visible Tooltip's
                            // OverlayPortal into the drag overlay can mutate layout.
                            proxyDecorator: (_, index, animation) => dragProxy(
                              IgnorePointer(
                                key: const ValueKey(
                                  'desktop-canvas-drag-preview',
                                ),
                                child: _CanvasTab(
                                  name: workspace.canvases[index].name,
                                  selected: true,
                                  index: index,
                                  labelStyle: labelStyle,
                                  onSelect: () {},
                                  preview: true,
                                ),
                              ),
                              index,
                              animation,
                            ),
                            onReorderItem: canvases.reorder,
                            onReorderStart: (index) {
                              Tooltip.dismissAllToolTips();
                              _select(workspace.canvases[index].id);
                            },
                            itemCount: workspace.canvases.length,
                            itemBuilder: (context, index) {
                              final canvas = workspace.canvases[index];
                              return _CanvasTab(
                                key: ValueKey('desktop-canvas-${canvas.id}'),
                                name: canvas.name,
                                selected: canvas.id == workspace.activeId,
                                index: index,
                                labelStyle: labelStyle,
                                onSelect: () => _select(canvas.id),
                                onContextMenu: (position) =>
                                    _showMenu(canvas.id, position),
                                onClose: () => _deleteCanvas(canvas.id),
                                closeKey: ValueKey(
                                  'desktop-canvas-close-${canvas.id}',
                                ),
                                editor: canvas.id == _renamingId
                                    ? _nameEditor(labelStyle)
                                    : null,
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (workspace.canvases.length > 1)
                  SizedBox(
                    width: 36,
                    child: PopupMenuButton<String>(
                      key: const ValueKey('desktop-canvas-picker'),
                      tooltip: '切换画布',
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.expand_more, size: 20),
                      initialValue: workspace.activeId,
                      onSelected: _select,
                      itemBuilder: (_) => [
                        for (final canvas in workspace.canvases)
                          CheckedPopupMenuItem(
                            value: canvas.id,
                            checked: canvas.id == workspace.activeId,
                            child: Text(
                              canvas.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                SizedBox(
                  width: 36,
                  child: IconButton(
                    key: const ValueKey('desktop-canvas-new'),
                    tooltip: '新建画布 (Ctrl+Shift+N)',
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.add, size: 20),
                    onPressed: createCanvas,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CanvasTab extends StatelessWidget {
  const _CanvasTab({
    super.key,
    required this.name,
    required this.selected,
    required this.index,
    required this.labelStyle,
    required this.onSelect,
    this.onContextMenu,
    this.onClose,
    this.closeKey,
    this.editor,
    this.preview = false,
  });

  final String name;
  final bool selected;
  final int index;
  final TextStyle labelStyle;
  final VoidCallback onSelect;
  final ValueChanged<Offset>? onContextMenu;
  final VoidCallback? onClose;
  final Key? closeKey;
  final Widget? editor;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final label = TextButton(
      onPressed: onSelect,
      style: TextButton.styleFrom(
        textStyle: labelStyle,
        foregroundColor: selected
            ? context.scheme.primary
            : context.scheme.onSurfaceVariant,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    Widget content = editor != null
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: editor,
          )
        : preview
        ? label
        : Tooltip(message: name, child: label);
    if (!preview && editor == null) {
      content = ReorderableDragStartListener(
        index: index,
        enabled: index != 0,
        child: content,
      );
    }
    final body = Padding(
      padding: const EdgeInsets.only(right: 4, top: 4, bottom: 4),
      child: Material(
        color: selected
            ? context.scheme.primaryContainer
            : context.scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        child: Row(
          children: [
            Expanded(child: content),
            if (index != 0)
              SizedBox(
                width: 24,
                height: 36,
                child: preview
                    ? const Icon(Icons.close, size: 16)
                    : IconButton(
                        key: closeKey,
                        tooltip: '关闭画布「$name」',
                        padding: EdgeInsets.zero,
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        iconSize: 16,
                        onPressed: onClose,
                        icon: const Icon(Icons.close),
                      ),
              ),
          ],
        ),
      ),
    );
    if (preview || editor != null) return body;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) =>
          onContextMenu?.call(details.globalPosition),
      child: body,
    );
  }
}

double _tabExtent(
  BuildContext context,
  String name,
  TextStyle style, {
  required bool closable,
}) {
  final text = TextPainter(
    text: TextSpan(text: name, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = text.width.clamp(36.0, 130.0) + 20 + (closable ? 24 : 0) + 4;
  text.dispose();
  return width;
}
