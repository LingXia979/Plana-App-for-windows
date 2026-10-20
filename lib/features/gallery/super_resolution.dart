import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/anlas_provider.dart';
import '../../core/theme/app_theme.dart';
import '../generate/models.dart';
import '../generate/widgets/common.dart' show hintSnack;
import 'albums/album_models.dart';
import 'gallery_state.dart';
import 'models.dart';
import 'upscale_model.dart';
import 'upscale_nai.dart';

/// 导入图片按实际像素校验，再把 JPEG 等格式转成 NAI 接受的 PNG。
/// PNG 原样保留，转换不裁切、不缩小、不填充背景。
Future<({Uint8List png, int width, int height})> prepareSuperResolutionImage(
  Uint8List bytes,
) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width, height = descriptor.height;
    _checkSize(width, height);
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    final png =
        bytes.length >= signature.length &&
        List.generate(
          signature.length,
          (i) => bytes[i] == signature[i],
        ).every((matches) => matches);
    if (png) return (png: bytes, width: width, height: height);
    codec = await descriptor.instantiateCodec();
    image = (await codec.getNextFrame()).image;
    final encoded = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))?.buffer.asUint8List();
    if (encoded == null) throw const FormatException('图片无法转换为 PNG');
    return (png: encoded, width: image.width, height: image.height);
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

void _checkSize(int width, int height) {
  if (width < 16 || height < 16) {
    throw const FormatException('超分辨率需要图片宽高均不少于 16 像素');
  }
  if (!naiV5UpscaleSupportsSize(width, height)) {
    throw FormatException('源图 $width×$height 超过 3,145,728 像素，超分不受理');
  }
}

/// 导入页和图库共用的固定 2× 超分流程。保存目标和选择状态由入口在点击时捕获。
Future<void> superResolveImage(
  BuildContext context,
  WidgetRef ref, {
  required Uint8List png,
  required int width,
  required int height,
  required int seed,
  required GallerySaveTarget target,
  required int selectionRevision,
  GenerateState? input,
}) async {
  _checkSize(width, height);
  // 在等待网络前取出长期存活的 provider，入口关闭后仍能保存已提交的结果。
  final gallery = ref.read(galleryProvider.notifier);
  final run = ref.read(naiUpscaleRunnerProvider);
  final refresh = ref.read(anlasProvider.notifier).refresh;
  final stage = ValueNotifier<String>('准备…');
  final navigator = Navigator.of(context, rootNavigator: true);
  final progress = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: _SuperResolutionProgress(
        key: const ValueKey('upscale-progress'),
        stage: stage,
      ),
    ),
  );
  unawaited(navigator.push(progress));
  try {
    final result = await run(
      png,
      width: width,
      height: height,
      onStage: (s) => stage.value = s,
    );
    await gallery.addResultToGallery(
      target: target,
      canSelect: () => gallery.selectionRevision == selectionRevision,
      bytes: result.png,
      width: result.width,
      height: result.height,
      seed: seed,
      badge: ResultBadge.upscaled2x,
      input: input,
    );
    unawaited(refresh());
    if (context.mounted) {
      hintSnack(
        context,
        '超分辨率完成 ${result.width}×${result.height},已存入图库',
        icon: Icons.check_circle_outline,
      );
    }
  } catch (e) {
    if (context.mounted) {
      hintSnack(context, '超分失败: $e', icon: Icons.error_outline);
    }
  } finally {
    if (navigator.mounted && progress.isActive) navigator.removeRoute(progress);
    await progress.completed;
    stage.dispose();
  }
}

class _SuperResolutionProgress extends StatelessWidget {
  const _SuperResolutionProgress({super.key, required this.stage});

  final ValueNotifier<String> stage;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.blur_on, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Text(
            '${UpscaleMethod.naiV5.label} · ${UpscaleMethod.naiV5.badge}',
            style: const TextStyle(fontSize: 16),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder<String>(
            valueListenable: stage,
            builder: (_, value, _) => Text(
              value,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}
