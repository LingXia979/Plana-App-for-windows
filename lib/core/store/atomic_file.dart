import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

typedef FileRename = Future<File> Function(File source, String destination);

/// 正常目录同目录 rename；不支持 rename 的 Windows 目录改用带校验的
/// 写入日志。替换完成前保留完整新内容和旧文件备份，启动时恢复中断写入。
Future<void> writeStringAtomic(File target, String contents) =>
    writeBytesAtomic(target, utf8.encode(contents));

Future<void> writeBytesAtomic(File target, List<int> bytes) async {
  await target.parent.create(recursive: true);
  await _recoverJournal(target);
  final tmp = File('${target.path}.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await commitPendingFile(tmp, target);
}

/// [rename] 用于故障注入测试。仅对明确的跨设备错误降级；权限、磁盘满等
/// 错误仍报告给调用方，不将未完成的写入当成成功。
Future<void> commitPendingFile(
  File pending,
  File target, {
  FileRename? rename,
}) async {
  try {
    await (rename ?? (source, path) => source.rename(path))(
      pending,
      target.path,
    );
  } on FileSystemException catch (error) {
    if (error.osError?.errorCode != (Platform.isWindows ? 17 : 18)) rethrow;
    final bytes = await pending.readAsBytes();
    // 日志不含源路径，恢复时只能操作日志旁边的目标文件。
    final journal = File('${target.path}.pending');
    final tmp = File('${target.path}.tmp');
    if (pending.absolute.path != tmp.absolute.path) {
      await tmp.writeAsBytes(bytes, flush: true);
    }
    final backup = File('${target.path}.bak');
    if (await target.exists()) {
      await backup.writeAsBytes(await target.readAsBytes(), flush: true);
    }
    await journal.writeAsString(
      jsonEncode({
        'length': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      }),
      flush: true,
    );
    await _copyVerified(target, bytes);
    await _removeIfPresent(journal);
    if (await journal.exists()) return; // 保留日志依赖的完整内容供下次清理
    await _removeIfPresent(tmp);
    await _removeIfPresent(backup);
    if (pending.absolute.path != tmp.absolute.path) {
      await _removeIfPresent(pending);
    }
  }
}

Future<void> _copyVerified(File target, List<int> bytes) async {
  await target.writeAsBytes(bytes, flush: true);
  if (sha256.convert(await target.readAsBytes()).toString() !=
      sha256.convert(bytes).toString()) {
    throw FileSystemException('写入校验失败，恢复文件已保留', target.path);
  }
}

Future<void> _removeIfPresent(File file) async {
  // 已确认目标完整，清理失败不应将成功保存误报为生成失败。
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    /* 下次启动继续清理 */
  }
}

Future<bool> _recoverJournal(File target) async {
  final journal = File('${target.path}.pending');
  if (!await journal.exists()) return false;
  final tmp = File('${target.path}.tmp');
  final backup = File('${target.path}.bak');
  try {
    final record = jsonDecode(await journal.readAsString());
    if (!await tmp.exists()) {
      throw const FormatException('Missing pending write contents');
    }
    final bytes = await tmp.readAsBytes();
    if (record is! Map ||
        record['length'] != bytes.length ||
        record['sha256'] != sha256.convert(bytes).toString()) {
      throw const FormatException('Incomplete write journal');
    }
    await _copyVerified(target, bytes);
  } on FormatException {
    // 恢复旧版本后隔离整组工件，避免旧日志覆盖之后成功保存的新版本。
    if (await backup.exists()) {
      await _copyVerified(target, await backup.readAsBytes());
    }
    await _quarantineJournal([tmp, backup, journal]);
    return false;
  } on FileSystemException {
    if (await backup.exists()) {
      await _copyVerified(target, await backup.readAsBytes());
    }
    rethrow;
  }
  // 后续写入前必须撤销日志；失败时阻止新提交复用它的 .tmp。
  await journal.delete();
  await _removeIfPresent(tmp);
  await _removeIfPresent(backup);
  return true;
}

Future<void> _quarantineJournal(List<File> files) async {
  final suffix = '.invalid-${DateTime.now().microsecondsSinceEpoch}';
  for (final file in files) {
    if (await file.exists()) await file.rename('${file.path}$suffix');
  }
}

/// 在索引载入之前恢复。旧版没有日志，仅接纳目标缺失且验证完整的 JSON /
/// PNG / 内容寻址 blob；已有正式文件优先，半截临时文件原样保留。
Future<int> recoverPendingWrites(Directory root) async {
  if (!await root.exists()) return 0;
  var recovered = 0;
  final files = await root
      .list(recursive: true, followLinks: false)
      .where((entry) => entry is File)
      .cast<File>()
      .toList();
  for (final file in files.where((f) => f.path.endsWith('.pending'))) {
    try {
      if (await _recoverJournal(
        File(file.path.substring(0, file.path.length - 8)),
      )) {
        recovered++;
      }
    } on FileSystemException {
      /* 保留日志，允许其它作品继续恢复 */
    }
  }
  for (final file in files.where((f) => f.path.endsWith('.tmp'))) {
    final target = File(file.path.substring(0, file.path.length - 4));
    if (await target.exists() ||
        await File('${target.path}.pending').exists() ||
        !await file.exists()) {
      continue;
    }
    try {
      final bytes = await file.readAsBytes();
      var valid = false;
      if (target.path.endsWith('.json')) {
        final value = jsonDecode(utf8.decode(bytes));
        valid = value is Map || value is List;
      } else if (target.path.endsWith('.png')) {
        // 解码器可能容忍缺少结尾块，还须检查完整 IEND。
        const end = [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
        valid =
            bytes.length > 24 &&
            List.generate(
              12,
              (i) => bytes[bytes.length - 12 + i],
            ).asMap().entries.every((e) => e.value == end[e.key]) &&
            img.decodePng(bytes) != null;
      } else if (target.path.endsWith('.bin')) {
        valid = target.uri.pathSegments.last == '${sha256.convert(bytes)}.bin';
      }
      if (!valid) continue;
      final modified = (await file.stat()).modified;
      await commitPendingFile(file, target);
      await target.setLastModified(modified);
      recovered++;
    } on Object {
      /* 损坏临时文件不导入，不删除 */
    }
  }
  return recovered;
}
