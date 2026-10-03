import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/store/app_stores.dart';
import '../../../core/theme/app_theme.dart';
import '../../desktop/desktop_library_state.dart';
import '../../generate/generation_controller.dart';
import '../albums/album_state.dart';
import '../desktop_image_save.dart';
import '../gallery_export.dart';
import '../gallery_state.dart';
import '../models.dart';
import '../save_settings.dart';

Future<GalleryExportReport?> showGalleryExportDialog(
  BuildContext context, {
  required List<ResultImage> selected,
  required String? albumId,
  required String albumName,
}) => showDialog<GalleryExportReport>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _GalleryExportDialog(
    selected: List.unmodifiable(selected),
    albumId: albumId,
    albumName: albumName,
  ),
);

class _GalleryExportDialog extends ConsumerStatefulWidget {
  const _GalleryExportDialog({
    required this.selected,
    required this.albumId,
    required this.albumName,
  });

  final List<ResultImage> selected;
  final String? albumId;
  final String albumName;

  @override
  ConsumerState<_GalleryExportDialog> createState() =>
      _GalleryExportDialogState();
}

class _GalleryExportDialogState extends ConsumerState<_GalleryExportDialog> {
  late final _directory = TextEditingController(
    text: ref.read(desktopSaveDirectoryProvider) ?? '',
  );
  var _folder = GalleryExportFolder.date;
  var _createFolder = false;
  var _cleanup = GalleryExportCleanup.none;
  var _busy = false;
  var _committing = false;
  var _cancelRequested = false;
  var _done = 0;
  var _total = 0;
  var _phase = '';
  String? _error;

  @override
  void dispose() {
    _directory.dispose();
    super.dispose();
  }

  List<ResultImage> _scopeImages() {
    final albums = ref.read(albumsProvider);
    if (!albums.exists(widget.albumId)) throw StateError('图库已被删除');
    return ref
        .read(galleryProvider)
        .results
        .where((image) => albums.contains(widget.albumId, image.id))
        .toList();
  }

  String _operation(GalleryExportCleanup mode) => switch (mode) {
    GalleryExportCleanup.none => '保留图库图片',
    GalleryExportCleanup.selected => '删除所选图片',
    GalleryExportCleanup.keepSamples => '删除图库其余图片，每种设置与 tag 仅保留最新一张样图',
    GalleryExportCleanup.deleteAlbum =>
      widget.albumId == null ? '清空全部作品，保留基础图库' : '清空图库并删除图库',
  };

  Future<void> _browse() async {
    try {
      final chosen = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择图片导出文件夹',
        initialDirectory: _directory.text.isEmpty ? null : _directory.text,
        lockParentWindow: true,
      );
      if (chosen != null && mounted) {
        setState(() {
          _directory.text = chosen;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '无法打开文件夹选择：$error');
    }
  }

  bool _hasTargetedGeneration(String? id) => ref
      .read(generationProvider)
      .jobs
      .any((job) => id == null || job.galleryTarget.albumId == id);

  Future<bool> _confirm(GalleryExportPlan plan) async {
    final selectedIds = plan.items.map((image) => image.id).toSet();
    final unexported = plan.deleteIds.difference(selectedIds).length;
    final memberships = ref.read(albumsProvider);
    final shared = widget.albumId == null
        ? 0
        : plan.deleteIds
              .where((id) => memberships.ofImage(id).length > 1)
              .length;
    return await showDialog<bool>(
          context: context,
          builder: (confirmationContext) => AlertDialog(
            key: const ValueKey('gallery-export-confirm-dialog'),
            title: const Text('确认导出'),
            content: SizedBox(
              width: 470,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(text: '你确认导出图片并执行“'),
                          TextSpan(
                            text: _operation(plan.options.cleanup),
                            style: TextStyle(
                              color: context.scheme.error,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const TextSpan(text: '”操作？'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '导出所选 ${plan.items.length} 张；从「${widget.albumName}」删除 ${plan.deleteIds.length} 张。',
                    ),
                    if (unexported > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('其中 $unexported 张未选择导出，也会被删除。'),
                      ),
                    if (shared > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('其中 $shared 张也属于其他图库，删除时会同步移除。'),
                      ),
                    if (plan.options.cleanup ==
                        GalleryExportCleanup.keepSamples) ...[
                      const SizedBox(height: 8),
                      Text('保留 ${plan.retainedCount} 张样图，忽略种子，每组取最新一张。'),
                      if (plan.unknownCount > 0)
                        Text('${plan.unknownCount} 张缺少完整生成信息，会分别保留。'),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      plan.options.cleanup == GalleryExportCleanup.selected
                          ? '只有成功导出的所选图片会被删除。'
                          : '所选图片全部导出成功后执行；导出失败或停止时保留图库。',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(confirmationContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const ValueKey('gallery-export-confirm'),
                onPressed: () => Navigator.pop(confirmationContext, true),
                child: const Text('确认导出并执行'),
              ),
            ],
          ),
        ) ==
        true;
  }

  Future<String> _applyCleanup(
    GalleryExportPlan plan,
    GalleryExportReport report,
  ) async {
    if (plan.options.cleanup == GalleryExportCleanup.none) return '';
    if (report.canceled || _cancelRequested) return '已停止，未清理图库';
    final wholeLibrary = plan.options.cleanup != GalleryExportCleanup.selected;
    if (wholeLibrary && report.failedIds.isNotEmpty) {
      return '导出未全部成功，未执行图库清理';
    }
    final scopeIds = _scopeImages().map((image) => image.id).toSet();
    if (wholeLibrary && !setEquals(scopeIds, plan.scopeIds)) {
      return '图库内容已变化，未执行清理，请重新操作';
    }
    if (plan.options.cleanup == GalleryExportCleanup.deleteAlbum &&
        _hasTargetedGeneration(plan.albumId)) {
      return '该图库仍有生成任务，已保留图库';
    }
    final toDelete = report.cleanupIds.intersection(scopeIds).toList();
    final stores = ref.read(appStoresProvider);
    final deleted = await ref
        .read(galleryProvider.notifier)
        .deleteResultsVerified(toDelete);
    await stores.gallery.flushIndex();
    await stores.gallery.idle;
    await stores.albums.idle;
    if (!mounted) return '';
    if (deleted.length != toDelete.length) {
      return '已删除 ${deleted.length} 张；${toDelete.length - deleted.length} 张未能删除，已保留图片和图库，请稍后重试';
    }
    if (plan.options.cleanup == GalleryExportCleanup.deleteAlbum) {
      // Late results belong to the live library, not to the confirmed snapshot.
      if (_scopeImages().isNotEmpty || _hasTargetedGeneration(plan.albumId)) {
        return '已删除 ${toDelete.length} 张；图库有新内容或任务，已保留图库';
      }
      final albumId = plan.albumId;
      if (albumId == null) return '已清空全部作品，基础图库已保留';
      await ref.read(albumsProvider.notifier).delete(albumId);
      if (mounted && ref.read(desktopLibraryProvider).albumId == plan.albumId) {
        ref.read(desktopLibraryProvider.notifier).choose(null);
      }
      return '已清空并删除「${plan.title}」';
    }
    return plan.options.cleanup == GalleryExportCleanup.keepSamples
        ? '已删除 ${toDelete.length} 张，保留 ${plan.retainedCount} 张样图'
        : '已删除 ${toDelete.length} 张已导出图片';
  }

  Future<void> _submit() async {
    if (_busy) return;
    final directory = _directory.text.trim();
    if (directory.isEmpty) {
      setState(() => _error = '请先选择导出文件夹');
      return;
    }
    setState(() {
      _busy = true;
      _committing = false;
      _cancelRequested = false;
      _error = null;
      _done = 0;
      _total = 0;
      _phase = '正在准备导出';
    });
    GalleryExportReport? report;
    try {
      if (!await Directory(directory).exists()) {
        throw StateError('导出文件夹不存在，请重新选择');
      }
      if (!mounted || _cancelRequested) return;
      final stores = ref.read(appStoresProvider);
      await stores.gallery.idle;
      if (!mounted || _cancelRequested) return;
      final scope = _scopeImages();
      final selectedIds = widget.selected.map((image) => image.id).toSet();
      final selected = scope
          .where((image) => selectedIds.contains(image.id))
          .toList();
      if (selected.length != selectedIds.length) {
        throw StateError('所选图片已变化，请关闭后重新选择');
      }
      final options = GalleryExportOptions(
        directory: directory,
        folder: _createFolder ? _folder : GalleryExportFolder.none,
        cleanup: _cleanup,
      );
      final plan = await prepareGalleryExport(
        selected: selected,
        albumImages: scope,
        albumId: widget.albumId,
        albumName: widget.albumName,
        options: options,
        store: stores.gallery,
        canceled: () => !mounted || _cancelRequested,
      );
      if (!mounted || _cancelRequested) return;
      if (_cleanup == GalleryExportCleanup.deleteAlbum &&
          _hasTargetedGeneration(widget.albumId)) {
        throw StateError(
          widget.albumId == null
              ? '仍有生成任务，请任务结束后再清空全部作品'
              : '该图库仍有生成任务，请任务结束后再执行删除图库',
        );
      }
      if (_cleanup != GalleryExportCleanup.none && !await _confirm(plan)) {
        return;
      }
      if (!mounted || _cancelRequested) return;
      final settings = await ref.read(saveSettingsProvider.future);
      if (!mounted || _cancelRequested) return;
      setState(() {
        _phase = '正在导出';
        _total = plan.items.length;
      });
      report = await exportGalleryImages(
        plan,
        store: stores.gallery,
        settings: settings,
        canceled: () => !mounted || _cancelRequested,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _done = done;
              _total = total;
            });
          }
        },
      );
      if (!mounted) return;
      setState(() {
        _committing = true;
        _phase = '正在完成导出';
      });
      final cleanupMessage = await _applyCleanup(plan, report);
      if (!mounted) return;
      if (report.savedIds.isNotEmpty) {
        await ref.read(desktopSaveDirectoryProvider.notifier).select(directory);
      }
      if (!mounted) return;
      final summary = [
        '已导出 ${report.savedIds.length} 张',
        if (report.failedIds.isNotEmpty) '${report.failedIds.length} 张失败',
        if (report.canceled && cleanupMessage.isEmpty) '已停止',
        if (cleanupMessage.isNotEmpty) cleanupMessage,
      ].join('；');
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context, report);
      messenger.showSnackBar(SnackBar(content: Text(summary)));
    } on GalleryExportCanceled {
      // A stopped preparation has not written files or changed the gallery.
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = report == null
              ? '无法导出：$error'
              : '已导出 ${report.savedIds.length} 张，图库清理未完成：$error',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _committing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dimensions = MediaQuery.sizeOf(context);
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        key: const ValueKey('gallery-export-dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 780,
            maxHeight: dimensions.height - 48,
          ),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('导出图片', style: context.texts.headlineSmall),
                const SizedBox(height: 8),
                Text('「${widget.albumName}」· 已选 ${widget.selected.length} 张'),
                const SizedBox(height: 18),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: const ValueKey('gallery-export-directory'),
                                controller: _directory,
                                enabled: !_busy,
                                decoration: const InputDecoration(
                                  labelText: '导出文件夹',
                                  hintText: '浏览选择保存位置',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            FilledButton.tonalIcon(
                              key: const ValueKey('gallery-export-browse'),
                              onPressed: _busy ? null : _browse,
                              icon: const Icon(
                                Icons.folder_open_outlined,
                                size: 18,
                              ),
                              label: const Text('浏览'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          key: const ValueKey('gallery-export-create-folder'),
                          value: _createFolder,
                          onChanged: _busy
                              ? null
                              : (value) =>
                                    setState(() => _createFolder = value!),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text('创建子文件夹'),
                          dense: true,
                        ),
                        if (_createFolder)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              children: [
                                for (final option in [
                                  GalleryExportFolder.date,
                                  GalleryExportFolder.album,
                                ])
                                  ChoiceChip(
                                    key: ValueKey(
                                      'gallery-export-folder-${option.name}',
                                    ),
                                    label: Text(
                                      option == GalleryExportFolder.date
                                          ? '以导出日期命名'
                                          : '以图库名称命名',
                                    ),
                                    selected: _folder == option,
                                    onSelected: _busy
                                        ? null
                                        : (_) =>
                                              setState(() => _folder = option),
                                  ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 10),
                        const Text(
                          '导出后',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        LayoutBuilder(
                          builder: (context, constraints) => Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final (mode, label) in [
                                (GalleryExportCleanup.selected, '删除所选图片'),
                                (GalleryExportCleanup.keepSamples, '每组保留一张样图'),
                                (
                                  GalleryExportCleanup.deleteAlbum,
                                  widget.albumId == null ? '清空全部作品' : '清空并删除图库',
                                ),
                              ])
                                SizedBox(
                                  width: constraints.maxWidth >= 630
                                      ? (constraints.maxWidth - 16) / 3
                                      : null,
                                  child: FilterChip(
                                    key: ValueKey(
                                      'gallery-export-cleanup-${mode.name}',
                                    ),
                                    label: Text(label),
                                    selected: _cleanup == mode,
                                    onSelected: _busy
                                        ? null
                                        : (selected) => setState(
                                            () => _cleanup = selected
                                                ? mode
                                                : GalleryExportCleanup.none,
                                          ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          switch (_cleanup) {
                            GalleryExportCleanup.none => '不选以上选项时，只导出图片。',
                            GalleryExportCleanup.selected => '导出成功后删除所选图片。',
                            GalleryExportCleanup.keepSamples =>
                              '清理当前图库全部图片（包含未选导出的图片），每组保留最新一张；忽略种子。',
                            GalleryExportCleanup.deleteAlbum =>
                              widget.albumId == null
                                  ? '清空全部作品（包含未选导出的图片），保留基础图库。'
                                  : '清空当前图库全部图片（包含未选导出的图片），并删除图库。',
                          },
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (widget.albumId == null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '“全部作品”是基础图库，始终保留；这里只清理图片。',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (_busy) ...[
                          const SizedBox(height: 16),
                          LinearProgressIndicator(
                            value: _total == 0 ? null : _done / _total,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _cancelRequested
                                ? '正在停止…'
                                : '$_phase${_total == 0 ? '' : ' $_done/$_total'}',
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(_error!, style: TextStyle(color: scheme.error)),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const ValueKey('gallery-export-cancel'),
                      onPressed: _busy
                          ? _cancelRequested || _committing
                                ? null
                                : () => setState(() => _cancelRequested = true)
                          : () => Navigator.pop(context),
                      child: Text(_busy ? '停止导出' : '取消'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      key: const ValueKey('gallery-export-submit'),
                      onPressed: _busy ? null : _submit,
                      child: Text('导出 ${widget.selected.length} 张'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
