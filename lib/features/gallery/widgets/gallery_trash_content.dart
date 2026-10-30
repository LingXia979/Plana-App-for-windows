import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../gallery_dates.dart';
import '../gallery_state.dart';
import '../models.dart';
import 'gallery_drag_selection.dart';
import 'gallery_image_tile.dart';
import 'gallery_trash_actions.dart';
import 'justified_grid.dart';
import 'result_thumb.dart';

Future<void> showGalleryTrash(BuildContext context) => showDialog<void>(
  context: context,
  builder: (dialogContext) => Dialog(
    insetPadding: const EdgeInsets.all(24),
    child: SizedBox(
      width: 1000,
      height: 720,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: GalleryTrashContent(onBack: () => Navigator.pop(dialogContext)),
      ),
    ),
  ),
);

class GalleryTrashContent extends ConsumerStatefulWidget {
  const GalleryTrashContent({super.key, required this.onBack});
  final VoidCallback onBack;
  @override
  ConsumerState<GalleryTrashContent> createState() =>
      _GalleryTrashContentState();
}

class _GalleryTrashContentState extends ConsumerState<GalleryTrashContent> {
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _drag = GlobalKey<GalleryDragSelectionState>();
  final _picked = <String>{};
  bool _selecting = false, _busy = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(galleryProvider.notifier).purgeExpiredTrash());
      }
    });
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      unawaited(ref.read(galleryProvider.notifier).purgeExpiredTrash());
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _exitSelection() {
    _drag.currentState?.cancel();
    setState(() {
      _selecting = false;
      _picked.clear();
    });
  }

  Future<void> _act(Iterable<String> ids, {required bool restore}) async {
    if (_busy) return;
    final snapshot = ids.toList();
    setState(() => _busy = true);
    if (restore) {
      await restoreGalleryTrash(context, snapshot);
    } else {
      await purgeGalleryTrash(context, snapshot);
    }
    if (mounted) {
      setState(() => _busy = false);
      _exitSelection();
    }
  }

  Future<void> _preview(ResultImage image) async {
    if (_busy) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('回收站预览'),
        content: SizedBox(
          width: math.min(560, MediaQuery.sizeOf(dialogContext).width * .7),
          height: math.min(480, MediaQuery.sizeOf(dialogContext).height * .55),
          child: Consumer(
            builder: (_, ref, _) {
              final bytes =
                  image.bytes ??
                  ref.watch(galleryImageProvider(image.id)).value;
              return bytes == null
                  ? ResultThumb(
                      result: image,
                      width: 360,
                      height: 400,
                      fit: BoxFit.contain,
                    )
                  : Image.memory(bytes, fit: BoxFit.contain);
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () async {
              await _act([image.id], restore: false);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('彻底删除'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await _act([image.id], restore: true);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            icon: const Icon(Icons.restore),
            label: const Text('恢复'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trash = ref.watch(galleryProvider.select((s) => s.trash));
    final ids = trash.map((t) => t.image.id).toList();
    _picked.retainAll(ids);
    final now = DateTime.now();
    final groups = <int, List<TrashedImage>>{};
    for (final t in trash) {
      groups.putIfAbsent(galleryDayKey(t.deletedAt), () => []).add(t);
    }
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    final order = [
      for (final day in days)
        for (final t in groups[day]!) t.image.id,
    ];
    return Focus(
      autofocus: true,
      focusNode: _focus,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          if (_selecting) {
            _exitSelection();
          } else if (!_busy) {
            widget.onBack();
          }
          return KeyEventResult.handled;
        }
        if (!_busy &&
            HardwareKeyboard.instance.isControlPressed &&
            event.logicalKey == LogicalKeyboardKey.keyA) {
          setState(() {
            _selecting = true;
            _picked.addAll(ids);
          });
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        key: const ValueKey('gallery-trash-content'),
        children: [
          Row(
            children: [
              IconButton(
                tooltip: '返回图库',
                onPressed: _busy ? null : widget.onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              const Expanded(
                child: Text(
                  '回收站',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ),
              Text('${trash.length} 张'),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                '保留 $kTrashKeepDays 天，到期自动彻底删除。恢复后回到原位置和仍存在的图库。',
                style: TextStyle(color: context.scheme.outline),
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              TextButton.icon(
                key: const ValueKey('trash-select'),
                onPressed: _busy || trash.isEmpty
                    ? null
                    : () {
                        if (_selecting) {
                          _exitSelection();
                        } else {
                          setState(() => _selecting = true);
                        }
                      },
                icon: const Icon(Icons.checklist),
                label: Text(_selecting ? '取消选择' : '多选'),
              ),
              if (_selecting)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _picked.addAll(ids)),
                  child: const Text('全选'),
                ),
              FilledButton.tonalIcon(
                key: const ValueKey('trash-restore'),
                onPressed:
                    _busy || (_selecting ? _picked.isEmpty : trash.isEmpty)
                    ? null
                    : () => _act(_selecting ? _picked : ids, restore: true),
                icon: const Icon(Icons.restore),
                label: Text(_selecting ? '恢复 (${_picked.length})' : '全部恢复'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('trash-purge'),
                onPressed:
                    _busy || (_selecting ? _picked.isEmpty : trash.isEmpty)
                    ? null
                    : () => _act(_selecting ? _picked : ids, restore: false),
                icon: const Icon(Icons.delete_forever_outlined),
                label: Text(_selecting ? '彻底删除 (${_picked.length})' : '清空回收站'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: trash.isEmpty
                ? const Center(child: Text('回收站为空'))
                : LayoutBuilder(
                    builder: (_, size) {
                      final cols = (size.maxWidth / 190).floor().clamp(1, 6);
                      return GalleryDragSelection(
                        key: _drag,
                        enabled: _selecting && !_busy,
                        handleEscape: false,
                        scrollController: _scroll,
                        order: order,
                        selected: _picked,
                        onChanged: (picked) => setState(() {
                          _picked
                            ..clear()
                            ..addAll(picked);
                        }),
                        child: CustomScrollView(
                          controller: _scroll,
                          slivers: [
                            for (final day in days) ...[
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    16,
                                    12,
                                    8,
                                  ),
                                  child: Text(
                                    '${galleryDayLabel(day, now)}删除 · 剩余 ${(kTrashKeepDays - galleryDaysSince(groups[day]!.first.deletedAt, now)).clamp(0, kTrashKeepDays)} 天',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                sliver: SliverGrid(
                                  gridDelegate: JustifiedGridDelegate(
                                    [for (final t in groups[day]!) t.image],
                                    cols: cols,
                                    gap: 6,
                                    inset: 10,
                                  ),
                                  delegate: SliverChildBuilderDelegate((
                                    _,
                                    index,
                                  ) {
                                    final image = groups[day]![index].image;
                                    return MetaData(
                                      metaData: image.id,
                                      child: GalleryImageTile(
                                        key: ValueKey(
                                          'trash-image-${image.id}',
                                        ),
                                        result: image,
                                        fit: BoxFit.contain,
                                        showTime: false,
                                        selecting: _selecting,
                                        picked: _picked.contains(image.id),
                                        mouseDragSelect: true,
                                        onTap: () {
                                          if (_busy) return;
                                          if (_selecting) {
                                            setState(() {
                                              if (!_picked.remove(image.id)) {
                                                _picked.add(image.id);
                                              }
                                            });
                                          } else {
                                            unawaited(_preview(image));
                                          }
                                        },
                                        onSecondaryTap: (_) => _preview(image),
                                        longPressDuration: gallerySelectionHold,
                                        onLongPress: (_) {
                                          if (_busy) return;
                                          _focus.requestFocus();
                                          setState(() => _selecting = true);
                                          if (!(_drag.currentState?.beginHold(
                                                image.id,
                                              ) ??
                                              false)) {
                                            setState(
                                              () => _picked.add(image.id),
                                            );
                                          }
                                        },
                                      ),
                                    );
                                  }, childCount: groups[day]!.length),
                                ),
                              ),
                            ],
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 12),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
