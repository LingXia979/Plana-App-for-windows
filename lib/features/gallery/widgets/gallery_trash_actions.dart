import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/store/app_stores.dart';
import '../../generate/widgets/common.dart' show confirmDialog, hintSnack;
import '../gallery_state.dart';

Future<int> restoreGalleryTrash(
  BuildContext context,
  Iterable<String> ids,
) async {
  final gallery = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(galleryProvider.notifier);
  try {
    final count = await gallery.restoreTrash(ids.toList());
    if (context.mounted) {
      hintSnack(context, '已恢复 $count 张', icon: Icons.restore);
    }
    return count;
  } catch (error) {
    if (context.mounted) {
      hintSnack(
        context,
        error is StateError ? error.message.toString() : '恢复更改尚未保存，请检查磁盘后重试',
        icon: Icons.error_outline,
      );
    }
    return 0;
  }
}

Future<Set<String>> moveGalleryImagesToTrash(
  BuildContext context,
  List<String> ids,
) async {
  final gallery = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(galleryProvider.notifier);
  final moved = await gallery.deleteResults(ids);
  if (context.mounted) {
    hintSnack(
      context,
      moved.isEmpty ? '未能完成删除，图片仍保留' : '已移入回收站 ${moved.length} 张',
      icon: Icons.delete_outline,
      actionLabel: moved.isEmpty ? null : '撤销',
      onAction: moved.isEmpty
          ? null
          : () => unawaited(restoreGalleryTrash(context, moved)),
    );
  }
  return moved;
}

Future<Set<String>> purgeGalleryTrash(
  BuildContext context,
  Iterable<String> ids,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final want = ids.toSet();
  final present = container
      .read(galleryProvider)
      .trash
      .where((t) => want.contains(t.image.id))
      .map((t) => t.image.id)
      .toList();
  if (present.isEmpty) return {};
  if (!await confirmDialog(
        context,
        title: '彻底删除 ${present.length} 张作品？',
        message: '将删除原图、生成参数和应用管理的作品文件，此操作不可恢复。',
        confirmLabel: '彻底删除',
      ) ||
      !context.mounted) {
    return {};
  }
  try {
    final removed = await container
        .read(galleryProvider.notifier)
        .purgeTrash(present);
    if (context.mounted) {
      hintSnack(
        context,
        '已彻底删除 ${removed.length} 张${removed.length < present.length ? '，其余图片仍在回收站' : ''}',
        icon: Icons.delete_forever_outlined,
      );
    }
    return removed;
  } catch (_) {
    if (context.mounted) {
      hintSnack(context, '清理尚未完成，请检查磁盘后重试', icon: Icons.error_outline);
    }
    return {};
  }
}

Future<void> showGalleryTrashMenu(BuildContext context, Offset position) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  final local = overlay.globalToLocal(position);
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      local & Size.zero,
      Offset.zero & overlay.size,
    ),
    items: const [
      PopupMenuItem(value: 'restore', child: Text('全部恢复')),
      PopupMenuItem(value: 'purge', child: Text('清空回收站')),
    ],
  );
  if (!context.mounted || choice == null) return;
  final ids = container
      .read(galleryProvider)
      .trash
      .map((t) => t.image.id)
      .toList();
  if (choice == 'restore') {
    await restoreGalleryTrash(context, ids);
  } else {
    await purgeGalleryTrash(context, ids);
  }
}

Future<void> toggleGalleryFavorite(BuildContext context, String id) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final image = container
      .read(galleryProvider)
      .results
      .where((r) => r.id == id)
      .firstOrNull;
  if (image == null) return;
  final on = !image.favorite;
  container.read(galleryProvider.notifier).setFavorite(id, on);
  try {
    await container.read(appStoresProvider).gallery.flushIndex();
  } catch (_) {
    if (context.mounted) {
      hintSnack(context, '收藏更改尚未保存，请检查磁盘后重试', icon: Icons.error_outline);
    }
    return;
  }
  if (!context.mounted) return;
  hintSnack(
    context,
    on ? '已收藏' : '已取消收藏',
    icon: on ? Icons.favorite : Icons.favorite_border,
    actionLabel: on ? null : '撤销',
    onAction: on
        ? null
        : () {
            container.read(galleryProvider.notifier).setFavorite(id, true);
            unawaited(
              container
                  .read(appStoresProvider)
                  .gallery
                  .flushIndex()
                  .catchError((Object _) {}),
            );
          },
  );
}
