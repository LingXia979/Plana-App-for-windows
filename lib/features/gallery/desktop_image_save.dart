import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/store/atomic_file.dart';
import 'models.dart';
import 'save_pipeline.dart';
import 'save_settings.dart';

final desktopSaveDirectoryProvider =
    NotifierProvider<DesktopSaveDirectory, String?>(DesktopSaveDirectory.new);

class DesktopSaveDirectory extends Notifier<String?> {
  static const preferenceKey = 'desktop_manual_save_directory';

  @override
  String? build() => ref.read(prefsStoreProvider).get(preferenceKey);

  Future<void> select(String directory) async {
    await ref
        .read(prefsStoreProvider)
        .write(key: preferenceKey, value: directory);
    if (ref.mounted) state = directory;
  }
}

/// Manual export is separate from automatic gallery archiving. Reserve a new
/// name for each click; repeated saves never replace an earlier export.
Future<File> saveDesktopImage({
  required String directory,
  required ResultImage image,
  required Uint8List bytes,
  required SaveSettings settings,
}) async {
  final folder = Directory(directory);
  if (!await folder.exists()) {
    throw FileSystemException('保存文件夹不存在，请重新选择', directory);
  }
  final output = await processForSave(bytes, settings);
  final id = image.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final stem = 'plana_${id}_${image.seed}';
  for (var i = 0; i < 10000; i++) {
    final suffix = i == 0 ? '' : '_${i + 1}';
    final file = File('${folder.path}/$stem$suffix.${settings.format.name}');
    final pending = File('${file.path}.part');
    if (await file.exists() || await pending.exists()) continue;
    try {
      await pending.create(exclusive: true);
    } on FileSystemException {
      if (await pending.exists()) continue;
      rethrow;
    }
    try {
      await pending.writeAsBytes(output, flush: true);
      if (await file.exists()) continue;
      await commitPendingFile(pending, file);
      return file;
    } finally {
      if (await pending.exists()) await pending.delete();
    }
  }
  throw StateError('无法分配新的图片文件名');
}
