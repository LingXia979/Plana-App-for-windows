import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../core/store/atomic_file.dart';
import '../../core/util/preview_cache.dart';
import 'naiv4vibe_codec.dart';

String _digest(String text) => sha256.convert(utf8.encode(text)).toString();

class FolderVibe {
  const FolderVibe({
    required this.source,
    required this.fingerprint,
    required this.ordinal,
    required this.id,
    required this.name,
    required this.hasImage,
    required this.models,
    required this.strength,
    required this.infoExtracted,
    this.preview,
    this.tags = const [],
    this.contentKey = '',
  });
  final String source, fingerprint, id, name;
  final int ordinal;
  final bool hasImage;
  final List<String> models, tags;
  final String contentKey;
  final double strength, infoExtracted;
  final String? preview;
  String get key => '$source#$ordinal';
  Map<String, dynamic> toJson() => {
    'source': source,
    'fingerprint': fingerprint,
    'ordinal': ordinal,
    'id': id,
    'name': name,
    'hasImage': hasImage,
    'models': models,
    'tags': tags,
    'strength': strength,
    'ie': infoExtracted,
    'preview': preview,
    'contentKey': contentKey,
  };
  factory FolderVibe.fromJson(Map<String, dynamic> j) => FolderVibe(
    source: j['source'] as String,
    fingerprint: j['fingerprint'] as String,
    ordinal: j['ordinal'] as int,
    id: j['id'] as String,
    name: j['name'] as String,
    hasImage: j['hasImage'] as bool,
    models: (j['models'] as List).cast<String>(),
    tags: (j['tags'] as List).cast<String>(),
    strength: (j['strength'] as num).toDouble(),
    infoExtracted: (j['ie'] as num).toDouble(),
    preview: j['preview'] as String?,
    contentKey: j['contentKey'] as String? ?? '',
  );
}

String _fingerprint(FileStat stat) =>
    '${stat.size}:${stat.modified.microsecondsSinceEpoch}';

typedef FolderRead = ({List<FolderVibe> entries, bool cached, bool invalid});

/// Cache only lightweight metadata and small previews; the originals and full
/// encodings stay in the user's folder. A bad file is cached too until it changes.
Future<FolderRead> readFolderVibes(String source, String cacheRoot) async {
  final stat = await File(source).stat();
  final fingerprint = _fingerprint(stat);
  final cacheKey = _digest('v2|$source|$fingerprint');
  final index = File('$cacheRoot/$cacheKey.json');
  try {
    final cached = jsonDecode(await index.readAsString()) as Map;
    final entries = (cached['entries'] as List)
        .map((j) => FolderVibe.fromJson((j as Map).cast<String, dynamic>()))
        .toList();
    if (entries.every(
      (e) => e.preview == null || File(e.preview!).existsSync(),
    )) {
      return (
        entries: entries,
        cached: true,
        invalid: cached['invalid'] == true,
      );
    }
  } catch (_) {}
  final entries = <FolderVibe>[];
  var invalid = false;
  try {
    final parsed = parseVibeFileText(await File(source).readAsString());
    for (var i = 0; i < parsed.length; i++) {
      final p = parsed[i];
      final name = p.name.isEmpty
          ? '${path.basenameWithoutExtension(source)}${parsed.length > 1 ? ' · ${i + 1}' : ''}'
          : p.name;
      String? preview;
      // Prefer an embedded thumbnail; fall back to the original when missing or malformed.
      for (final candidate in [p.thumbnailDataUrl, p.imageBase64]) {
        if (candidate == null) continue;
        try {
          final bytes = base64Decode(
            candidate.startsWith('data:')
                ? candidate.split(',').last
                : candidate,
          );
          final target = '$cacheRoot/$cacheKey-$i.png';
          await writeBytesAtomic(File(target), fitPreviewPng(bytes));
          preview = target;
          break;
        } catch (_) {}
      }
      final id = p.id.isNotEmpty ? p.id : _digest(jsonEncode(p.raw));
      entries.add(
        FolderVibe(
          source: source,
          fingerprint: fingerprint,
          ordinal: i,
          id: id,
          name: name,
          hasImage: p.imageBase64 != null,
          models: p.supportedModelKeys,
          tags: p.tags,
          strength: (p.defaultStrength ?? .6).clamp(0, 1),
          infoExtracted: (p.defaultInfoExtracted ?? 1).clamp(0, 1),
          preview: preview,
          contentKey: _digest(jsonEncode(p.raw)),
        ),
      );
    }
  } catch (_) {
    invalid = true;
  }
  await writeStringAtomic(
    index,
    jsonEncode({
      'entries': entries.map((e) => e.toJson()).toList(),
      'invalid': invalid,
    }),
  );
  return (entries: entries, cached: false, invalid: invalid);
}

typedef FolderVibeData = ({
  Uint8List? image,
  String? imageHash,
  Map<String, String>? encodedByModel,
  double infoExtracted,
  List<VibeEncodingItem> encodings,
});

/// All models in an encoding-only item must share exactly the selected IE.
/// In particular Full and Curated are never substituted for one another.
FolderVibeData dataForParsedVibe(
  ParsedVibe parsed,
  String modelKey,
  double preferredIE,
) {
  if (parsed.imageBase64 case final String image) {
    final bytes = base64Decode(
      image.startsWith('data:') ? image.split(',').last : image,
    );
    return (
      image: bytes,
      imageHash: sha256.convert(bytes).toString(),
      encodedByModel: null,
      infoExtracted: preferredIE,
      encodings: parsed.encodingItems,
    );
  }
  final candidates =
      parsed.encodingItems
          .where(
            (e) =>
                e.modelKey == modelKey &&
                e.infoExtracted != null &&
                e.infoExtracted!.isFinite,
          )
          .toList()
        ..sort(
          (a, b) => (a.infoExtracted! - preferredIE).abs().compareTo(
            (b.infoExtracted! - preferredIE).abs(),
          ),
        );
  if (candidates.isEmpty) throw const FormatException('当前模型没有带信息提取量的可用编码');
  final ie = candidates.first.infoExtracted!;
  final byModel = <String, String>{
    for (final e in parsed.encodingItems)
      if (e.infoExtracted != null && (e.infoExtracted! - ie).abs() < 1e-9)
        e.modelKey: e.encoding,
  };
  return (
    image: null,
    imageHash: null,
    encodedByModel: byModel,
    infoExtracted: ie,
    encodings: const [],
  );
}

Future<FolderVibeData> loadFolderVibe(FolderVibe entry, String modelKey) async {
  if (_fingerprint(await File(entry.source).stat()) != entry.fingerprint) {
    throw const FormatException('文件已变化，请刷新文件夹后重新选择');
  }
  final parsed = parseVibeFileText(await File(entry.source).readAsString());
  return dataForParsedVibe(
    parsed[entry.ordinal],
    modelKey,
    entry.infoExtracted,
  );
}

class VibeFolderState {
  const VibeFolderState({
    this.directory,
    this.entries = const [],
    this.scanning = false,
    this.done = 0,
    this.total = 0,
    this.skipped = 0,
    this.cached = 0,
    this.message,
  });
  final String? directory, message;
  final List<FolderVibe> entries;
  final bool scanning;
  final int done, total, skipped, cached;
}

final vibeFolderRootProvider = FutureProvider<Directory>((ref) async {
  final root = await getApplicationSupportDirectory();
  return Directory('${root.path}/vibe_folders');
});

final vibeFolderProvider =
    AsyncNotifierProvider<VibeFolderLibrary, VibeFolderState>(
      VibeFolderLibrary.new,
    );

class VibeFolderLibrary extends AsyncNotifier<VibeFolderState> {
  late Directory _root;
  int _generation = 0;
  bool _disposed = false;

  @override
  Future<VibeFolderState> build() async {
    ref.onDispose(() {
      _disposed = true;
      _generation++;
    });
    _root = await ref.read(vibeFolderRootProvider.future);
    try {
      final j =
          jsonDecode(await File('${_root.path}/folder.json').readAsString())
              as Map;
      final directory = j['directory'] as String?;
      if (directory != null) {
        // Return cached metadata first; page open schedules an incremental refresh.
        final entries = (j['entries'] as List? ?? [])
            .map((e) => FolderVibe.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
        return VibeFolderState(directory: directory, entries: entries);
      }
    } catch (_) {}
    return const VibeFolderState();
  }

  Future<void> choose(String directory) async {
    await future;
    cancel();
    state = AsyncData(VibeFolderState(directory: directory));
    await _save();
    await refresh();
  }

  Future<void> _save() async {
    final current = state.value;
    await writeStringAtomic(
      File('${_root.path}/folder.json'),
      jsonEncode({
        'directory': current?.directory,
        'entries': current?.entries.map((e) => e.toJson()).toList() ?? [],
      }),
    );
  }

  void cancel() {
    _generation++;
    final current = state.value;
    if (current == null || !current.scanning) return;
    state = AsyncData(
      VibeFolderState(
        directory: current.directory,
        entries: current.entries,
        done: current.done,
        total: current.total,
        cached: current.cached,
        skipped: current.skipped,
        message: '已停止扫描',
      ),
    );
  }

  Future<void> disconnect() async {
    cancel();
    state = const AsyncData(VibeFolderState());
    await _save();
  }

  Future<void> refresh() async {
    await future;
    final initial = state.value!;
    final directory = initial.directory;
    if (directory == null || initial.scanning) return;
    final generation = ++_generation;
    bool alive() => !_disposed && generation == _generation;
    state = AsyncData(
      VibeFolderState(
        directory: directory,
        entries: initial.entries,
        scanning: true,
      ),
    );
    try {
      final files = <String>[];
      await for (final entity in Directory(
        directory,
      ).list(followLinks: false)) {
        if (!alive()) return;
        if (entity is File &&
            const [
              '.json',
              '.naiv4vibe',
              '.naiv4vibebundle',
            ].contains(path.extension(entity.path).toLowerCase())) {
          files.add(entity.path);
        }
      }
      files.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      final entries = <FolderVibe>[];
      final contents = <String>{};
      var skipped = 0, cached = 0;
      final cacheRoot = '${_root.path}/cache';
      for (var i = 0; i < files.length; i++) {
        final source = files[i];
        try {
          final result = await readFolderVibesInBackground(source, cacheRoot);
          if (!alive()) return;
          if (result.invalid) skipped++;
          if (result.cached) cached++;
          for (final e in result.entries) {
            // Same image ID can carry different models or IE encodings. Only
            // collapse identical records so those useful variants stay visible.
            if (contents.add(e.contentKey)) entries.add(e);
          }
        } catch (_) {
          skipped++;
        }
        if (!alive()) return;
        // At most one update per file, with small immutable metadata only.
        state = AsyncData(
          VibeFolderState(
            directory: directory,
            entries: initial.entries.isEmpty
                ? List.unmodifiable(entries)
                : initial.entries,
            scanning: true,
            done: i + 1,
            total: files.length,
            skipped: skipped,
            cached: cached,
          ),
        );
      }
      if (!alive()) return;
      state = AsyncData(
        VibeFolderState(
          directory: directory,
          entries: List.unmodifiable(entries),
          done: files.length,
          total: files.length,
          skipped: skipped,
          cached: cached,
        ),
      );
      await _save();
    } catch (_) {
      if (alive()) {
        state = AsyncData(
          VibeFolderState(
            directory: directory,
            entries: initial.entries,
            message: '文件夹暂时无法读取，请检查路径后重试',
          ),
        );
      }
    }
  }
}

Future<FolderRead> readFolderVibesInBackground(
  String source,
  String cacheRoot,
) => PreviewWorkQueue.run(() => readFolderVibes(source, cacheRoot));
Future<FolderVibeData> loadFolderVibeInBackground(
  FolderVibe entry,
  String modelKey,
) => PreviewWorkQueue.run(() => loadFolderVibe(entry, modelKey));
