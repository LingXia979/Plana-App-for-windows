import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/theme/app_theme.dart';
import '../gallery/albums/album_cover_dialog.dart';
import '../gallery/albums/album_deletion.dart';
import '../gallery/albums/album_state.dart';
import '../gallery/albums/album_ui.dart' show albumError, showAlbumName;
import '../gallery/gallery_state.dart';
import '../generate/generation_controller.dart';
import '../generate/widgets/common.dart' show confirmDialog, hintSnack;
import 'desktop_library_state.dart';

enum _AlbumAction { rename, cover, delete }

/// One management flow for the overview and the library picker. Opening this
/// menu, renaming, and choosing a cover never selects a different library.
class DesktopAlbumMenuController {
  bool _busy = false;

  Future<void> show(
    BuildContext context,
    String? albumId,
    Offset position,
  ) async {
    if (_busy) return;
    _busy = true;
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final readOnly = container.read(appStoresProvider).albums.readOnly;
      final canRename = albumId != null && !readOnly;
      final canDelete =
          !readOnly &&
          (albumId != null ||
              container.read(galleryProvider).results.isNotEmpty);
      final overlay =
          Navigator.of(context).overlay!.context.findRenderObject()
              as RenderBox;
      final local = overlay.globalToLocal(position);
      final action = await showMenu<_AlbumAction>(
        context: context,
        position: RelativeRect.fromRect(
          Rect.fromLTWH(local.dx, local.dy, 0, 0),
          Offset.zero & overlay.size,
        ),
        items: [
          PopupMenuItem(
            key: const ValueKey('desktop-library-rename'),
            value: _AlbumAction.rename,
            enabled: canRename,
            child: ListTile(
              enabled: canRename,
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
          PopupMenuItem(
            key: const ValueKey('desktop-library-cover'),
            value: _AlbumAction.cover,
            enabled: !readOnly,
            child: ListTile(
              enabled: !readOnly,
              leading: const Icon(Icons.image_outlined),
              title: const Text('自定义封面'),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
          PopupMenuItem(
            key: const ValueKey('desktop-library-delete'),
            value: _AlbumAction.delete,
            enabled: canDelete,
            child: ListTile(
              enabled: canDelete,
              leading: const Icon(Icons.delete_outline),
              title: Text(albumId == null ? '清空全部作品' : '删除'),
              iconColor: canDelete ? context.scheme.error : null,
              textColor: canDelete ? context.scheme.error : null,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        ],
      );
      if (action == null || !context.mounted) return;
      switch (action) {
        case _AlbumAction.rename:
          final album = container.read(albumsProvider).album(albumId);
          if (album != null) await showAlbumName(context, album: album);
        case _AlbumAction.cover:
          await showAlbumCoverDialog(context, albumId: albumId);
        case _AlbumAction.delete:
          await _deleteAlbum(context, container, albumId);
      }
    } catch (error) {
      if (context.mounted) albumError(context, error);
    } finally {
      _busy = false;
    }
  }

  Future<void> _deleteAlbum(
    BuildContext context,
    ProviderContainer container,
    String? albumId,
  ) async {
    bool hasGeneration() => container
        .read(generationProvider)
        .jobs
        .any((job) => albumId == null || job.galleryTarget.albumId == albumId);
    if (hasGeneration()) {
      hintSnack(context, '该图库仍有生成任务，请任务结束后再删除');
      return;
    }
    if (albumId == null) {
      final ids = container
          .read(galleryProvider)
          .results
          .map((r) => r.id)
          .toList();
      if (ids.isEmpty) return;
      final confirmed = await confirmDialog(
        context,
        title: '清空全部作品？',
        message:
            '将删除全部 ${ids.length} 张作品及其历史参数，移除它们在各图库中的归属。'
            '“全部作品”和其他图库容器会保留，已导出的文件不受影响。此操作不可恢复。',
        confirmLabel: '清空全部作品',
      );
      if (!confirmed || !context.mounted) return;
      if (hasGeneration()) {
        hintSnack(context, '仍有生成任务，已保留全部作品');
        return;
      }
      final deleted = await container
          .read(galleryProvider.notifier)
          .deleteResultsVerified(ids);
      if (!context.mounted) return;
      final stores = container.read(appStoresProvider);
      await stores.gallery.flushIndex();
      await stores.albums.idle;
      if (!context.mounted) return;
      final failed = ids.length - deleted.length;
      hintSnack(
        context,
        failed == 0
            ? '已删除 ${deleted.length} 张作品，图库已保留'
            : '已删除 ${deleted.length} 张作品；$failed 张未能删除，仍保留在图库中',
        icon: failed == 0 ? Icons.check_circle_outline : Icons.error_outline,
      );
      return;
    }
    final albums = container.read(albumsProvider);
    if (!albums.exists(albumId)) return;
    final plan = AlbumDeletionPlan.capture(
      albumId: albumId,
      albums: albums,
      images: container.read(galleryProvider).results,
    );
    final confirmed = await confirmDialog(
      context,
      title: '删除「${albums.name(albumId)}」？',
      message: [
        '是否删除这个图库（包含 ${plan.imageIds.length} 张图片）？',
        if (plan.exclusiveIds.isNotEmpty)
          '将一并删除仅在此图库中的 ${plan.exclusiveIds.length} 张图片，并从全部作品中移除。',
        if (plan.sharedIds.isNotEmpty)
          '${plan.sharedIds.length} 张图片也属于其他图库，将保留这些图片。',
        if (plan.imageIds.isEmpty) '图库里没有图片，将只删除这个空图库。',
        '此操作不可恢复。',
      ].join('\n\n'),
      confirmLabel: '删除图库',
    );
    if (!confirmed || !context.mounted) return;
    final result = await deleteGalleryAlbum(container, plan);
    if (!context.mounted) return;
    if (!result.albumDeleted) {
      final reason = switch (result.status) {
        AlbumDeletionStatus.generationPending => '图库有生成任务，已保留图库',
        AlbumDeletionStatus.contentsChanged => '图库内容或归属已变化，已保留图库，请重新操作',
        AlbumDeletionStatus.filesRemain => '部分图片未能删除，已保留图片和图库，请稍后重试',
        AlbumDeletionStatus.deleted => '',
      };
      hintSnack(
        context,
        result.deletedIds.isEmpty
            ? reason
            : '已删除 ${result.deletedIds.length} 张图片；$reason',
        icon: Icons.error_outline,
      );
      return;
    }
    final selected = container.read(desktopLibraryProvider);
    if (!selected.automatic && selected.albumId == albumId) {
      container.read(desktopLibraryProvider.notifier).choose(null);
      container.read(generationProvider.notifier).select(null);
      container.read(galleryResultPreviewProvider.notifier).clear();
    }
    hintSnack(
      context,
      '已删除图库及 ${result.deletedIds.length} 张图片'
      '${plan.sharedIds.isEmpty ? '' : '；${plan.sharedIds.length} 张其他图库共用的图片已保留'}',
    );
  }
}
