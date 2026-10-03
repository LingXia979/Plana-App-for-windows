import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../core/theme/app_theme.dart';
import '../generate/generate_state.dart';
import '../generate/nai_request.dart';
import '../generate/vibe_cache.dart';
import '../generate/widgets/common.dart' show hintSnack;
import 'local_vibe_folder.dart';
import 'naiv4vibe_codec.dart';

class LocalVibeFolderPanel extends ConsumerStatefulWidget {
  const LocalVibeFolderPanel({
    super.key,
    required this.search,
    required this.onConfirmed,
  });
  final String search;
  final VoidCallback onConfirmed;
  @override
  ConsumerState<LocalVibeFolderPanel> createState() =>
      _LocalVibeFolderPanelState();
}

class _LocalVibeFolderPanelState extends ConsumerState<LocalVibeFolderPanel> {
  final _selected = <String>{};
  final _hidden = <String>{};
  String _model = '';
  String? _pinned;
  bool _adding = false;
  String? _message;
  String get _modelKey =>
      kModelToEncodingKey[naiModelId(
        ref.read(generateProvider).params.model,
      )] ??
      '';

  @override
  void initState() {
    super.initState();
    Future<void>(() async {
      if (!mounted) return;
      await ref.read(vibeFolderProvider.future);
      if (mounted) await ref.read(vibeFolderProvider.notifier).refresh();
    });
  }

  Future<void> _pickFolder() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择 Vibe 素材文件夹',
    );
    if (selected == null || !mounted) return;
    setState(() {
      _selected.clear();
      _hidden.clear();
      _message = null;
    });
    await ref.read(vibeFolderProvider.notifier).choose(selected);
  }

  Future<void> _confirm(List<FolderVibe> entries) async {
    final selected = entries.where((e) => _selected.contains(e.key)).toList();
    if (selected.isEmpty) return;
    setState(() {
      _adding = true;
      _message = null;
    });
    var count = 0;
    final failed = <String>[];
    final modelKey = _modelKey;
    for (final entry in selected) {
      try {
        final data = await loadFolderVibeInBackground(entry, modelKey);
        if (!mounted) return;
        if (data.imageHash case final String hash) {
          final cache = await ref.read(vibeCacheProvider.future);
          for (final encoding in data.encodings) {
            if (encoding.infoExtracted case final double ie) {
              await cache.put(hash, encoding.modelKey, ie, encoding.encoding);
            }
          }
        }
        if (!mounted) return;
        if (!ref
            .read(generateProvider)
            .vibes
            .any(
              (v) =>
                  v.sourceId == entry.id ||
                  (data.imageHash != null && v.imageHash == data.imageHash),
            )) {
          ref
              .read(generateProvider.notifier)
              .addVibe(
                image: data.image,
                imageHash: data.imageHash,
                name: entry.name,
                sourceId: entry.id,
                strength: entry.strength,
                infoExtracted: data.infoExtracted,
                encodedByModel: data.encodedByModel,
              );
          count++;
        }
        _selected.remove(entry.key);
      } catch (error) {
        failed.add(
          '${entry.name}：${error is FormatException ? error.message : '文件暂时无法读取'}',
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _adding = false;
      _message = failed.isEmpty ? null : failed.take(3).join('；');
    });
    if (failed.isEmpty) {
      hintSnack(context, '已加入 $count 个 Vibe');
      widget.onConfirmed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vibeFolderProvider);
    final library = ref.read(vibeFolderProvider.notifier);
    final data = state.value;
    if (data == null) return const Center(child: CircularProgressIndicator());
    final existingKeys = data.entries.map((e) => e.key).toSet();
    _selected.removeWhere((key) => !existingKeys.contains(key));
    final q = widget.search.trim().toLowerCase();
    final entries = data.entries
        .where(
          (e) =>
              !_hidden.contains(e.key) &&
              (q.isEmpty ||
                  '${e.name} ${e.tags.join(' ')} ${path.basename(e.source)}'
                      .toLowerCase()
                      .contains(q)) &&
              (_model.isEmpty || e.models.contains(_model)),
        )
        .toList();
    if (_pinned != null) {
      entries.sort(
        (a, b) => a.key == _pinned
            ? -1
            : b.key == _pinned
            ? 1
            : 0,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: _adding ? null : _pickFolder,
                icon: const Icon(Icons.folder_open, size: 18),
                label: Text(data.directory == null ? '关联文件夹' : '更换文件夹'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Tooltip(
                  message: data.directory ?? '',
                  child: Text(
                    data.directory ?? '选择保存 Vibe 文件的目录',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodySmall,
                  ),
                ),
              ),
              if (data.directory != null) ...[
                IconButton(
                  tooltip: data.scanning ? '停止扫描' : '刷新文件夹',
                  onPressed: _adding
                      ? null
                      : () {
                          _hidden.clear();
                          data.scanning ? library.cancel() : library.refresh();
                        },
                  icon: Icon(
                    data.scanning ? Icons.stop_circle_outlined : Icons.refresh,
                    size: 20,
                  ),
                ),
                IconButton(
                  tooltip: '取消关联（保留原文件）',
                  onPressed: _adding ? null : library.disconnect,
                  icon: const Icon(Icons.link_off, size: 20),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(
            children: [
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _model,
                  isDense: true,
                  items: [
                    const DropdownMenuItem(value: '', child: Text('全部模型')),
                    for (final entry in kEncodingKeyLabel.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (v) => setState(() => _model = v ?? ''),
                  style: context.texts.bodySmall,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Text(
                  data.message ??
                      (data.scanning
                          ? '正在读取 ${data.done} / ${data.total}'
                          : '${entries.length} 个素材 · ${data.cached} 个文件使用缓存${data.skipped > 0 ? ' · ${data.skipped} 个文件未识别' : ''}'),
                  style: context.texts.labelSmall,
                ),
              ),
              TextButton(
                onPressed: _adding
                    ? null
                    : () => setState(() => _selected.clear()),
                child: const Text('清空选择'),
              ),
            ],
          ),
        ),
        if (data.scanning)
          LinearProgressIndicator(
            value: data.total == 0 ? null : data.done / data.total,
            minHeight: 2,
          ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _message!,
              style: TextStyle(color: context.scheme.error, fontSize: 12),
            ),
          ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 44,
                        color: context.scheme.outlineVariant,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        data.directory == null
                            ? '把本地 Vibe 素材放到这里浏览'
                            : '没有匹配的 Vibe 素材',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '支持 .naiv4vibe、.naiv4vibebundle 和 .json',
                        style: context.texts.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Text('读取所选文件夹，不含子文件夹。', style: context.texts.labelSmall),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisExtent: 246,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final e = entries[index];
                    final selected = _selected.contains(e.key);
                    final compatible =
                        e.hasImage || e.models.contains(_modelKey);
                    return Material(
                      color: selected
                          ? context.scheme.primaryContainer
                          : context.scheme.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: selected
                              ? context.scheme.primary
                              : context.scheme.outlineVariant,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _adding || !compatible
                            ? null
                            : () => setState(() {
                                if (!_selected.remove(e.key)) {
                                  _selected.add(e.key);
                                }
                              }),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  ColoredBox(
                                    color: context.scheme.surfaceContainerLow,
                                    child: e.preview == null
                                        ? Icon(
                                            Icons.data_object,
                                            color: context.scheme.outline,
                                          )
                                        : Image.file(
                                            File(e.preview!),
                                            fit: BoxFit.contain,
                                            cacheWidth: 420,
                                            errorBuilder: (_, _, _) => const Icon(
                                              Icons
                                                  .image_not_supported_outlined,
                                            ),
                                          ),
                                  ),
                                  Positioned(
                                    top: 8,
                                    left: 8,
                                    child: Icon(
                                      selected
                                          ? Icons.check_circle
                                          : Icons.radio_button_unchecked,
                                      color: selected
                                          ? context.scheme.primary
                                          : context.scheme.outline,
                                    ),
                                  ),
                                  Positioned(
                                    top: 0,
                                    right: 0,
                                    child: PopupMenuButton<String>(
                                      tooltip: '素材操作',
                                      onSelected: (action) => setState(() {
                                        if (action == 'pin') {
                                          _pinned = e.key;
                                        } else {
                                          _hidden.add(e.key);
                                          _selected.remove(e.key);
                                        }
                                      }),
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 'pin',
                                          child: Text('本次置顶'),
                                        ),
                                        PopupMenuItem(
                                          value: 'hide',
                                          child: Text('本次隐藏（保留原文件）'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(10, 8, 10, 3),
                              child: Text(
                                e.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                              child: Text(
                                !compatible
                                    ? '当前模型不可用'
                                    : e.models.isEmpty
                                    ? '图片素材'
                                    : e.models
                                          .map((m) => kEncodingKeyLabel[m] ?? m)
                                          .join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: compatible
                                      ? context.scheme.outline
                                      : context.scheme.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '选择后加入创作，保留原文件与已有编码。',
                  style: context.texts.bodySmall,
                ),
              ),
              FilledButton.icon(
                onPressed: _adding || _selected.isEmpty
                    ? null
                    : () => _confirm(data.entries),
                icon: Icon(
                  _adding ? Icons.hourglass_top : Icons.check,
                  size: 18,
                ),
                label: Text(_adding ? '正在加入…' : '确认选择 (${_selected.length})'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
