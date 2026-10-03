import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../import/image_metadata.dart';
import 'metadata_export.dart';

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();

/// Keep unexposed NovelAI fields (characters, coordinates, model hints, etc.)
/// when a user edits only the visible form. Other formats use normalized fields.
Map<String, dynamic> metadataComment(ImageMetadata? meta) {
  var fields = <String, dynamic>{};
  final raw = meta?.raw;
  if (meta?.isNovelAI == true && raw is Map) {
    final comment = raw['Comment'];
    if (comment is Map) fields = _copy(comment.cast<String, dynamic>());
    if (comment is String) {
      try {
        final decoded = jsonDecode(comment);
        if (decoded is Map) fields = decoded.cast<String, dynamic>();
      } on FormatException {
        // Fall back to the successfully parsed common fields.
      }
    }
  }
  return {
    ...fields,
    'prompt': meta?.prompt ?? '',
    'uc': meta?.negativePrompt ?? '',
    'steps': int.tryParse(meta?.steps ?? '') ?? 28,
    'scale': double.tryParse(meta?.scale ?? '') ?? 5.0,
    'seed': int.tryParse(meta?.seed ?? '') ?? 0,
    'sampler': meta?.sampler ?? 'k_euler_ancestral',
    'noise_schedule': meta?.noiseSchedule ?? 'native',
    'cfg_rescale': double.tryParse(meta?.cfgRescale ?? '') ?? 0.0,
    'strength': fields['strength'] ?? 0.7,
    'noise': fields['noise'] ?? 0.0,
    'sm': fields['sm'] == true,
    'sm_dyn': fields['sm_dyn'] == true,
  };
}

Map<String, dynamic> updateMetadataComment(
  Map<String, dynamic> original,
  Map<String, dynamic> edits,
) {
  final result = _copy(original)..addAll(edits);
  for (final pair in [('v4_prompt', 'prompt'), ('v4_negative_prompt', 'uc')]) {
    final value = result[pair.$1];
    if (value is Map && value['caption'] is Map) {
      value['caption']['base_caption'] = result[pair.$2];
    }
  }
  return result;
}

Future<List<File>> listMetadataImages(Directory directory) async {
  final files = <File>[];
  await for (final entry in directory.list(followLinks: false)) {
    if (entry is File &&
        const {
          '.png',
          '.jpg',
          '.jpeg',
          '.webp',
        }.contains(p.extension(entry.path).toLowerCase())) {
      files.add(entry);
    }
  }
  files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
  return files;
}

class MetadataBatchResult {
  const MetadataBatchResult(this.outputs, this.errors, this.cancelled);
  final List<String> outputs;
  final List<String> errors;
  final bool cancelled;
}

/// A snapshot of one batch. Files are decoded one at a time; cancelling finishes
/// the active image, and never deletes completed copies or touches originals.
class MetadataBatchJob {
  MetadataBatchJob({
    required List<File> files,
    required this.directory,
    Map<String, dynamic>? comment,
    Map<String, Uint8List> memoryImages = const {},
    this.source = 'Plana',
  }) : files = List.unmodifiable(files),
       _memoryImages = Map.unmodifiable(memoryImages),
       _comment = comment == null ? null : _copy(comment);

  final List<File> files;
  final Directory directory;
  final Map<String, dynamic>? _comment;
  // Newly generated history images may still be queued for disk persistence.
  final Map<String, Uint8List> _memoryImages;
  final String source;
  bool _cancelled = false;
  void cancel() => _cancelled = true;

  Future<MetadataBatchResult> run({
    required void Function(int completed, int total, String name) onProgress,
  }) async {
    final outputs = <String>[];
    final errors = <String>[];
    if (!_cancelled) await directory.create(recursive: true);
    for (var i = 0; i < files.length && !_cancelled; i++) {
      final file = files[i];
      try {
        final bytes = _memoryImages[file.path] ?? await file.readAsBytes();
        if (_cancelled) break;
        final output = await exportMetadataCopy(
          directory: directory,
          sourceName: p.basename(file.path),
          bytes: bytes,
          comment: _comment,
          source: source,
        );
        outputs.add(output.path);
      } catch (error) {
        errors.add('${p.basename(file.path)}：$error');
      }
      onProgress(i + 1, files.length, p.basename(file.path));
      await Future<void>.delayed(Duration.zero);
    }
    return MetadataBatchResult(outputs, errors, _cancelled);
  }
}
