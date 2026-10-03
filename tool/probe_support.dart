import 'dart:io';
import 'package:plana_app/core/store/atomic_file.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/probe_support.dart <application data directory>',
    );
    exitCode = 64;
    return;
  }
  final root = Directory(
    '${args.single}/write_fix_probe_${DateTime.now().microsecondsSinceEpoch}',
  );
  await root.create();
  final target = File('${root.path}/验证 文件.json');
  await writeStringAtomic(target, '{"version":1}');
  await writeStringAtomic(target, '{"version":2}');
  if (await target.readAsString() != '{"version":2}') {
    throw StateError('Mismatch');
  }
  stdout.writeln(
    'Real application directory: initial save + replacement + verification PASS',
  );
  await target.delete();
  await root.delete();
}
