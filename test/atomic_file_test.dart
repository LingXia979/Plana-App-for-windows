import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/atomic_file.dart';
import 'package:plana_app/core/store/app_stores.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_write_test_');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<File> crossDevice(File source, String path) async =>
      throw FileSystemException(
        'Cannot rename',
        source.path,
        OSError('cross device', Platform.isWindows ? 17 : 18),
      );

  test('同目录 Windows 跨设备错误完成保存和覆盖，校验后清理恢复文件', () async {
    final target = File('${root.path}/测试 image.png');
    final pending = File('${target.path}.tmp');
    await pending.writeAsBytes([1, 2, 3, 4]);
    await commitPendingFile(pending, target, rename: crossDevice);
    expect(await target.readAsBytes(), [1, 2, 3, 4]);
    await pending.writeAsBytes([5, 6, 7]);
    await commitPendingFile(pending, target, rename: crossDevice);
    expect(await target.readAsBytes(), [5, 6, 7]);
    expect(await root.list().length, 1);
  });

  test('非跨设备错误保留原文件和待写完整内容并向上报告', () async {
    final target = File('${root.path}/image.png');
    await target.writeAsBytes([1, 2]);
    final pending = File('${target.path}.tmp');
    await pending.writeAsBytes([3, 4]);
    await expectLater(
      commitPendingFile(
        pending,
        target,
        rename: (_, _) async {
          throw const FileSystemException(
            'access denied',
            '',
            OSError('access', 5),
          );
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await target.readAsBytes(), [1, 2]);
    expect(await pending.readAsBytes(), [3, 4]);
  });

  test('中途退出留下半截目标，启动按已校验日志补全写入', () async {
    final target = File('${root.path}/state.json');
    final bytes = utf8.encode('{"version":2}');
    await target.writeAsString('{');
    await File('${target.path}.tmp').writeAsBytes(bytes);
    await File('${target.path}.bak').writeAsString('{"version":1}');
    await File('${target.path}.pending').writeAsString(
      jsonEncode({
        'length': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      }),
    );
    expect(await recoverPendingWrites(root), 1);
    expect(jsonDecode(await target.readAsString()), {'version': 2});
    expect(await root.list().length, 1);
  });

  test('恢复内容校验失败时使用旧备份，不采纳损坏的新内容', () async {
    final target = File('${root.path}/state.json');
    await target.writeAsString('{');
    await File('${target.path}.tmp').writeAsString('corrupt');
    await File('${target.path}.bak').writeAsString('{"version":1}');
    await File(
      '${target.path}.pending',
    ).writeAsString('{"length":999,"sha256":"invalid"}');
    expect(await recoverPendingWrites(root), 0);
    expect(jsonDecode(await target.readAsString()), {'version': 1});
    expect(await File('${target.path}.tmp').exists(), isFalse);
    expect(await File('${target.path}.pending').exists(), isFalse);
    expect(await root.list().length, 4); // 正式文件与隔离后的三个诊断文件。
  });

  for (final missingContents in [false, true]) {
    test('回退旧日志后成功保存的新值不会在重启时回滚，缺少临时内容=$missingContents', () async {
      final target = File('${root.path}/state.json');
      await target.writeAsString('{');
      if (!missingContents) {
        await File('${target.path}.tmp').writeAsString('corrupt');
      }
      await File('${target.path}.bak').writeAsString('{"version":1}');
      await File(
        '${target.path}.pending',
      ).writeAsString('{"length":999,"sha256":"invalid"}');
      await recoverPendingWrites(root);
      expect(jsonDecode(await target.readAsString()), {'version': 1});
      await writeStringAtomic(target, '{"version":2}');
      await recoverPendingWrites(root);
      expect(jsonDecode(await target.readAsString()), {'version': 2});
    });
  }

  test('索引已有旧记录时补回遗漏的完整图片，后续编号不覆盖它', () async {
    final png = await File('assets/app_icon.png').readAsBytes();
    final images = Directory('${root.path}/gallery/images');
    await images.create(recursive: true);
    await File('${images.path}/gen0.png').writeAsBytes(png);
    await File('${images.path}/gen9.png.tmp').writeAsBytes(png);
    await File('${root.path}/gallery/index.json').writeAsString(
      jsonEncode({
        'v': 1,
        'seq': 1,
        'selectedId': 'gen0',
        'items': [
          {'id': 'gen0', 'w': 256, 'h': 256, 'seed': 42, 't': 1},
        ],
      }),
    );
    final stores = await AppStores.open(rootOverride: root);
    expect(stores.gallery.initialResults.map((r) => r.id).toSet(), {
      'gen0',
      'gen9',
    });
    expect(stores.gallery.seq, 10);
    expect(stores.gallery.initialSelectedId, 'gen0');
    await stores.gallery.flushIndex();
    await stores.gallery.idle;
  });

  test('恢复旧版完整 PNG 与索引，保留正式文件及损坏临时文件', () async {
    final png = await File('assets/app_icon.png').readAsBytes();
    final images = Directory('${root.path}/gallery/images');
    await images.create(recursive: true);
    await File('${images.path}/gen7.png.tmp').writeAsBytes(png);
    await File(
      '${images.path}/gen8.png.tmp',
    ).writeAsBytes(png.take(32).toList());
    await File('${root.path}/gallery/index.json.tmp').writeAsString(
      jsonEncode({
        'v': 1,
        'seq': 8,
        'selectedId': 'gen7',
        'items': [
          {
            'id': 'gen7',
            'w': 256,
            'h': 256,
            'seed': 42,
            't': 1,
            'hasInput': false,
          },
        ],
      }),
    );
    await File('${root.path}/existing.json').writeAsString('{"old":true}');
    await File('${root.path}/existing.json.tmp').writeAsString('{"new":true}');
    await File('${root.path}/broken.json.tmp').writeAsString('{');
    final stores = await AppStores.open(rootOverride: root);
    expect(stores.gallery.initialResults.single.id, 'gen7');
    expect(stores.gallery.initialResults.single.seed, 42);
    expect(stores.gallery.seq, 8);
    expect(await stores.gallery.readImage('gen7'), png);
    expect(await File('${images.path}/gen8.png').exists(), isFalse);
    expect(await File('${images.path}/gen8.png.tmp').exists(), isTrue);
    expect(
      await File('${root.path}/existing.json').readAsString(),
      '{"old":true}',
    );
    expect(await File('${root.path}/broken.json').exists(), isFalse);
    expect(await recoverPendingWrites(root), 0);
  });
}
