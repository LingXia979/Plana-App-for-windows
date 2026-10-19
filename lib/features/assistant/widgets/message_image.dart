import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/store/app_stores.dart';
import '../../generate/widgets/reference_image_preview.dart';

/// An attachment stored with a sent message; preview its bytes, not its thumbnail.
class AssistantMessageImage extends ConsumerStatefulWidget {
  const AssistantMessageImage({
    super.key,
    required this.imageHash,
    required this.title,
  });

  final String imageHash;
  final String title;

  @override
  ConsumerState<AssistantMessageImage> createState() =>
      _AssistantMessageImageState();
}

class _AssistantMessageImageState extends ConsumerState<AssistantMessageImage> {
  late Future<Uint8List?> _image;
  bool _previewOpen = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant AssistantMessageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageHash != widget.imageHash) _loadImage();
  }

  void _loadImage() {
    _image = ref.read(appStoresProvider).assistant.image(widget.imageHash);
  }

  Future<void> _openImage(Uint8List bytes) async {
    if (_previewOpen) return;
    _previewOpen = true;
    try {
      await showReferenceImagePreview(
        context,
        image: bytes,
        title: widget.title,
      );
    } finally {
      _previewOpen = false;
    }
  }

  Widget _unavailable() => const Tooltip(
    message: '图片暂时无法读取',
    child: SizedBox(
      width: 96,
      height: 96,
      child: Icon(Icons.broken_image_outlined),
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    key: ValueKey(widget.imageHash),
    future: _image,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const SizedBox(width: 96, height: 96);
      }
      final bytes = snapshot.data;
      if (bytes == null || bytes.isEmpty) return _unavailable();
      return Tooltip(
        message: '查看原图',
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => unawaited(_openImage(bytes)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              bytes,
              width: 96,
              height: 96,
              cacheWidth: 192,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _unavailable(),
            ),
          ),
        ),
      );
    },
  );
}
