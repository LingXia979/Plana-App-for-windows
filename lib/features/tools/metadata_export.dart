import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/util/png_meta.dart';

/// Export a processed copy. Reserve a new filename so neither a source image
/// nor an earlier export can be overwritten, including simultaneous exports.
Future<File> exportMetadataCopy({
  required Directory directory,
  required String sourceName,
  required Uint8List bytes,
  String? customPrompt,
  Map<String, dynamic>? comment,
  String source = 'Plana',
}) async {
  final output = comment != null
      ? await writeImageMetadataPng(bytes, comment: comment, source: source)
      : customPrompt == null
      ? await cleanImagePng(bytes)
      : await writeCustomMetadataPng(bytes, customPrompt);
  final stem = p
      .basenameWithoutExtension(sourceName)
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  final name =
      '${stem.isEmpty ? 'image' : stem}_${customPrompt == null && comment == null ? 'clean' : 'custom'}';
  for (var i = 0; ; i++) {
    final file = File(
      p.join(directory.path, '$name${i == 0 ? '' : ' ($i)'}.png'),
    );
    try {
      await file.create(exclusive: true);
    } on FileSystemException {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      rethrow;
    }
    try {
      return await file.writeAsBytes(output, flush: true);
    } catch (_) {
      await file.delete();
      rethrow;
    }
  }
}
