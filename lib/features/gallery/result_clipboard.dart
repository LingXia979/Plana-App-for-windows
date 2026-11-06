import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/clipboard_image.dart';
import '../../core/platform/image_transfer.dart';
import '../../core/store/app_stores.dart';
import '../generate/widgets/common.dart' show hintSnack;
import 'models.dart';
import 'save_pipeline.dart';
import 'save_settings.dart';

Future<PreparedImageTransfer> prepareResultTransfer(
  WidgetRef ref,
  ResultImage result,
) {
  // Snapshot preferences and source before any await or widget unmount.
  final settings = ref.read(saveSettingsProvider.future);
  final store = result.bytes == null
      ? ref.read(appStoresProvider).gallery
      : null;
  return prepareImageTransfer(
    load: () async => result.bytes ?? await store?.readImage(result.id),
    settings: settings,
    name: 'plana_${result.seed}',
  );
}

Future<PreparedImageTransfer> prepareImageTransfer({
  required Future<Uint8List?> Function() load,
  required Future<SaveSettings> settings,
  String name = 'plana_image',
}) async {
  final options = await settings;
  final source = await load();
  if (source == null || source.isEmpty) {
    throw const FormatException('图片还没读出来，稍后再试');
  }
  final input = options.format == SaveFormat.png
      ? await DesktopClipboard.ensurePng(source)
      : source;
  final bytes = await processForSave(input, options);
  final safeName = name.replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]'), '_');
  return PreparedImageTransfer(
    bytes: bytes,
    name:
        '${safeName.isEmpty ? 'plana_image' : safeName}.${options.format.name}',
  );
}

/// Copy and drag-out share the gallery's save settings and processing.
Future<void> copyResultToClipboard(
  BuildContext context,
  WidgetRef ref,
  ResultImage result,
) => copyPreparedImage(context, prepareResultTransfer(ref, result));

Future<void> copyBytesToClipboard(
  BuildContext context,
  WidgetRef ref,
  Uint8List bytes,
) => copyPreparedImage(
  context,
  prepareImageTransfer(
    load: () async => bytes,
    settings: ref.read(saveSettingsProvider.future),
  ),
);

int _copySequence = 0;

Future<void> copyPreparedImage(
  BuildContext context,
  Future<PreparedImageTransfer> preparation,
) async {
  final sequence = ++_copySequence;
  try {
    final export = await preparation;
    if (!context.mounted || sequence != _copySequence) return;
    final file = defaultTargetPlatform == TargetPlatform.windows
        ? await export.file()
        : null;
    if (!context.mounted || sequence != _copySequence) return;
    final ok = await DesktopClipboard.writeImage(
      export.bytes,
      filePath: file?.path,
      stillCurrent: () => context.mounted && sequence == _copySequence,
    );
    if (!context.mounted || sequence != _copySequence) return;
    hintSnack(
      context,
      ok ? '图片已按图库默认保存设置复制' : '复制失败：剪贴板暂时不可用，请重试',
      icon: ok ? Icons.check_circle_outline : Icons.error_outline,
    );
  } catch (_) {
    if (context.mounted && sequence == _copySequence) {
      hintSnack(context, '无法准备要复制的图片，请重试', icon: Icons.error_outline);
    }
  }
}
