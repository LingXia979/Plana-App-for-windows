import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/store/app_stores.dart';
import '../../../core/platform/desktop.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/image_drop.dart';
import '../../../core/util/image_ops.dart';
import '../../../core/util/image_pick.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import '../gallery_state.dart';
import '../widgets/history_image_picker.dart';
import 'album_state.dart';
import 'album_ui.dart' show albumError;

enum _CoverSource { current, history, upload, automatic }

class _CoverInput {
  const _CoverInput(this.bytes, this.imageId);
  final Uint8List bytes;
  final String? imageId;
}

/// Choosing a cover never switches the active library or changes its images.
Future<void> showAlbumCoverDialog(
  BuildContext context, {
  String? albumId,
  Uint8List? initialImageBytes,
  String? sourceImageId,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final albums = container.read(albumsProvider);
  if (!albums.exists(albumId)) {
    albumError(context, StateError('图库已被删除'));
    return;
  }
  final images = container.read(galleryProvider).results;
  final source = initialImageBytes != null
      ? _CoverInput(initialImageBytes, sourceImageId)
      : await showDialog<Object>(
          context: context,
          builder: (context) => AlertDialog(
            key: const ValueKey('album-cover-source-dialog'),
            title: const Text('自定义封面'),
            scrollable: true,
            contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            content: SizedBox(
              width: 360,
              child: ImageDropRegion(
                key: const ValueKey('album-cover-image-drop'),
                label: '用此图片制作封面',
                enabled:
                    container.read(desktopModeProvider) &&
                    !container.read(appStoresProvider).albums.readOnly,
                onDrop: (images, payload) async => Navigator.pop(
                  context,
                  _CoverInput(images.first.bytes, payload.imageId),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      key: const ValueKey('album-cover-current'),
                      leading: const Icon(Icons.photo_library_outlined),
                      title: const Text('从这个图库里选择'),
                      enabled: images.any(
                        (image) => albums.contains(albumId, image.id),
                      ),
                      subtitle:
                          images.any(
                            (image) => albums.contains(albumId, image.id),
                          )
                          ? null
                          : const Text('这个图库还没有作品'),
                      onTap: () => Navigator.pop(context, _CoverSource.current),
                    ),
                    ListTile(
                      key: const ValueKey('album-cover-history'),
                      leading: const Icon(Icons.history),
                      title: const Text('从历史里选择'),
                      enabled: images.isNotEmpty,
                      subtitle: images.isEmpty ? const Text('历史里还没有作品') : null,
                      onTap: () => Navigator.pop(context, _CoverSource.history),
                    ),
                    ListTile(
                      key: const ValueKey('album-cover-upload'),
                      leading: const Icon(Icons.upload_file_outlined),
                      title: const Text('从本地上传图片'),
                      onTap: () => Navigator.pop(context, _CoverSource.upload),
                    ),
                    if (albums.cover(albumId) != null) ...[
                      const Divider(),
                      ListTile(
                        key: const ValueKey('album-cover-auto'),
                        leading: const Icon(Icons.restore),
                        title: const Text('恢复自动封面'),
                        onTap: () =>
                            Navigator.pop(context, _CoverSource.automatic),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          ),
        );
  if (source == null || !context.mounted) return;
  try {
    final notifier = container.read(albumsProvider.notifier);
    if (source == _CoverSource.automatic) {
      await notifier.setCover(albumId, null);
      if (context.mounted) hintSnack(context, '已恢复自动封面');
      return;
    }
    Uint8List? bytes;
    String? imageId;
    if (source is _CoverInput) {
      bytes = source.bytes;
      imageId = source.imageId;
    } else if (source == _CoverSource.upload) {
      bytes = (await pickImageFile(context))?.bytes;
      if (bytes == null) return;
    } else {
      final current = container.read(albumsProvider);
      final allowedIds = source == _CoverSource.current
          ? {
              for (final image in container.read(galleryProvider).results)
                if (current.contains(albumId, image.id)) image.id,
            }
          : null;
      final picked = await showHistoryImagePicker(
        context,
        allowedIds: allowedIds,
        title: source == _CoverSource.current ? '从这个图库里选择' : '从历史里选择',
      );
      if (picked == null || picked.isEmpty || !context.mounted) return;
      final image = picked.first;
      imageId = image.id;
      bytes =
          image.bytes ??
          await container.read(appStoresProvider).gallery.readImage(image.id);
      if (bytes == null) throw StateError('这张图片暂时无法读取，请重新选择');
    }
    if (!context.mounted) return;
    final png = await showDialog<Uint8List>(
      context: context,
      builder: (_) => _AlbumCoverCropDialog(bytes: bytes!),
    );
    if (png == null || !context.mounted) return;
    await notifier.setCover(albumId, png, sourceImageId: imageId);
    if (context.mounted) hintSnack(context, '封面已更新');
  } catch (error) {
    if (context.mounted) albumError(context, error);
  }
}

class _AlbumCoverCropDialog extends StatefulWidget {
  const _AlbumCoverCropDialog({required this.bytes});
  final Uint8List bytes;

  @override
  State<_AlbumCoverCropDialog> createState() => _AlbumCoverCropDialogState();
}

class _AlbumCoverCropDialogState extends State<_AlbumCoverCropDialog> {
  double _x = 0, _y = 0;
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final png = await coverResizePng(
        widget.bytes,
        512,
        512,
        keepAlpha: true,
        alignX: _x,
        alignY: _y,
      );
      if (mounted) Navigator.pop(context, png);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '无法制作封面，请换一张图片重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      key: const ValueKey('album-cover-crop-dialog'),
      title: const Text('调整封面'),
      scrollable: true,
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  widget.bytes,
                  fit: BoxFit.cover,
                  alignment: Alignment(_x, _y),
                  errorBuilder: (_, _, _) =>
                      const Center(child: Text('无法读取这张图片')),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('水平位置'),
            Slider(
              key: const ValueKey('album-cover-align-x'),
              value: _x,
              min: -1,
              max: 1,
              onChanged: _busy ? null : (value) => setState(() => _x = value),
            ),
            const Text('垂直位置'),
            Slider(
              key: const ValueKey('album-cover-align-y'),
              value: _y,
              min: -1,
              max: 1,
              onChanged: _busy ? null : (value) => setState(() => _y = value),
            ),
            if (_error != null)
              Text(_error!, style: TextStyle(color: context.scheme.error)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('album-cover-save'),
          onPressed: _busy ? null : _save,
          child: Text(_busy ? '保存中…' : '使用此封面'),
        ),
      ],
    ),
  );
}
