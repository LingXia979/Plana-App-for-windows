import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'clipboard_image.dart';

/// All native formats derive from this already-processed export, never from
/// a gallery original that could still contain removed metadata.
class PreparedImageTransfer {
  PreparedImageTransfer({required this.bytes, required this.name});

  final Uint8List bytes;
  final String name;
  Future<File>? _file;

  Future<File> file({Directory? temporaryDirectory}) =>
      _file ??= _writeFile(temporaryDirectory);

  Future<File> _writeFile(Directory? temporaryDirectory) async {
    final temp = temporaryDirectory ?? await getTemporaryDirectory();
    final root = Directory(p.join(temp.path, imageTransferCacheName));
    await root.create(recursive: true);
    final expected = p.join(
      await temp.resolveSymbolicLinks(),
      imageTransferCacheName,
    );
    if (!p.equals(await root.resolveSymbolicLinks(), expected)) {
      throw const FileSystemException('图片导出缓存目录无效');
    }
    // Recipients may read later, after another copy/drag or after Plana closes.
    if (_lastSweep == null ||
        DateTime.now().difference(_lastSweep!) > const Duration(hours: 1)) {
      _lastSweep = DateTime.now();
      final clipboard = await DesktopClipboard.read();
      if (clipboard.error == null) {
        await sweepImageTransferCache(root, protectedPaths: clipboard.paths);
      }
    }
    final folder = await root.createTemp('transfer_');
    final file = File(p.join(folder.path, p.basename(name)));
    try {
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } catch (_) {
      if (await file.exists()) await file.delete();
      await folder.delete();
      rethrow;
    }
  }
}

const imageTransferCacheName = 'plana_image_transfer';
DateTime? _lastSweep;

/// Only old, flat export folders are eligible. Never traverse links, delete
/// gallery originals, or expire the current clipboard's file.
Future<void> sweepImageTransferCache(
  Directory root, {
  List<String> protectedPaths = const [],
  DateTime? now,
}) async {
  final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 7));
  try {
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final canonical = await root.resolveSymbolicLinks();
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory ||
          !RegExp(r'^transfer_[\w-]+$').hasMatch(p.basename(entry.path))) {
        continue;
      }
      try {
        if (!p.equals(
          await entry.resolveSymbolicLinks(),
          p.join(canonical, p.basename(entry.path)),
        )) {
          continue;
        }
        final files = await entry.list(followLinks: false).toList();
        if (files.any((file) => file is! File) ||
            files.any(
              (file) => protectedPaths.any((path) => p.equals(path, file.path)),
            )) {
          continue;
        }
        if ((await entry.stat()).modified.isAfter(cutoff)) continue;
        var fresh = false;
        for (final file in files) {
          if ((await file.stat()).modified.isAfter(cutoff)) fresh = true;
        }
        if (fresh) continue;
        for (final file in files) {
          await file.delete();
        }
        await entry.delete();
      } on FileSystemException {
        // A recipient can still have an exported file open.
      }
    }
  } on FileSystemException {
    // Housekeeping must not prevent a new export.
  }
}
