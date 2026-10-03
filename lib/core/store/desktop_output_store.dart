import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../features/gallery/models.dart';
import '../../features/generate/models.dart' show isAnimaModel, isKreaModel;
import 'date_album.dart';
import 'atomic_file.dart';
import 'desktop_output_location.dart';

class DesktopOutputMigrationReport {
  const DesktopOutputMigrationReport({
    this.migrated = 0,
    this.issues = const [],
  });

  final int migrated;

  /// A failed pair is kept at its original location. The gallery in AppData is
  /// independent and is never modified by a works-folder migration.
  final List<String> issues;
  bool get hasErrors => issues.isNotEmpty;
}

/// Managed user-visible PNGs and sidecars for the internal gallery records.
/// Opening the app never creates an empty date directory.
class DesktopOutputStore {
  DesktopOutputStore(
    this.root, {
    Iterable<Directory> legacyRoots = const [],
    this.locationIssues = const [],
  }) : legacyRoots = List.unmodifiable(
         {
           for (final directory in legacyRoots)
             if (outputPathKey(directory.path) != outputPathKey(root.path))
               outputPathKey(directory.path): directory,
         }.values,
       );

  final Directory root;
  final List<Directory> legacyRoots;
  final List<String> locationIssues;
  Future<void> _tail = Future.value();
  final _deleted = <String>{};
  Future<DesktopOutputMigrationReport>? _migration;
  DesktopOutputMigrationReport? lastMigration;
  bool get migrating => _migration != null;
  Future<void> get idle async {
    await _migration;
    await _tail;
  }

  Future<T> _queue<T>(Future<T> Function() action) {
    final work = _tail.then((_) => action());
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  String _identity(ResultImage result) => '${result.id}_${result.createdAt}';

  Directory folderFor(String? albumId, DateTime date) {
    if (albumId == null || isDailyAlbum(albumId)) {
      return Directory(
        '${root.path}/${albumId == null ? desktopDayKey(date) : albumId.substring(4)}',
      );
    }
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(albumId)) {
      throw ArgumentError.value(albumId, 'albumId', 'Invalid gallery ID');
    }
    return Directory('${root.path}/图库/$albumId');
  }

  Future<File> save(ResultImage result, {String? albumId}) =>
      _queue(() => _save(result, albumId));

  Future<File> _save(ResultImage result, String? albumId) async {
    if (_deleted.contains(_identity(result))) throw StateError('图片已删除');
    final bytes = result.bytes;
    if (bytes == null || bytes.isEmpty) throw StateError('图片尚未就绪');
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(result.id)) {
      throw ArgumentError('Invalid image ID');
    }
    final folder = folderFor(
      albumId,
      DateTime.fromMillisecondsSinceEpoch(result.createdAt),
    );
    _checkFolder(folder);
    await folder.create(recursive: true);
    _checkFolder(folder);
    final stem = '${result.id}_${result.createdAt}';
    for (var suffix = 0; suffix < 10000; suffix++) {
      final name = '$stem${suffix == 0 ? '' : '_$suffix'}';
      final target = File('${folder.path}/$name.png');
      final sidecar = File('${folder.path}/$name.json');
      final pending = File('${target.path}.part');
      if (_exists(target) || _exists(sidecar) || _exists(pending)) continue;
      try {
        await pending.create(exclusive: true);
      } on FileSystemException {
        if (await pending.exists()) continue;
        rethrow;
      }
      if (await target.exists()) {
        await pending.delete();
        continue;
      }
      try {
        await pending.writeAsBytes(bytes, flush: true);
        // A separately reserved .part name prevents two app instances colliding.
        await commitPendingFile(pending, target);
        final p = result.input?.params;
        final anima = p != null && isAnimaModel(p.model);
        final krea = p != null && isKreaModel(p.model);
        final metadata = <String, Object?>{
          'managedBy': 'plana-gallery',
          'id': result.id,
          'createdAt': result.createdAt,
          'albumId': albumId,
          'width': result.width,
          'height': result.height,
          'seed': result.seed,
          'model': p?.model,
          'prompt': result.input?.prompt,
          'negativePrompt': result.input?.negativePrompt,
          'steps': p?.activeSteps,
          'cfg': anima
              ? p.animaCfg
              : krea
              ? p.kreaCfg
              : p?.cfg,
          'sampler': anima
              ? p.animaSampler
              : krea
              ? p.kreaSampler
              : p?.sampler,
          'scheduler': anima
              ? p.animaScheduler
              : krea
              ? p.kreaScheduler
              : p?.noiseSchedule,
          'cfgRescale': p?.cfgRescale,
        };
        await writeStringAtomic(
          sidecar,
          const JsonEncoder.withIndent('  ').convert(metadata),
        );
        return target;
      } catch (_) {
        if (await pending.exists()) await pending.delete();
        // This name was reserved by this save; a failed sidecar must not leave
        // an untracked managed PNG behind.
        if (await target.exists()) await target.delete();
        rethrow;
      }
    }
    throw StateError('无法分配新的图片文件名');
  }

  static bool _exists(FileSystemEntity file) =>
      FileSystemEntity.typeSync(file.path, followLinks: false) !=
      FileSystemEntityType.notFound;

  void _checkFolder(Directory folder) {
    if (!isPlainOutputDirectory(folder)) {
      throw FileSystemException('作品目录不可写或包含链接，已保留原文件', folder.path);
    }
  }

  /// Enumerate only the date and album folders produced by this store. Avoid
  /// recursive walks into arbitrary user folders even inside the works leaf.
  Stream<File> _sidecars(Directory outputRoot) async* {
    if (!isPlainOutputDirectory(outputRoot)) return;
    final folders = <Directory>[];
    for (final entry in await _listFolder(outputRoot)) {
      if (entry is! Directory || !isPlainOutputDirectory(entry)) continue;
      final name = p.basename(entry.path);
      if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(name)) {
        folders.add(entry);
      } else if (name == '图库') {
        for (final album in await _listFolder(entry)) {
          if (album is Directory &&
              RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(p.basename(album.path)) &&
              isPlainOutputDirectory(album)) {
            folders.add(album);
          }
        }
      }
    }
    for (final folder in folders) {
      if (!isPlainOutputDirectory(folder)) continue;
      // Finish listing before a migrated/deleted pair removes its empty folder.
      final entries = await _listFolder(folder);
      for (final entry in entries) {
        if (entry is File && p.extension(entry.path) == '.json') yield entry;
      }
    }
  }

  Future<List<FileSystemEntity>> _listFolder(Directory directory) async {
    try {
      return await directory.list(followLinks: false).toList();
    } on FileSystemException catch (error) {
      // A missing old installation is normal. Access-denied/IO errors must reach
      // the caller: treating them as an empty folder could orphan works when a
      // gallery deletion is waiting for output cleanup to complete.
      final code = error.osError?.errorCode;
      if (code == 2 || (Platform.isWindows && code == 3)) return [];
      rethrow;
    }
  }

  /// Retryable background migration. Queue each pair separately so a large
  /// archive cannot hold up a newly generated image or a gallery deletion.
  Future<DesktopOutputMigrationReport> migrateLegacy() {
    if (_migration case final running?) return running;
    final work = _migrateLegacy();
    _migration = work;
    work.then((report) {
      lastMigration = report;
      _migration = null;
    });
    return work;
  }

  Future<DesktopOutputMigrationReport> _migrateLegacy() async {
    var migrated = 0;
    final issues = [...locationIssues];
    for (final oldRoot in legacyRoots) {
      try {
        _checkFolder(oldRoot);
        await for (final source in _sidecars(oldRoot)) {
          try {
            if (await _queue(() => _migratePair(oldRoot, source))) migrated++;
          } catch (error) {
            issues.add('${p.basename(source.path)}：$error');
          }
          // Yield between pairs, including cached/small files.
          await Future<void>.delayed(Duration.zero);
        }
        _removeEmptyFolder(oldRoot);
      } catch (error) {
        issues.add('${oldRoot.path}：$error');
      }
    }
    return DesktopOutputMigrationReport(
      migrated: migrated,
      issues: List.unmodifiable(issues),
    );
  }

  Future<Digest> _digest(File file) => sha256.bind(file.openRead()).first;

  Future<void> _copyInto(File source, File reserved) async {
    final handle = await reserved.open(mode: FileMode.write);
    try {
      await for (final chunk in source.openRead()) {
        await handle.writeFrom(chunk);
      }
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  Future<bool> _matches(File file, int length, Digest digest) async =>
      FileSystemEntity.typeSync(file.path, followLinks: false) ==
          FileSystemEntityType.file &&
      await file.length() == length &&
      await _digest(file) == digest;

  bool _matchesStem(String filename, String stem) =>
      filename == stem ||
      (filename.startsWith('${stem}_') &&
          RegExp(r'^\d+$').hasMatch(filename.substring(stem.length + 1)));

  Future<bool> _migratePair(Directory oldRoot, File sidecar) async {
    _checkFolder(sidecar.parent);
    if (!sidecar.existsSync()) return false; // A queued deletion won first.
    final sourceName = p.basenameWithoutExtension(sidecar.path);
    if (!RegExp(r'^[a-zA-Z0-9_-]+_\d+(?:_\d+)?$').hasMatch(sourceName)) {
      return false;
    }
    if (FileSystemEntity.typeSync(sidecar.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    final metadata = jsonDecode(await sidecar.readAsString());
    if (metadata is! Map ||
        metadata['id'] is! String ||
        metadata['createdAt'] is! int ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(metadata['id'] as String)) {
      return false;
    }
    // Earlier releases did not stamp managedBy. Accept only their complete
    // identifying metadata shape, never an arbitrary JSON next to a PNG.
    if (metadata['managedBy'] != 'plana-gallery' &&
        (metadata['managedBy'] != null ||
            metadata['width'] is! int ||
            metadata['height'] is! int ||
            !metadata.containsKey('prompt') ||
            !metadata.containsKey('negativePrompt'))) {
      return false;
    }
    final stem = '${metadata['id']}_${metadata['createdAt']}';
    if (!_matchesStem(sourceName, stem) || _deleted.contains(stem)) {
      return false;
    }
    final sourcePng = File(p.setExtension(sidecar.path, '.png'));
    final sourceType = FileSystemEntity.typeSync(
      sourcePng.path,
      followLinks: false,
    );
    if (sourceType == FileSystemEntityType.notFound) return false;
    if (sourceType != FileSystemEntityType.file) {
      throw FileSystemException('作品图片不是普通文件，已保留原文件', sourcePng.path);
    }
    final relativeFolder = p.relative(sidecar.parent.path, from: oldRoot.path);
    final folder = Directory(p.join(root.path, relativeFolder));
    if (!p.isWithin(p.absolute(root.path), p.absolute(folder.path))) {
      throw const FormatException('作品文件夹超出目标目录');
    }
    _checkFolder(folder);
    await folder.create(recursive: true);
    _checkFolder(folder);
    final pngLength = await sourcePng.length();
    final jsonLength = await sidecar.length();
    final pngDigest = await _digest(sourcePng);
    final jsonDigest = await _digest(sidecar);

    for (var suffix = 0; suffix < 10000; suffix++) {
      final name = '$stem${suffix == 0 ? '' : '_$suffix'}';
      final png = File(p.join(folder.path, '$name.png'));
      final json = File(p.join(folder.path, '$name.json'));
      final pending = File('${png.path}.part');
      if (_exists(pending)) continue; // A different process is saving it.
      final existsPng = _exists(png);
      final existsJson = _exists(json);
      final alreadyCopied =
          existsPng &&
          existsJson &&
          await _matches(png, pngLength, pngDigest) &&
          await _matches(json, jsonLength, jsonDigest);
      if (!alreadyCopied && (existsPng || existsJson)) continue;

      final created = <File>[];
      var verified = alreadyCopied;
      try {
        if (!alreadyCopied) {
          // Exclusive final-name reservations also coexist with older builds,
          // which check the PNG before taking their separate .part reservation.
          try {
            await png.create(exclusive: true);
          } on FileSystemException {
            if (_exists(png)) continue;
            rethrow;
          }
          created.add(png);
          await json.create(exclusive: true);
          created.add(json);
          _checkFolder(folder);
          await _copyInto(sourcePng, png);
          await _copyInto(sidecar, json);
          verified =
              await _matches(png, pngLength, pngDigest) &&
              await _matches(json, jsonLength, jsonDigest);
          if (!verified) throw const FileSystemException('复制校验失败，原文件已保留');
        }
        // Never remove a source that changed while its copy was in flight.
        if (!await _matches(sourcePng, pngLength, pngDigest) ||
            !await _matches(sidecar, jsonLength, jsonDigest)) {
          throw const FileSystemException('迁移过程中原文件已改变，已保留两边文件');
        }
        _checkFolder(sidecar.parent);
        _checkFolder(folder);
        for (final file in [sourcePng, sidecar]) {
          if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
            throw FileSystemException('原文件已改变，已保留迁移副本', file.path);
          }
        }
        sourcePng.deleteSync();
        sidecar.deleteSync();
        _removeEmptyFolder(sidecar.parent);
        if (p.basename(sidecar.parent.parent.path) == '图库') {
          _removeEmptyFolder(sidecar.parent.parent);
        }
        return true;
      } catch (_) {
        // A fully verified destination may now be the only complete pair if
        // source cleanup was interrupted; retain it for an idempotent retry.
        if (!verified && isPlainOutputDirectory(folder)) {
          for (final file in created) {
            try {
              if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
                  FileSystemEntityType.file) {
                file.deleteSync();
              }
            } on FileSystemException {
              /* Keep failed cleanup for inspection. */
            }
          }
        }
        rethrow;
      }
    }
    throw const FileSystemException('目标存在过多同名作品，原文件已保留');
  }

  void _removeEmptyFolder(Directory directory) {
    if (!isPlainOutputDirectory(directory)) return;
    try {
      directory.deleteSync(); // Never recursive; foreign files keep it alive.
    } on FileSystemException {
      /* Missing, not empty, or not writable. */
    }
  }

  /// Only remove exact app-generated PNG/JSON pairs in managed folders. User
  /// exports, unknown files, and links are never traversed or removed.
  Future<Set<String>> deleteResults(
    List<ResultImage> results, {
    bool Function(String id)? canDelete,
  }) {
    return _queue(() async {
      final byStem = {for (final r in results) _identity(r): r};
      final files = <String, List<File>>{};
      for (final outputRoot in [root, ...legacyRoots]) {
        await for (final entry in _sidecars(outputRoot)) {
          final name = p.basenameWithoutExtension(entry.path);
          // A collision suffix is allowed, but a prefix match is not ownership.
          final suffixAt = name.lastIndexOf('_');
          final result =
              byStem[name] ??
              (suffixAt > 0 &&
                      RegExp(r'^\d+$').hasMatch(name.substring(suffixAt + 1))
                  ? byStem[name.substring(0, suffixAt)]
                  : null);
          if (result == null) continue;
          try {
            final metadata = jsonDecode(await entry.readAsString());
            if (metadata is! Map ||
                metadata['id'] != result.id ||
                metadata['createdAt'] != result.createdAt ||
                (metadata['managedBy'] != null &&
                    metadata['managedBy'] != 'plana-gallery')) {
              continue;
            }
          } catch (_) {
            // Matching names with unreadable metadata cannot be safely owned.
            throw StateError('作品参数文件无法读取，已保留图片：${p.basename(entry.path)}');
          }
          (files[result.id] ??= []).add(entry);
        }
      }
      final deleted = <String>{};
      for (final result in results) {
        if (canDelete?.call(result.id) == false) continue;
        var success = true;
        for (final sidecar in files[result.id] ?? const <File>[]) {
          final png = File(p.setExtension(sidecar.path, '.png'));
          try {
            // Keep the final ownership guard and unlink in one event-loop turn.
            if (canDelete?.call(result.id) == false ||
                !isPlainOutputDirectory(sidecar.parent)) {
              success = false;
              break;
            }
            for (final file in [png, sidecar]) {
              final type = FileSystemEntity.typeSync(
                file.path,
                followLinks: false,
              );
              if (type == FileSystemEntityType.notFound) continue;
              if (type != FileSystemEntityType.file) {
                success = false;
                break;
              }
              file.deleteSync();
            }
            if (!success) break;
            try {
              sidecar.parent.deleteSync();
            } on FileSystemException {
              /* not empty */
            }
          } on FileSystemException {
            success = false;
            break;
          }
        }
        if (success && canDelete?.call(result.id) != false) {
          deleted.add(result.id);
          // A generation save queued after deletion cannot recreate this file.
          _deleted.add(_identity(result));
        }
      }
      return deleted;
    });
  }
}
