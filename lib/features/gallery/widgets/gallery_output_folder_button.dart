import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/store/app_stores.dart';
import '../../../core/store/desktop_output_location.dart';
import '../../../core/theme/app_theme.dart';
import '../../generate/widgets/common.dart' show hintSnack;

/// The archive folder is shared by the library overview and its image browser.
class GalleryOutputFolderButton extends ConsumerStatefulWidget {
  const GalleryOutputFolderButton({super.key});

  @override
  ConsumerState<GalleryOutputFolderButton> createState() =>
      _GalleryOutputFolderButtonState();
}

class _GalleryOutputFolderButtonState
    extends ConsumerState<GalleryOutputFolderButton> {
  bool _opening = false;

  Future<void> _open() async {
    final store = ref.read(appStoresProvider).desktopOutput;
    setState(() => _opening = true);
    try {
      final report = await store.migrateLegacy();
      if (!mounted) return;
      if (!isPlainOutputDirectory(store.root)) {
        throw StateError('作品路径不能是链接或文件');
      }
      await store.root.create(recursive: true);
      if (!mounted) return;
      final opened = await launchUrl(
        Uri.directory(store.root.path),
        mode: LaunchMode.externalApplication,
      );
      if (!mounted) return;
      if (!opened) {
        hintSnack(context, '无法打开作品文件夹：${store.root.path}');
      } else if (report.hasErrors) {
        hintSnack(context, '部分旧作品未能迁移，仍保留在原目录；图库历史可正常使用');
      }
    } catch (_) {
      if (mounted) {
        hintSnack(context, '无法打开作品文件夹，请将程序放到可写入的位置：${store.root.path}');
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '自动保存：${ref.read(appStoresProvider).desktopOutput.root.path}',
    child: TextButton.icon(
      key: const ValueKey('desktop-gallery-folder'),
      style: TextButton.styleFrom(
        backgroundColor: context.scheme.primary.withValues(alpha: .08),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        minimumSize: const Size(0, 36),
        visualDensity: VisualDensity.compact,
      ),
      onPressed: _opening ? null : _open,
      icon: const Icon(Icons.folder_open_outlined, size: 18),
      label: Text(_opening ? '正在整理作品…' : '作品文件夹'),
    ),
  );
}
