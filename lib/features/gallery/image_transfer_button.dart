import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/image_transfer.dart';
import '../../core/ui/external_image_drag.dart';
import '../../core/ui/image_drop.dart';
import 'result_clipboard.dart';
import 'save_settings.dart';

/// Also usable by original reference previews, without a gallery result ID.
class ImageTransferButton extends ConsumerWidget {
  const ImageTransferButton({super.key, required this.load});
  final Future<Uint8List?> Function() load;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<PreparedImageTransfer> prepare() => prepareImageTransfer(
      load: load,
      settings: ref.read(saveSettingsProvider.future),
    );
    return ExternalImageDrag(
      data: ImageDropPayload.image(
        name: 'plana_image.png',
        source: 'preview',
        load: load,
      ),
      prepare: prepare,
      feedback: const Material(
        elevation: 6,
        shape: CircleBorder(),
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Icon(Icons.image_outlined, size: 32),
        ),
      ),
      child: IconButton(
        key: const ValueKey('preview-image-transfer'),
        tooltip: '点击复制图片；按住拖到其他应用',
        onPressed: () => copyPreparedImage(context, prepare()),
        icon: const Icon(Icons.copy_outlined),
      ),
    );
  }
}
