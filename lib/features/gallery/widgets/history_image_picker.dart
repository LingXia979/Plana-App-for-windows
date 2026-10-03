import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../gallery_state.dart';
import '../models.dart';
import 'gallery_drag_selection.dart';
import 'gallery_image_tile.dart';

/// Selecting history never changes the gallery's active image or generation.
/// A null allowedIds means all history; an empty set means an empty scope.
Future<List<ResultImage>?> showHistoryImagePicker(
  BuildContext context, {
  bool multiple = false,
  Set<String>? allowedIds,
  String title = '从历史选择',
}) => showDialog<List<ResultImage>>(
  context: context,
  builder: (_) => Dialog(
    key: const ValueKey('history-image-picker'),
    constraints: const BoxConstraints(maxWidth: 780, maxHeight: 580),
    insetPadding: const EdgeInsets.all(24),
    clipBehavior: Clip.antiAlias,
    child: SizedBox(
      width: 780,
      height: 580,
      child: _HistoryImagePicker(
        multiple: multiple,
        allowedIds: allowedIds == null ? null : Set.unmodifiable(allowedIds),
        title: title,
      ),
    ),
  ),
);

class _HistoryImagePicker extends ConsumerStatefulWidget {
  const _HistoryImagePicker({
    required this.multiple,
    required this.allowedIds,
    required this.title,
  });

  final bool multiple;
  final Set<String>? allowedIds;
  final String title;

  @override
  ConsumerState<_HistoryImagePicker> createState() =>
      _HistoryImagePickerState();
}

class _HistoryImagePickerState extends ConsumerState<_HistoryImagePicker> {
  final _selected = <String>{};
  final _scroll = ScrollController();
  final _dragSelection = GlobalKey<GalleryDragSelectionState>();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _pick(ResultImage item) {
    if (!widget.multiple) {
      Navigator.pop(context, [item]);
      return;
    }
    setState(() {
      if (!_selected.add(item.id)) _selected.remove(item.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = ref
        .watch(galleryProvider)
        .results
        .where((item) => widget.allowedIds?.contains(item.id) ?? true)
        .toList();
    final selected = items
        .where((item) => _selected.contains(item.id))
        .toList();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.history, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(widget.title, style: context.texts.titleLarge),
              ),
              const CloseButton(),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '共 ${items.length} 张 · ${widget.multiple ? '已选 ${selected.length} 张 · 点击或拖动勾选' : '点击选择图片'}',
            style: context.texts.bodySmall,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: GalleryDragSelection(
              key: _dragSelection,
              enabled: widget.multiple && items.isNotEmpty,
              scrollController: _scroll,
              order: [for (final item in items) item.id],
              selected: _selected,
              onChanged: (next) => setState(() {
                _selected
                  ..clear()
                  ..addAll(next);
              }),
              child: items.isEmpty
                  ? Center(
                      child: Text(
                        widget.allowedIds == null
                            ? '暂无历史图片，生成的作品会显示在这里'
                            : '这个图库暂无图片',
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) => GridView.builder(
                        key: const PageStorageKey('metadata-history-grid'),
                        controller: _scroll,
                        padding: EdgeInsets.zero,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: math.max(
                            2,
                            (constraints.maxWidth / 190).floor(),
                          ),
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final item = items[index];
                          return MetaData(
                            metaData: item.id,
                            child: GalleryImageTile(
                              key: ValueKey('history-image-${item.id}'),
                              result: item,
                              fit: BoxFit.contain,
                              selecting: widget.multiple,
                              mouseDragSelect: widget.multiple,
                              picked: _selected.contains(item.id),
                              onTap: () => _pick(item),
                              longPressDuration: gallerySelectionHold,
                              onLongPress: widget.multiple
                                  ? (_) {
                                      if (!(_dragSelection.currentState
                                              ?.beginHold(item.id) ??
                                          false)) {
                                        setState(() => _selected.add(item.id));
                                      }
                                    }
                                  : null,
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ),
          if (widget.multiple) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton(
                  key: const ValueKey('history-select-all'),
                  onPressed: items.isEmpty
                      ? null
                      : () => setState(() {
                          if (selected.length == items.length) {
                            _selected.clear();
                          } else {
                            _selected.addAll(items.map((item) => item.id));
                          }
                        }),
                  child: Text(
                    items.isNotEmpty && selected.length == items.length
                        ? '取消全选'
                        : '全选',
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  key: const ValueKey('history-confirm-selection'),
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.pop(context, selected),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text('添加（${selected.length} 张）'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
