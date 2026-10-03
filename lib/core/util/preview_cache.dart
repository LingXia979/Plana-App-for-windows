import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../store/atomic_file.dart';

/// Bounded background work shared by directory scanning and visible previews.
/// No image decode, base64 decode or JSON parsing runs on the UI isolate.
class PreviewWorkQueue {
  static final _tails = [Future<void>.value(), Future<void>.value()];
  static int _next = 0;
  static Future<T> run<T>(FutureOr<T> Function() work) {
    final lane = _next++ % _tails.length;
    final result = _tails[lane].then((_) => Isolate.run(work));
    _tails[lane] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

Uint8List fitPreviewPng(Uint8List bytes, {int maxEdge = 420}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('无法读取预览图片');
  final oriented = img.bakeOrientation(decoded);
  final longest = oriented.width > oriented.height
      ? oriented.width
      : oriented.height;
  final resized = longest <= maxEdge
      ? oriented
      : img.copyResize(
          oriented,
          width: oriented.width >= oriented.height ? maxEdge : null,
          height: oriented.height > oriented.width ? maxEdge : null,
          interpolation: img.Interpolation.average,
        );
  return img.encodePng(resized);
}

Future<String?> _buildPreview(String source, String output) async {
  try {
    Uint8List bytes;
    if (source.toLowerCase().endsWith('.naiv4vibe')) {
      final raw = jsonDecode(await File(source).readAsString()) as Map;
      final data = raw['image'] ?? raw['thumbnail'];
      if (data is! String || data.isEmpty) return null;
      bytes = base64Decode(
        data.startsWith('data:') ? data.split(',').last : data,
      );
    } else {
      bytes = await File(source).readAsBytes();
    }
    await writeBytesAtomic(File(output), fitPreviewPng(bytes));
    return output;
  } catch (_) {
    return null;
  }
}

class PreviewCache {
  PreviewCache(this.directory);
  final Directory directory;
  final _pending = <String, Future<String?>>{};

  Future<String?> fileFor(String source) async {
    final stat = await File(source).stat();
    if (stat.type != FileSystemEntityType.file) return null;
    final key = sha256
        .convert(
          utf8.encode(
            'fit-v1|$source|${stat.size}|${stat.modified.microsecondsSinceEpoch}',
          ),
        )
        .toString();
    final output = '${directory.path}/$key.png';
    if (await File(output).exists()) return output;
    final existing = _pending[key];
    if (existing != null) return existing;
    final task = buildPreviewInBackground(source, output);
    _pending[key] = task;
    try {
      return await task;
    } finally {
      _pending.removeWhere((k, _) => k == key);
    }
  }
}

final previewCacheProvider = FutureProvider<PreviewCache>((ref) async {
  final root = await getApplicationSupportDirectory();
  return PreviewCache(Directory('${root.path}/desktop_previews'));
});

final filePreviewProvider = FutureProvider.autoDispose.family<String?, String>((
  ref,
  path,
) async {
  final cache = await ref.watch(previewCacheProvider.future);
  return cache.fileFor(path);
});

class FittedFilePreview extends ConsumerWidget {
  const FittedFilePreview(this.file, {super.key});
  final File file;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(filePreviewProvider(file.path));
    final path = preview.value;
    if (path == null) {
      return Center(
        child: Icon(
          preview.isLoading ? Icons.image_outlined : Icons.data_object,
          size: 28,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      );
    }
    return Image.file(
      File(path),
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) =>
          const Center(child: Icon(Icons.broken_image_outlined)),
    );
  }
}

Future<String?> buildPreviewInBackground(String source, String output) =>
    PreviewWorkQueue.run(() => _buildPreview(source, output));
