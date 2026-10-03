import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../gallery/gallery_state.dart';
import '../gallery/albums/gallery_transfer_dialog.dart';
import '../gallery/models.dart';
import '../gallery/widgets/result_canvas.dart';
import '../generate/models.dart';
import '../shell/shell_state.dart';

typedef _ViewerFrame = ({MemoryImage? image, GenerateState? input});

Future<void> showDesktopImageViewer(
  BuildContext context, {
  required List<ResultImage> images,
  required int index,
  required String libraryName,
  String? sourceAlbum,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _DesktopImageViewer(
    images: images,
    initialIndex: index,
    libraryName: libraryName,
    sourceAlbum: sourceAlbum,
  ),
);

class _DesktopImageViewer extends ConsumerStatefulWidget {
  const _DesktopImageViewer({
    required this.images,
    required this.initialIndex,
    required this.libraryName,
    this.sourceAlbum,
  });
  final List<ResultImage> images;
  final int initialIndex;
  final String libraryName;
  final String? sourceAlbum;
  @override
  ConsumerState<_DesktopImageViewer> createState() =>
      _DesktopImageViewerState();
}

class _DesktopImageViewerState extends ConsumerState<_DesktopImageViewer> {
  late int _index = widget.initialIndex;
  late int _targetIndex = _index;
  final _frames = <int, Future<_ViewerFrame>>{};
  MemoryImage? _image;
  GenerateState? _input;
  bool _hasFrame = false;
  bool _loading = true;
  bool _transferring = false;
  int _loadSequence = 0;
  final _transform = TransformationController();
  final _infoScroll = ScrollController(keepScrollOffset: false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_show(_targetIndex));
    });
  }

  @override
  void dispose() {
    _frames.clear();
    _transform.dispose();
    _infoScroll.dispose();
    super.dispose();
  }

  void _step(int delta) {
    final next = _targetIndex + delta;
    if (next < 0 || next >= widget.images.length) {
      return;
    }
    unawaited(_show(next));
  }

  Future<_ViewerFrame> _prepare(int index) =>
      _frames.putIfAbsent(index, () => _readFrame(index));

  Future<_ViewerFrame> _readFrame(int index) async {
    final result = widget.images[index];
    final input = _readInput(result);
    final image = await _readImage(result);
    return (image: image, input: await input);
  }

  Future<GenerateState?> _readInput(ResultImage result) async {
    if (result.input != null) return result.input;
    ProviderSubscription<AsyncValue<GenerateState?>>? subscription;
    try {
      final provider = galleryInputProvider(result.id);
      subscription = ref.listenManual(provider, (_, _) {});
      return await ref.read(provider.future);
    } catch (_) {
      return null;
    } finally {
      subscription?.close();
    }
  }

  Future<MemoryImage?> _readImage(ResultImage result) async {
    ProviderSubscription<AsyncValue<Uint8List?>>? subscription;
    try {
      var bytes = result.bytes;
      if (bytes == null) {
        // Keep this lazy read alive until it finishes, including prefetches.
        final provider = galleryImageProvider(result.id);
        subscription = ref.listenManual(provider, (_, _) {});
        bytes = await ref.read(provider.future);
      }
      if (!mounted || bytes == null) return null;
      final image = MemoryImage(bytes);
      var failed = false;
      await precacheImage(image, context, onError: (_, _) => failed = true);
      return failed ? null : image;
    } catch (_) {
      return null;
    } finally {
      subscription?.close();
    }
  }

  Future<void> _show(int index) async {
    final sequence = ++_loadSequence;
    setState(() {
      _targetIndex = index;
      _loading = true;
    });
    final frame = await _prepare(index);
    if (!mounted || sequence != _loadSequence) return;
    // Commit pixels, metadata and actions together after decoding. Keep the
    // existing Image/InteractiveViewer mounted while the next frame loads.
    if (_infoScroll.hasClients) _infoScroll.jumpTo(0);
    setState(() {
      _index = index;
      _image = frame.image;
      _input = frame.input;
      _hasFrame = true;
      _loading = false;
      _transform.value = Matrix4.identity();
    });
    // Only retain the current frame and its neighbours, never the whole album.
    _frames.removeWhere((i, _) => (i - index).abs() > 1);
    for (final neighbor in [index - 1, index + 1]) {
      if (neighbor >= 0 && neighbor < widget.images.length) {
        unawaited(_prepare(neighbor));
      }
    }
  }

  void _close() {
    Navigator.of(context).pop();
  }

  Future<void> _transfer({required bool copy}) async {
    if (_transferring) return;
    setState(() => _transferring = true);
    try {
      final change = await showGalleryTransfer(
        context,
        {widget.images[_index].id},
        copy: copy,
        sourceAlbum: widget.sourceAlbum,
      );
      if (mounted &&
          !copy &&
          widget.sourceAlbum != null &&
          change != null &&
          change.count > 0) {
        _close();
      }
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.images[_index];
    final input = _input;
    final comparison = ref.watch(comparePreviewProvider);
    final displayedImage = comparison?.resultId == result.id
        ? MemoryImage(comparison!.bytes)
        : _image;
    ref.listen(shellIndexProvider, (_, index) {
      // 只有用户明确导入/使用重绘才离开图库；普通看图不动创作历史选中项。
      if (index == kTabCreate && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    });
    final size = MediaQuery.sizeOf(context);
    final date = result.createdAt <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(result.createdAt);
    final prompts = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText(
          !_hasFrame
              ? '正在读取作品参数…'
              : input == null
              ? '这张作品没有保存参数快照，可通过导入读取图片元数据。'
              : input.prompt.isEmpty
              ? '未填写正面提示词'
              : input.prompt,
          style: const TextStyle(fontSize: 13, height: 1.8),
        ),
        if (input != null) ...[
          for (final character in input.characters.where(
            (c) => c.enabled && c.positive.isNotEmpty,
          )) ...[
            const SizedBox(height: 16),
            Text(
              character.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            SelectableText(
              character.positive,
              style: const TextStyle(fontSize: 13, height: 1.8),
            ),
          ],
          if (input.negativePrompt.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text(
              '负面提示词',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            SelectableText(
              input.negativePrompt,
              style: const TextStyle(fontSize: 13, height: 1.8),
            ),
          ],
        ],
      ],
    );
    final info = Column(
      key: const ValueKey('desktop-image-info'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '作品信息',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 20),
        Text(
          '${result.width} × ${result.height} px',
          style: TextStyle(color: context.scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Text(
          input == null
              ? (_hasFrame ? '未保存生成参数' : '正在读取生成参数…')
              : '${input.params.activeSteps} 步 · ${input.params.model}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: context.scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                '种子  ${result.seed}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: '复制种子',
              icon: const Icon(Icons.copy_outlined, size: 16),
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: '${result.seed}')),
            ),
          ],
        ),
        Text(
          date == null
              ? '生成时间未知'
              : '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
                    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}',
          style: TextStyle(color: context.scheme.outline, fontSize: 12),
        ),
        const SizedBox(height: 24),
        const Text(
          '正面提示词',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Scrollbar(
            controller: _infoScroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              key: const ValueKey('desktop-image-prompts'),
              controller: _infoScroll,
              // Reserve the gutter even when the text needs no scrollbar.
              padding: const EdgeInsets.only(right: 14),
              child: prompts,
            ),
          ),
        ),
        const SizedBox(height: 16),
        ResultActions(
          key: ValueKey('desktop-image-actions-${result.id}'),
          result: result,
          detailsPanel: true,
          onInpaintOpened: () =>
              ref.read(shellIndexProvider.notifier).select(kTabCreate),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('desktop-image-move'),
                onPressed: _transferring ? null : () => _transfer(copy: false),
                icon: const Icon(Icons.drive_file_move_outline, size: 18),
                label: const Text('移动'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('desktop-image-copy'),
                onPressed: _transferring ? null : () => _transfer(copy: true),
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: const Text('复制'),
              ),
            ),
          ],
        ),
      ],
    );
    return Dialog(
      key: const ValueKey('desktop-image-viewer'),
      insetPadding: const EdgeInsets.all(20),
      constraints: const BoxConstraints(maxWidth: 1500),
      child: PopScope(
        canPop: true,
        child: SizedBox(
          width: size.width - 40,
          height: size.height - 40,
          child: Stack(
            children: [
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape): _close,
                  const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                      _step(-1),
                  const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                      _step(1),
                },
                child: Focus(
                  autofocus: true,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${widget.libraryName} · 作品 ${result.id.replaceFirst('gen', '')}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Text(
                              '${_index + 1} / ${widget.images.length}',
                              style: TextStyle(color: context.scheme.outline),
                            ),
                            const SizedBox(width: 14),
                            IconButton(
                              key: const ValueKey('desktop-image-close'),
                              tooltip: '关闭 (Esc)',
                              onPressed: _close,
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: ColoredBox(
                                    color: context.scheme.surface,
                                    child: Column(
                                      children: [
                                        Expanded(
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              _image == null
                                                  ? Center(
                                                      child: _loading
                                                          ? const CircularProgressIndicator()
                                                          : const Text(
                                                              '无法读取这张图片',
                                                            ),
                                                    )
                                                  : InteractiveViewer(
                                                      transformationController:
                                                          _transform,
                                                      minScale: .5,
                                                      maxScale: 8,
                                                      child: SizedBox.expand(
                                                        child: Image(
                                                          key: const ValueKey(
                                                            'desktop-viewer-image',
                                                          ),
                                                          image:
                                                              displayedImage!,
                                                          fit: BoxFit.contain,
                                                          gaplessPlayback: true,
                                                        ),
                                                      ),
                                                    ),
                                              if (result.hasInpaintComparison)
                                                Positioned(
                                                  right: 12,
                                                  bottom: 12,
                                                  child: ResultActions(
                                                    key: ValueKey(
                                                      'desktop-image-comparison-${result.id}',
                                                    ),
                                                    result: result,
                                                    canvasBar: CanvasActionBar
                                                        .comparison,
                                                    enabled: _image != null,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.all(8),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              IconButton(
                                                key: const ValueKey(
                                                  'desktop-image-previous',
                                                ),
                                                tooltip: '上一张 (←)',
                                                onPressed: _targetIndex > 0
                                                    ? () => _step(-1)
                                                    : null,
                                                icon: const Icon(
                                                  Icons.chevron_left,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              TextButton.icon(
                                                onPressed: () =>
                                                    _transform.value =
                                                        Matrix4.identity(),
                                                icon: const Icon(
                                                  Icons.fit_screen,
                                                  size: 18,
                                                ),
                                                label: const Text('适应窗口'),
                                              ),
                                              const SizedBox(width: 12),
                                              IconButton(
                                                key: const ValueKey(
                                                  'desktop-image-next',
                                                ),
                                                tooltip: '下一张 (→)',
                                                onPressed:
                                                    _targetIndex <
                                                        widget.images.length - 1
                                                    ? () => _step(1)
                                                    : null,
                                                icon: const Icon(
                                                  Icons.chevron_right,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 24),
                              SizedBox(
                                width: (size.width * .26).clamp(260, 340),
                                child: info,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
