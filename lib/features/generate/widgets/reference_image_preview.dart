import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Views the original reference bytes without changing generation parameters.
Future<void> showReferenceImagePreview(
  BuildContext context, {
  required Uint8List image,
  required String title,
}) => showDialog<void>(
  context: context,
  requestFocus: true,
  builder: (_) => _ReferenceImagePreview(image: image, title: title),
);

class _ReferenceImagePreview extends StatefulWidget {
  const _ReferenceImagePreview({required this.image, required this.title});

  final Uint8List image;
  final String title;

  @override
  State<_ReferenceImagePreview> createState() => _ReferenceImagePreviewState();
}

class _ReferenceImagePreviewState extends State<_ReferenceImagePreview> {
  final _transform = TransformationController();
  Offset _doubleTapPosition = Offset.zero;

  void _reset() => _transform.value = Matrix4.identity();

  void _doubleTap() {
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _reset();
      return;
    }
    const scale = 2.5;
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        _doubleTapPosition.dx * (1 - scale),
        _doubleTapPosition.dy * (1 - scale),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    key: const ValueKey('reference-image-preview'),
    constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 800),
    insetPadding: const EdgeInsets.all(20),
    clipBehavior: Clip.antiAlias,
    child: SizedBox(
      width: 1100,
      height: 800,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: '适应窗口',
                  onPressed: _reset,
                  icon: const Icon(Icons.fit_screen),
                ),
                IconButton(
                  tooltip: '关闭预览',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ColoredBox(
                  color: context.scheme.surfaceContainerLowest,
                  child: GestureDetector(
                    onDoubleTapDown: (details) =>
                        _doubleTapPosition = details.localPosition,
                    onDoubleTap: _doubleTap,
                    child: InteractiveViewer(
                      transformationController: _transform,
                      maxScale: 8,
                      child: SizedBox.expand(
                        child: Image.memory(
                          widget.image,
                          key: const ValueKey('reference-preview-image'),
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                          errorBuilder: (_, _, _) =>
                              const Center(child: Text('这张参考图暂时无法读取')),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '滚轮缩放 · 拖动查看 · 双击还原或放大 · Esc 关闭',
              textAlign: TextAlign.center,
              style: context.texts.bodySmall!.copyWith(
                color: context.scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
