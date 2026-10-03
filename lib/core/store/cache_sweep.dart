import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/log.dart';

/// 分享用的临时图落这里(gallery_grid_sheet)。每次分享前自己会清一次,
/// 这里再兜一道:分享到一半退出的残留、以及存储管理里手动清理。
const kShareCacheDir = 'plana_share';

/// Windows 的 temporary directory 是所有软件共享的系统 Temp，只有明确
/// 由 Plana 写入的子目录才属于应用缓存。移动端仍使用插件给出的应用缓存根。
/// 不遍历系统 Temp，也不接纳链接或被重定向到别处的同名目录。
Future<List<FileSystemEntity>> temporaryStorageRoots(
  Directory temporaryDirectory, {
  bool? windows,
}) async {
  if (!(windows ?? Platform.isWindows)) return [temporaryDirectory];
  try {
    if (await FileSystemEntity.type(
          temporaryDirectory.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.directory) {
      return [];
    }
    final root = Directory(p.join(temporaryDirectory.path, kShareCacheDir));
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return [];
    }
    final expected = p.join(
      await temporaryDirectory.resolveSymbolicLinks(),
      kShareCacheDir,
    );
    if (!p.equals(await root.resolveSymbolicLinks(), expected)) return [];
    return [root];
  } on FileSystemException {
    return [];
  }
}

// file_picker 建的 UUID 目录 / image_picker 落的 UUID 文件
final _uuidLike = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(\..*)?$',
);

String _baseName(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return path.substring(i + 1);
}

/// 清应用临时缓存。Windows 只处理 [temporaryStorageRoots] 中的 Plana
/// 专属目录；不能凭 UUID、扩展名或 image_picker 前缀删除共享 Temp 文件。
/// 移动端继续清 file_picker / image_picker 留在应用缓存中的导入副本。
/// [minAge] 内的新鲜条目豁免(启动自动清扫默认 1 小时,防碰到本次会话
/// 正在用的临时文件;存储管理手动清理传 Duration.zero 全清)。
/// [temporaryDirectory] 和 [windows] 可覆盖环境，供隔离的文件系统测试使用。
Future<void> sweepPickerCache({
  Duration minAge = const Duration(hours: 1),
  Directory? temporaryDirectory,
  bool? windows,
}) async {
  try {
    final dir = temporaryDirectory ?? await getTemporaryDirectory();
    final cutoff = DateTime.now().subtract(minAge);
    if (windows ?? Platform.isWindows) {
      var deleted = 0;
      for (final root in await temporaryStorageRoots(dir, windows: true)) {
        final canonicalRoot = await root.resolveSymbolicLinks();
        deleted += await _sweepOwnedEntry(
          root,
          root.path,
          canonicalRoot,
          cutoff,
        );
      }
      logd('[cache-sweep] 清掉 $deleted 项 Plana 临时缓存');
      return;
    }
    var deleted = 0, kept = 0;
    await for (final ent in dir.list(followLinks: false)) {
      if (ent is Link) continue;
      final name = _baseName(ent.path);
      final junk =
          _uuidLike.hasMatch(name) ||
          name.endsWith('.onnx') ||
          name.startsWith('image_picker') ||
          name.startsWith('scaled_') ||
          name == kShareCacheDir;
      if (!junk) {
        kept++;
        continue;
      }
      try {
        if ((await ent.stat()).modified.isAfter(cutoff)) {
          kept++;
          continue; // 新鲜豁免
        }
        await ent.delete(recursive: true);
        deleted++;
      } catch (e) {
        logd('[cache-sweep] 删不掉 $name: $e');
      }
    }
    logd('[cache-sweep] 清掉 $deleted 项,保留 $kept 项');
  } catch (e) {
    logd('[cache-sweep] 失败: $e');
  }
}

/// 手动逐层清理，避免递归删除跨过目录联接或符号链接。每一层均校验
/// 实际路径；目录内仍在使用的新文件也受 minAge 保护。
Future<int> _sweepOwnedEntry(
  FileSystemEntity entry,
  String rootPath,
  String canonicalRoot,
  DateTime cutoff,
) async {
  try {
    final type = await FileSystemEntity.type(entry.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      return 0;
    }
    final relative = p.relative(entry.path, from: rootPath);
    final expected = p.normalize(p.join(canonicalRoot, relative));
    if (!p.equals(expected, canonicalRoot) &&
        !p.isWithin(canonicalRoot, expected)) {
      return 0;
    }
    if (!p.equals(await entry.resolveSymbolicLinks(), expected)) return 0;
    final modified = (await entry.stat()).modified;
    if (type == FileSystemEntityType.file) {
      if (modified.isAfter(cutoff)) return 0;
      await entry.delete();
      return 1;
    }
    var deleted = 0;
    await for (final child in Directory(entry.path).list(followLinks: false)) {
      deleted += await _sweepOwnedEntry(child, rootPath, canonicalRoot, cutoff);
    }
    if (!modified.isAfter(cutoff) &&
        p.equals(await entry.resolveSymbolicLinks(), expected)) {
      // Non-recursive deletion succeeds only when no fresh or linked children
      // remain. In particular, never follow or remove a retained junction.
      try {
        await Directory(entry.path).delete();
        deleted++;
      } on FileSystemException {
        // A fresh/linked child, another writer, or a file lock kept it alive.
      }
    }
    return deleted;
  } on FileSystemException {
    return 0;
  }
}
