import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/net/remote_image.dart';

/// Scheduling belongs to one codex browser, not the shared image cache. No
/// notifier rebuilds the cards/list when scrolling starts or stops.
class CodexImageLoadController {
  CodexImageLoadController({
    this.quietPeriod = const Duration(milliseconds: 140),
    this.startsPerFrame = 3,
  }) : assert(startsPerFrame > 0);

  final Duration quietPeriod;
  final int startsPerFrame;
  final _positions = <ScrollPosition>{};
  final _waiting = <_CodexImageRequest, VoidCallback>{};
  Timer? _quiet;
  bool _paused = false;
  bool _drainScheduled = false;
  bool _disposed = false;

  @visibleForTesting
  bool get isPaused => _paused;

  @visibleForTesting
  int get pendingCount => _waiting.length;

  /// DragScrollActivity reports zero velocity while dragging a scrollbar; its
  /// isScrollingNotifier remains true, including pauses with the thumb held.
  void attach(ScrollPosition position) {
    if (_disposed || !_positions.add(position)) return;
    position.addListener(_moved);
    position.isScrollingNotifier.addListener(_activityChanged);
    if (position.isScrollingNotifier.value) _activityChanged();
  }

  void detach(ScrollPosition position) {
    if (!_positions.remove(position)) return;
    position.removeListener(_moved);
    position.isScrollingNotifier.removeListener(_activityChanged);
    if (_positions.isEmpty) {
      // An empty filter or a closed grid has no scroll activity left to wait
      // for. Do not leave a quiet timer alive after its last position detaches.
      _quiet?.cancel();
      _quiet = null;
      _paused = false;
      _scheduleDrain();
    } else if (!_disposed && _paused) {
      _waitForQuiet();
    }
  }

  bool get _scrolling =>
      _positions.any((position) => position.isScrollingNotifier.value);

  void _activityChanged() {
    if (_disposed) return;
    if (_scrolling) {
      _paused = true;
      _quiet?.cancel();
    } else {
      _waitForQuiet();
    }
  }

  void _moved() {
    if (_disposed) return;
    _paused = true;
    // Also covers pointerScroll and jumpTo, whose start/end notifications can
    // occur together in one event with no sustained scrolling activity.
    _waitForQuiet();
  }

  void _waitForQuiet() {
    _quiet?.cancel();
    _quiet = Timer(quietPeriod, () {
      _quiet = null;
      if (_disposed || _scrolling) return;
      _paused = false;
      _scheduleDrain();
    });
  }

  void _enqueue(_CodexImageRequest request, VoidCallback resolve) {
    if (_disposed || !request.active) return;
    _waiting[request] = resolve;
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_disposed || _paused || _drainScheduled || _waiting.isEmpty) return;
    _drainScheduled = true;
    // After layout, cards removed by scrolling/filtering have already canceled
    // their tickets. Start only a few remaining thumbnails in each frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _drainScheduled = false;
      if (_disposed || _paused) return;
      final batch = _waiting.keys.take(startsPerFrame).toList();
      for (final request in batch) {
        final resolve = _waiting.remove(request);
        if (request.active) resolve?.call();
      }
      _scheduleDrain();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _quiet?.cancel();
    _quiet = null;
    for (final position in _positions.toList()) {
      detach(position);
    }
    _waiting.clear();
  }
}

/// Owns one image request. Replacing its URL, decode size, or content revision
/// cancels the queued resolution; disposing a card never starts an old request.
class CodexDeferredImage extends StatefulWidget {
  const CodexDeferredImage({
    super.key,
    required this.controller,
    required this.builder,
  });

  final CodexImageLoadController controller;
  final Widget Function(RemoteImageProviderDecorator decorator) builder;

  @override
  State<CodexDeferredImage> createState() => _CodexDeferredImageState();
}

class _CodexDeferredImageState extends State<CodexDeferredImage> {
  ImageProvider<Object>? _source;
  _CodexImageRequest? _request;
  _CodexImageProvider? _provider;

  ImageProvider<Object> _decorate(ImageProvider<Object> source) {
    if (_source != source || _request?.controller != widget.controller) {
      _request?.cancel();
      _source = source;
      _request = _CodexImageRequest(widget.controller);
      _provider = _CodexImageProvider(source, _request!);
    }
    return _provider!;
  }

  @override
  void dispose() {
    _request?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_decorate);
}

class _CodexImageRequest {
  _CodexImageRequest(this.controller);

  final CodexImageLoadController controller;
  bool _canceled = false;
  bool get active => !_canceled && !controller._disposed;

  void cancel() {
    _canceled = true;
    controller._waiting.remove(this);
  }
}

@immutable
class _CodexImageProvider extends ImageProvider<Object> {
  const _CodexImageProvider(this.source, this.request);

  final ImageProvider<Object> source;
  final _CodexImageRequest request;

  @override
  Future<Object> obtainKey(ImageConfiguration configuration) =>
      source.obtainKey(configuration);

  @override
  ImageStreamCompleter loadImage(Object key, ImageDecoderCallback decode) =>
      source.loadImage(key, decode);

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    Object key,
    ImageErrorListener handleError,
  ) {
    if (!request.active) return;
    final cache = PaintingBinding.instance.imageCache;
    bool tracked() {
      final status = cache.statusForKey(key);
      return status.pending || status.keepAlive || status.live;
    }

    void resolve() {
      if (!request.active) return;
      if (request.controller._paused && !tracked()) {
        request.controller._enqueue(request, resolve);
        return;
      }
      try {
        source.resolveStreamForKey(configuration, stream, key, handleError);
      } catch (error, stack) {
        handleError(error, stack);
      }
    }

    // Decoded cache hits remain visible while moving. Sharing an existing
    // in-flight completer also starts no new download/decode.
    if (stream.completer != null || tracked()) {
      resolve();
    } else {
      request.controller._enqueue(request, resolve);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _CodexImageProvider &&
      other.source == source &&
      identical(other.request, request);

  @override
  int get hashCode => Object.hash(source, request);
}
