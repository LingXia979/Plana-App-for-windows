import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'atomic_file.dart';

/// Packaged apps save beside the executable. A recognized Flutter source build
/// saves at the project root, outside build/ so rebuilding cannot erase works.
/// Neither case depends on the process working directory.
Directory desktopWorksDirectory({String? executablePath}) => Directory(
  p.join(
    _applicationRoot(executablePath ?? Platform.resolvedExecutable),
    'output',
  ),
);

String _applicationRoot(String executablePath) {
  final executableDirectory = p.dirname(p.absolute(executablePath));
  final runner = p.dirname(executableDirectory);
  final architecture = p.dirname(runner);
  final windows = p.dirname(architecture);
  final build = p.dirname(windows);
  final project = p.dirname(build);
  // Only this exact build layout and this application's source markers qualify.
  // A portable app in an arbitrary nested folder must not write to its parents.
  if ({
        'release',
        'debug',
        'profile',
      }.contains(p.basename(executableDirectory).toLowerCase()) &&
      p.basename(runner).toLowerCase() == 'runner' &&
      {'x64', 'arm64'}.contains(p.basename(architecture).toLowerCase()) &&
      p.basename(windows).toLowerCase() == 'windows' &&
      p.basename(build).toLowerCase() == 'build' &&
      _isPlanaProject(project)) {
    return project;
  }
  return executableDirectory;
}

bool _isPlanaProject(String directory) {
  try {
    final pubspec = File(p.join(directory, 'pubspec.yaml'));
    return FileSystemEntity.typeSync(pubspec.path, followLinks: false) ==
            FileSystemEntityType.file &&
        pubspec.lengthSync() <= 65536 &&
        RegExp(
          r'^name:\s*plana_app\s*(?:#.*)?$',
          multiLine: true,
        ).hasMatch(pubspec.readAsStringSync()) &&
        File(p.join(directory, 'lib', 'main.dart')).existsSync() &&
        Directory(p.join(directory, 'windows', 'runner')).existsSync();
  } on FileSystemException {
    return false;
  } on FormatException {
    return false;
  }
}

/// windows.33 used a works folder beside even a deeply nested build executable.
Directory legacyExecutableWorksDirectory({String? executablePath}) => Directory(
  p.join(
    p.dirname(p.absolute(executablePath ?? Platform.resolvedExecutable)),
    '作品',
  ),
);

Directory legacyDesktopWorksDirectory(Directory documents) =>
    Directory(p.join(documents.path, 'Plana app for windows', '作品'));

bool _isWorksLeaf(String path) =>
    {'作品', 'output'}.contains(p.basename(p.normalize(path)).toLowerCase());

/// An owned leaf is not enough if an ancestor redirects into another folder.
/// Missing components are allowed so the first successful save can create them.
bool isPlainOutputDirectory(Directory directory) {
  var path = p.normalize(p.absolute(directory.path));
  while (true) {
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        return false;
      }
    } on FileSystemException {
      return false;
    }
    final parent = p.dirname(path);
    if (parent == path) return true;
    path = parent;
  }
}

String outputPathKey(String path) {
  final normalized = p.normalize(p.absolute(path));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

File _locationRegistry(Directory support) =>
    File(p.join(support.path, 'desktop_output_roots.json'));

/// Internal bookkeeping for future upgrades installed in a different folder.
/// This contains only previously used works leaves, never account settings.
Future<List<Directory>> readDesktopWorksRoots(
  Directory support, {
  List<String>? issues,
}) async {
  final file = _locationRegistry(support);
  try {
    if (!isPlainOutputDirectory(support)) return [];
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return [];
    if (type != FileSystemEntityType.file || await file.length() > 65536) {
      throw const FormatException('作品目录登记文件不合法');
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map ||
        value['managedBy'] != 'plana-output-locations' ||
        value['version'] != 1 ||
        value['roots'] is! List) {
      throw const FormatException('作品目录登记文件不合法');
    }
    final byPath = <String, Directory>{};
    for (final path in value['roots'] as List) {
      if (path is! String || !p.isAbsolute(path)) continue;
      final normalized = p.normalize(path);
      if (!_isWorksLeaf(normalized)) continue;
      final directory = Directory(normalized);
      if (!isPlainOutputDirectory(directory)) continue;
      byPath[outputPathKey(normalized)] = directory;
    }
    return byPath.values.toList();
  } catch (error) {
    issues?.add('无法读取之前的作品目录登记：$error');
    return [];
  }
}

/// Register before background migration: closing halfway through an upgrade
/// must not forget the prior location. Old roots remain retryable when offline.
Future<({List<Directory> previous, List<String> issues})>
registerDesktopWorksRoot(Directory support, Directory current) async {
  final issues = <String>[];
  final previous = await readDesktopWorksRoots(support, issues: issues);
  // Preserve an unreadable registry for recovery instead of replacing evidence
  // of an earlier location with only the current executable's folder.
  if (issues.isNotEmpty) return (previous: previous, issues: issues);
  try {
    if (!isPlainOutputDirectory(support)) {
      throw const FileSystemException('应用设置目录包含链接或不可访问');
    }
    if (!p.isAbsolute(current.path) ||
        !_isWorksLeaf(current.path) ||
        !isPlainOutputDirectory(current)) {
      throw const FileSystemException('作品目录不合法或包含链接');
    }
    final file = _locationRegistry(support);
    for (final path in [
      file.path,
      '${file.path}.tmp',
      '${file.path}.pending',
      '${file.path}.bak',
    ]) {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.notFound) {
        throw const FileSystemException('作品目录登记不是普通文件');
      }
    }
    final roots = <String, String>{
      for (final directory in [...previous, current])
        outputPathKey(directory.path): p.normalize(p.absolute(directory.path)),
    };
    await writeStringAtomic(
      file,
      jsonEncode({
        'managedBy': 'plana-output-locations',
        'version': 1,
        'roots': roots.values.toList(),
      }),
    );
  } catch (error) {
    issues.add('无法记住当前作品位置；更换安装目录前请先保留作品文件夹：$error');
  }
  return (previous: previous, issues: issues);
}
