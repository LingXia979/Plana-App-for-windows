import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../generate/widgets/common.dart' show hintSnack;
import '../gallery_state.dart';
import 'album_models.dart';
import 'album_state.dart';
import 'album_ui.dart';

Future<GalleryTransferChange?> showGalleryTransfer(
  BuildContext context,
  Set<String> images, {
  required bool copy,
  String? sourceAlbum,
}) async {
  final notifier = ProviderScope.containerOf(
    context,
  ).read(albumsProvider.notifier);
  final change = await showDialog<GalleryTransferChange>(
    context: context,
    builder: (_) => _TransferDialog(
      images: Set.of(images),
      copy: copy,
      sourceAlbum: sourceAlbum,
    ),
  );
  if (change != null && context.mounted) {
    hintSnack(
      context,
      change.count == 0
          ? '所选图片已在目标图库中'
          : '已${copy ? '复制' : '移动'} ${change.count} 张',
      icon: copy ? Icons.copy_outlined : Icons.drive_file_move_outline,
      actionLabel: change.count == 0 ? null : '撤销',
      onAction: change.count == 0
          ? null
          : () async {
              try {
                await notifier.undoTransfer(change);
              } catch (e) {
                if (context.mounted) albumError(context, e);
              }
            },
    );
  }
  return change;
}

class _TransferDialog extends ConsumerStatefulWidget {
  const _TransferDialog({
    required this.images,
    required this.copy,
    this.sourceAlbum,
  });
  final Set<String> images;
  final bool copy;
  final String? sourceAlbum;

  @override
  ConsumerState<_TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends ConsumerState<_TransferDialog> {
  final _targets = <String>{};
  bool _busy = false;
  String get _verb => widget.copy ? '复制' : '移动';

  Future<void> _submit() async {
    if (_targets.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final change = await ref
          .read(albumsProvider.notifier)
          .transfer(
            widget.images,
            Set.of(_targets),
            copy: widget.copy,
            sourceAlbum: widget.sourceAlbum,
          );
      if (mounted) Navigator.pop(context, change);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        albumError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(albumsProvider);
    final count = ref
        .watch(galleryProvider)
        .results
        .where(
          (r) =>
              widget.images.contains(r.id) &&
              data.contains(widget.sourceAlbum, r.id),
        )
        .length;
    final targets = data.albums
        .where((a) => a.id != widget.sourceAlbum)
        .toList();
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        key: const ValueKey('gallery-transfer-dialog'),
        title: Text('$_verb到图库'),
        content: SizedBox(
          width: 460,
          height: 330,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('已选 $count 张'),
              const SizedBox(height: 8),
              Text(
                widget.copy
                    ? '可选择多个图库。每个目标各保存一份独立副本，全部作品也会显示新增图片。'
                    : widget.sourceAlbum == null
                    ? '图片将从原有图库移至目标图库，全部作品仍会显示。'
                    : '图片将从本图库移至目标图库，其他图库中的副本保留。',
              ),
              const SizedBox(height: 12),
              Expanded(
                child: targets.isEmpty
                    ? const Center(child: Text('还没有其他图库，可以先新建一个'))
                    : ListView.builder(
                        itemCount: targets.length,
                        itemBuilder: (_, i) {
                          final album = targets[i];
                          return ListTile(
                            key: ValueKey(
                              'gallery-transfer-target-${album.id}',
                            ),
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(album.name),
                            selected: _targets.contains(album.id),
                            trailing: widget.copy
                                ? Icon(
                                    _targets.contains(album.id)
                                        ? Icons.check_box
                                        : Icons.check_box_outline_blank,
                                  )
                                : _targets.contains(album.id)
                                ? const Icon(Icons.check)
                                : null,
                            onTap: _busy
                                ? null
                                : () => setState(() {
                                    if (!widget.copy) _targets.clear();
                                    if (!_targets.add(album.id)) {
                                      _targets.remove(album.id);
                                    }
                                  }),
                          );
                        },
                      ),
              ),
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final id = await showAlbumName(context);
                        if (id != null && mounted) {
                          setState(() {
                            if (!widget.copy) _targets.clear();
                            _targets.add(id);
                          });
                        }
                      },
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('新建图库'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('gallery-transfer-submit'),
            onPressed:
                !_busy &&
                    count > 0 &&
                    _targets.isNotEmpty &&
                    _targets.every(data.exists)
                ? _submit
                : null,
            child: Text(
              _busy
                  ? '保存中…'
                  : widget.copy && _targets.isNotEmpty
                  ? '复制 ($count × ${_targets.length} 个图库)'
                  : '$_verb ($count)',
            ),
          ),
        ],
      ),
    );
  }
}
