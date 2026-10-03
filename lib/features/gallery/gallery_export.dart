import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'desktop_image_save.dart';
import 'gallery_store.dart';
import 'models.dart';
import 'save_settings.dart';

enum GalleryExportCleanup { none, selected, keepSamples, deleteAlbum }

enum GalleryExportFolder { none, date, album }

class GalleryExportCanceled implements Exception {
  const GalleryExportCanceled();

  @override
  String toString() => '已停止导出';
}

class GalleryExportOptions {
  const GalleryExportOptions({
    required this.directory,
    this.folder = GalleryExportFolder.none,
    this.cleanup = GalleryExportCleanup.none,
  });

  final String directory;
  final GalleryExportFolder folder;
  final GalleryExportCleanup cleanup;
}

/// A snapshot for the confirmation UI. Preparing it never changes gallery data
/// or creates output folders. Only [items] are exported; cleanup may cover the
/// whole [scopeIds] snapshot, including images which were not selected.
class GalleryExportPlan {
  GalleryExportPlan._({
    required List<ResultImage> items,
    required Set<String> scopeIds,
    required Set<String> deleteIds,
    required this.retainedCount,
    required this.unknownCount,
    required this.directory,
    required this.options,
    required this.albumId,
    required this.title,
  }) : items = List.unmodifiable(items),
       scopeIds = Set.unmodifiable(scopeIds),
       deleteIds = Set.unmodifiable(deleteIds);

  final List<ResultImage> items;
  final Set<String> scopeIds;
  final Set<String> deleteIds;
  final int retainedCount;
  final int unknownCount;
  final String directory;
  final GalleryExportOptions options;
  final String? albumId;
  final String title;
}

/// Saving and cleanup are deliberately separate. The caller may apply
/// [cleanupIds] only after checking that the gallery snapshot is still current.
class GalleryExportReport {
  GalleryExportReport._({
    required Set<String> savedIds,
    required Set<String> failedIds,
    required Set<String> cleanupIds,
    required Map<String, String> errors,
    required Map<String, String> savedPaths,
    required this.directory,
    required this.canceled,
  }) : savedIds = Set.unmodifiable(savedIds),
       failedIds = Set.unmodifiable(failedIds),
       cleanupIds = Set.unmodifiable(cleanupIds),
       errors = Map.unmodifiable(errors),
       savedPaths = Map.unmodifiable(savedPaths);

  final Set<String> savedIds;
  final Set<String> failedIds;
  final Set<String> cleanupIds;
  final Map<String, String> errors;
  final Map<String, String> savedPaths;
  final String directory;
  final bool canceled;
}

Future<GalleryExportPlan> prepareGalleryExport({
  required List<ResultImage> selected,
  required List<ResultImage> albumImages,
  required String? albumId,
  required String albumName,
  required GalleryExportOptions options,
  required GalleryStore store,
  DateTime? now,
  bool Function()? canceled,
}) async {
  _checkCanceled(canceled);
  if (options.directory.trim().isEmpty) {
    throw ArgumentError.value(options.directory, 'directory', '请选择导出文件夹');
  }
  final scope = <String, ResultImage>{};
  for (final image in albumImages) {
    scope.putIfAbsent(image.id, () => image);
  }
  final selectedIds = <String>{};
  final items = <ResultImage>[];
  for (final image in selected) {
    if (scope.containsKey(image.id) && selectedIds.add(image.id)) {
      // The selected copy can still have its PNG cached after the grid has
      // released its own copy. Album membership always comes from scope.
      items.add(image);
    }
  }
  final deleteIds = <String>{};
  var unknownCount = 0;
  switch (options.cleanup) {
    case GalleryExportCleanup.none:
      break;
    case GalleryExportCleanup.selected:
      deleteIds.addAll(selectedIds);
    case GalleryExportCleanup.deleteAlbum:
      deleteIds.addAll(scope.keys);
    case GalleryExportCleanup.keepSamples:
      // Results can be visible before their queued snapshot finishes saving.
      await store.idle;
      _checkCanceled(canceled);
      final newest = <String, ResultImage>{};
      for (final image in scope.values) {
        _checkCanceled(canceled);
        final key = await _sampleKey(image, store, canceled);
        _checkCanceled(canceled);
        if (key == null) {
          unknownCount++;
          continue;
        }
        final previous = newest[key];
        if (previous == null) {
          newest[key] = image;
        } else if (_isNewer(image, previous)) {
          deleteIds.add(previous.id);
          newest[key] = image;
        } else {
          deleteIds.add(image.id);
        }
      }
  }
  final base = p.normalize(p.absolute(options.directory));
  final date = now ?? DateTime.now();
  final child = switch (options.folder) {
    GalleryExportFolder.none => null,
    GalleryExportFolder.date =>
      '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}',
    GalleryExportFolder.album => _windowsFolderName(albumName),
  };
  _checkCanceled(canceled);
  return GalleryExportPlan._(
    items: items,
    scopeIds: scope.keys.toSet(),
    deleteIds: deleteIds,
    retainedCount: scope.length - deleteIds.length,
    unknownCount: unknownCount,
    directory: child == null ? base : p.join(base, child),
    options: options,
    albumId: albumId,
    title: albumName,
  );
}

Future<GalleryExportReport> exportGalleryImages(
  GalleryExportPlan plan, {
  required GalleryStore store,
  required SaveSettings settings,
  bool Function()? canceled,
  void Function(int done, int total)? onProgress,
}) async {
  final savedIds = <String>{};
  final failedIds = <String>{};
  final errors = <String, String>{};
  final savedPaths = <String, String>{};
  var wasCanceled = canceled?.call() ?? false;
  String? directoryError;
  if (!wasCanceled && plan.items.isNotEmpty) {
    try {
      await _ensureOutputDirectory(plan);
      await store.idle;
    } catch (error) {
      directoryError = error.toString();
    }
  }
  var done = 0;
  for (final image in plan.items) {
    if (wasCanceled || (canceled?.call() ?? false)) {
      wasCanceled = true;
      break;
    }
    try {
      if (directoryError != null) throw StateError(directoryError);
      final bytes = image.bytes ?? await store.readImage(image.id);
      if (bytes == null || bytes.isEmpty) {
        throw StateError('图片原文件缺失或为空');
      }
      final file = await saveDesktopImage(
        directory: plan.directory,
        image: image,
        bytes: bytes,
        settings: settings,
      );
      // Reading the committed output, rather than trusting the write call,
      // ensures cleanup never relies on an absent/empty export.
      if (!await file.exists() ||
          await file.openRead().fold<int>(0, (n, bytes) => n + bytes.length) ==
              0) {
        throw StateError('导出文件未通过写入验证');
      }
      savedIds.add(image.id);
      savedPaths[image.id] = file.path;
    } catch (error) {
      failedIds.add(image.id);
      errors[image.id] = error.toString();
    }
    done++;
    onProgress?.call(done, plan.items.length);
  }
  wasCanceled = wasCanceled || (canceled?.call() ?? false);
  final cleanupIds = <String>{};
  if (!wasCanceled && plan.items.isNotEmpty) {
    if (plan.options.cleanup == GalleryExportCleanup.selected) {
      cleanupIds.addAll(plan.deleteIds.intersection(savedIds));
    } else if (savedIds.length == plan.items.length && failedIds.isEmpty) {
      cleanupIds.addAll(plan.deleteIds);
    }
  }
  return GalleryExportReport._(
    savedIds: savedIds,
    failedIds: failedIds,
    cleanupIds: cleanupIds,
    errors: errors,
    savedPaths: savedPaths,
    directory: plan.directory,
    canceled: wasCanceled,
  );
}

Future<void> _ensureOutputDirectory(GalleryExportPlan plan) async {
  final base = Directory(p.normalize(p.absolute(plan.options.directory)));
  if (!await base.exists()) {
    throw FileSystemException('导出文件夹不存在，请重新选择', base.path);
  }
  if (plan.options.folder == GalleryExportFolder.none) return;
  if (!p.isWithin(base.path, plan.directory) ||
      p.dirname(plan.directory) != base.path) {
    throw FileSystemException('导出子文件夹必须位于所选文件夹内', plan.directory);
  }
  final child = Directory(plan.directory);
  final resolvedBase = await base.resolveSymbolicLinks();
  if (await child.exists()) {
    if (!p.isWithin(resolvedBase, await child.resolveSymbolicLinks())) {
      throw FileSystemException('导出子文件夹指向所选文件夹以外', child.path);
    }
  } else {
    await child.create();
  }
  if (!p.isWithin(resolvedBase, await child.resolveSymbolicLinks())) {
    throw FileSystemException('导出子文件夹指向所选文件夹以外', child.path);
  }
}

String _windowsFolderName(String name) {
  var result = name
      .replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  result = String.fromCharCodes(result.runes.take(100));
  result = result.replaceAll(RegExp(r'[. ]+$'), '');
  if (result.isEmpty || result == '.' || result == '..') result = '图库';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])$',
    caseSensitive: false,
  ).hasMatch(result.split('.').first.trimRight())) {
    result = '_$result';
  }
  return result;
}

bool _isNewer(ResultImage candidate, ResultImage current) {
  if (candidate.createdAt != current.createdAt) {
    return candidate.createdAt > current.createdAt;
  }
  // Batch results can share a millisecond. The gallery's sequence is the next
  // available ordering signal; otherwise keep its existing newest-first order.
  final a = RegExp(r'^gen(\d+)$').firstMatch(candidate.id);
  final b = RegExp(r'^gen(\d+)$').firstMatch(current.id);
  return a != null && b != null && int.parse(a[1]!) > int.parse(b[1]!);
}

void _checkCanceled(bool Function()? canceled) {
  if (canceled?.call() ?? false) throw const GalleryExportCanceled();
}

Future<String?> _sampleKey(
  ResultImage image,
  GalleryStore store,
  bool Function()? canceled,
) async {
  if (image.inpaintHistoryCleared || image.width <= 0 || image.height <= 0) {
    return null;
  }
  try {
    final document = await store.readInputRaw(image.id);
    _checkCanceled(canceled);
    if (document?['inpaintHistoryCleared'] == true) return null;
    final state = _groupingState(document?['state']);
    if ((image.badge == ResultBadge.inpaint || image.inpaintFrom != null) &&
        state['inpaint'] == null) {
      return null;
    }
    final bytes = image.bytes ?? await store.readImage(image.id);
    _checkCanceled(canceled);
    if (bytes == null) return null;
    final texts = _pngGenerationText(bytes);
    final comment = _object(jsonDecode(texts['comment'] ?? ''));
    // Snapshots precede preset application. Both effective prompts must be
    // present in the actual PNG, or different presets could be merged.
    String? caption(String key) {
      final value = comment[key];
      if (value is! Map || value['caption'] is! Map) return null;
      final base = (value['caption'] as Map)['base_caption'];
      return base is String ? base : null;
    }

    final positive = comment['prompt'] ?? caption('v4_prompt');
    final negative =
        comment['uc'] ??
        comment['negative_prompt'] ??
        caption('v4_negative_prompt');
    if (positive is! String ||
        negative is! String ||
        !_finiteNumber(comment['steps']) ||
        !_finiteNumber(comment['scale']) ||
        comment['sampler'] is! String ||
        !_positiveNumber(comment['width']) ||
        !_positiveNumber(comment['height'])) {
      return null;
    }
    final key = {
      'state': state,
      'effective': _withoutRunFields(comment),
      if (texts['source'] != null) 'source': texts['source'],
      'width': image.width,
      'height': image.height,
      'badge': image.badge.name,
    };
    return sha256.convert(utf8.encode(jsonEncode(_canonical(key)))).toString();
  } on GalleryExportCanceled {
    rethrow;
  } catch (_) {
    // Old/missing/incomplete metadata has no safe duplicate key. Each such
    // result is retained; never materialize GenerateState or write blobs here.
    return null;
  }
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Missing complete generation parameters');
  }
  return value;
}

bool _finiteNumber(Object? value) => value is num && value.isFinite;
bool _positiveNumber(Object? value) =>
    _finiteNumber(value) && (value as num) > 0;
bool _hash(Object? value) =>
    value is String && RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(value);

Map<String, dynamic> _groupingState(Object? raw) {
  final state = _object(raw);
  final params = _object(state['params']);
  if (state['prompt'] is! String ||
      state['negativePrompt'] is! String ||
      params['model'] is! String ||
      (params['model'] as String).isEmpty ||
      !_positiveNumber(params['width']) ||
      !_positiveNumber(params['height']) ||
      !_positiveNumber(params['steps']) ||
      !_finiteNumber(params['cfg']) ||
      !_finiteNumber(params['cfgRescale']) ||
      params['sampler'] is! String ||
      params['noiseSchedule'] is! String ||
      params['varietyPlus'] is! bool ||
      params['normalizeVibe'] is! bool ||
      params['useCoords'] is! bool) {
    throw const FormatException('Incomplete generation snapshot');
  }
  final result = Map<String, dynamic>.of(state)
    ..remove('anlas')
    ..remove('openPanels')
    ..remove('promptRaw')
    ..remove('negativePromptRaw');
  result['params'] = _withoutRunFields({
    for (final entry in params.entries)
      if (entry.key != 'modalMem' && entry.key != 'loop')
        entry.key: entry.value,
  });
  for (final field in [
    'characters',
    'vibes',
    'charRefs',
    'kreaStyleRefs',
    'loras',
  ]) {
    final values = state[field];
    if (values == null && (field == 'kreaStyleRefs' || field == 'loras')) {
      result[field] = <Object>[];
      continue;
    }
    if (values is! List) throw const FormatException('Missing reference list');
    final cleaned = <Object>[];
    for (final value in values) {
      final item = _object(value);
      if (item['enabled'] == false) continue;
      if (item['enabled'] is! bool) {
        throw const FormatException('Incomplete reference');
      }
      final next = Map<String, dynamic>.of(item)..remove('enabled');
      if (field == 'characters') {
        if (item['positive'] is! String || item['negative'] is! String) {
          throw const FormatException('Incomplete character prompts');
        }
        if ((item['positive'] as String).trim().isEmpty) continue;
        next
          ..remove('positiveRaw')
          ..remove('negativeRaw')
          ..remove('activeTab');
      } else if (field == 'loras') {
        if (item['name'] is! String || !_finiteNumber(item['weight'])) {
          throw const FormatException('Incomplete LoRA');
        }
        next
          ..remove('displayName')
          ..remove('previewUrl')
          ..remove('triggerWords');
      } else {
        final encoded = item['encodedByModel'];
        final hasEncoded =
            field == 'vibes' &&
            encoded is Map &&
            encoded.isNotEmpty &&
            encoded.values.every((v) => v is String && v.isNotEmpty);
        if (item['image'] == null && !hasEncoded) continue;
        if (!_hash(item['image']) && !hasEncoded) {
          throw const FormatException('Incomplete reference image');
        }
        if (field != 'kreaStyleRefs' &&
            (!_finiteNumber(item['strength']) ||
                !_finiteNumber(item['infoExtracted']))) {
          throw const FormatException('Incomplete reference weights');
        }
        if (field == 'charRefs' && item['mode'] is! String) {
          throw const FormatException('Incomplete character reference mode');
        }
        if (field == 'kreaStyleRefs' &&
            !_finiteNumber(state['kreaStyleRefWeight'])) {
          throw const FormatException('Incomplete style reference weight');
        }
        if (_hash(item['image'])) next.remove('encodedByModel');
        next.remove('sourceId');
      }
      next.remove('id');
      if (field != 'loras') next.remove('name');
      cleaned.add(next);
    }
    result[field] = cleaned;
  }
  final img2img = state['img2img'];
  if (img2img != null) {
    final input = _object(img2img);
    if (!_hash(input['image']) ||
        !_finiteNumber(input['strength']) ||
        !_finiteNumber(input['noise'])) {
      throw const FormatException('Incomplete image-to-image parameters');
    }
  }
  final inpaint = state['inpaint'];
  if (inpaint != null) {
    final input = _object(inpaint);
    if (!_hash(input['image']) ||
        !_hash(input['mask']) ||
        !_finiteNumber(input['strength'])) {
      throw const FormatException('Incomplete inpainting parameters');
    }
    if (input['paste'] != null) {
      final paste = _object(input['paste']);
      if (!_hash(paste['original']) ||
          !const [
            'sendX',
            'sendY',
            'tightX',
            'tightY',
            'tightW',
            'tightH',
            'outW',
            'outH',
          ].every((key) => paste[key] is int) ||
          (paste['focusMask'] != null && !_hash(paste['focusMask']))) {
        throw const FormatException('Incomplete inpainting paste parameters');
      }
      if (paste['focus'] != null) {
        final focus = _object(paste['focus']);
        if (!const [
          'x',
          'y',
          'width',
          'height',
          'context',
        ].every((key) => focus[key] is int)) {
          throw const FormatException('Incomplete inpainting focus parameters');
        }
      }
    }
    result['inpaint'] = Map<String, dynamic>.of(input)
      ..remove('sourceId')
      ..remove(
        'grid',
      ); // Editor grid is redundant with the actual request mask.
  }
  return result;
}

Object? _withoutRunFields(Object? value) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        if (!const {
          'seed',
          'extra_noise_seed',
          'batch_index',
          'batchIndex',
          'generation_time',
          'Generation time',
        }.contains(entry.key))
          entry.key: _withoutRunFields(entry.value),
    };
  }
  if (value is List) return [for (final item in value) _withoutRunFields(item)];
  return value;
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return [for (final item in value) _canonical(item)];
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return value;
}

const _maxTextBytes = 4 * 1024 * 1024;

/// Only inspect text chunks. Decoding pixels/LSB would make album preparation
/// expensive, so images with only hidden metadata are safely kept individually.
Map<String, String> _pngGenerationText(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 20) throw const FormatException('Not a PNG');
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) throw const FormatException('Not a PNG');
  }
  final data = ByteData.sublistView(bytes);
  final result = <String, String>{};
  var offset = 8;
  while (offset + 12 <= bytes.length) {
    final length = data.getUint32(offset);
    final end = offset + 12 + length;
    if (end > bytes.length) throw const FormatException('Truncated PNG');
    final type = ascii.decode(
      Uint8List.sublistView(bytes, offset + 4, offset + 8),
    );
    if (type == 'IEND') return result;
    if (type == 'tEXt' || type == 'iTXt' || type == 'zTXt') {
      if (length > _maxTextBytes) {
        throw const FormatException('Oversized PNG text');
      }
      final chunk = Uint8List.sublistView(bytes, offset + 8, end - 4);
      final separator = chunk.indexOf(0);
      if (separator < 1) throw const FormatException('Invalid PNG keyword');
      final keyword = latin1.decode(chunk.sublist(0, separator)).toLowerCase();
      if (keyword == 'comment' || keyword == 'source') {
        if (getCrc32(Uint8List.sublistView(bytes, offset + 4, end - 4)) !=
            data.getUint32(end - 4)) {
          throw const FormatException('Invalid PNG text checksum');
        }
        var start = separator + 1;
        var compressed = false;
        if (type == 'iTXt') {
          if (start + 2 > chunk.length ||
              chunk[start] > 1 ||
              chunk[start + 1] != 0) {
            throw const FormatException('Invalid PNG text compression');
          }
          compressed = chunk[start] == 1;
          start += 2;
          for (var i = 0; i < 2; i++) {
            final zero = chunk.indexOf(0, start);
            if (zero < 0) throw const FormatException('Invalid PNG text');
            start = zero + 1;
          }
        } else if (type == 'zTXt') {
          if (start >= chunk.length || chunk[start++] != 0) {
            throw const FormatException('Invalid PNG text compression');
          }
          compressed = true;
        }
        var content = Uint8List.sublistView(chunk, start);
        if (compressed) {
          final sink = _LimitedTextSink();
          final decoder = ZLibDecoder().startChunkedConversion(sink);
          decoder.add(content);
          decoder.close();
          content = sink.bytes.takeBytes();
        }
        final text = type == 'iTXt'
            ? utf8.decode(content)
            : latin1.decode(content);
        if (result.containsKey(keyword) && result[keyword] != text) {
          throw const FormatException('Conflicting PNG metadata');
        }
        result[keyword] = text;
      }
    }
    offset = end;
  }
  throw const FormatException('Truncated PNG');
}

class _LimitedTextSink implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (bytes.length + data.length > _maxTextBytes) {
      throw const FormatException('Oversized PNG text');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}
