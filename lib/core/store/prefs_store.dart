import '../util/log.dart';
import 'dart:convert';
import 'dart:io';

import '../auth/secure_storage.dart';
import 'atomic_file.dart';

/// 非机密设置的普通持久化(`<support>/settings.json`),启动时一次读进内存。
///
/// **为什么要从 secure storage 搬出来**:`flutter_secure_storage` 的
/// `AndroidOptions.resetOnError` 默认 `true`,官方注释原文是出错时
/// "PERMANENTLY erase the data"。而此前本项目把 9 类设置也塞在那里,于是一次
/// Keystore 故障(换机恢复最常见,见 S1A-03)会把主题、生成参数、编辑器设置、
/// 保存设置…… 连同令牌一起清空;各读取点又都是 `catch (_) { return 默认值 }`,
/// 用户只看到「App 莫名其妙恢复出厂设置」,毫无提示。
///
/// 搬出来之后,Keystore 出问题的最坏后果从「全部设置 + 凭据一起消失」
/// 缩小到「需要重新登录」。见 S1A-02 / S1C-11。
///
/// 接口刻意与 `FlutterSecureStorage` 对齐(`read` / `write` / `delete` 同名同参),
/// 各设置模块只需换一个 provider,其余代码一行不动。
class PrefsStore {
  PrefsStore._(this._file, this._map);

  final File _file;
  final Map<String, String> _map;

  Future<void> _chain = Future.value();

  /// Wait for settings already queued before closing the application.
  Future<void> get idle => _chain;

  /// 需要从 secure storage 迁出的键。
  ///
  /// **新增非机密设置项时必须登记在这里** —— 漏登记的后果是老用户升级后
  /// 那一项静默回落默认值(旧值还躺在 secure storage 里,再没人读)。
  ///
  /// 反过来,`nai_access_token` / `bot_session` / `auth_mode` 三个是真凭据,
  /// **留在 secure storage,不要加进来**。
  static const migrateKeys = <String>[
    'theme_settings',
    'editor_settings',
    'completion_source',
    'upscale_method',
    'gen_modules',
    'backend_base_url',
    'save_settings',
    'storage_settings',
    'gen_settings',
  ];

  /// [legacyRead] / [legacyDelete] 仅供测试注入(`FlutterSecureStorage` 是具体类,
  /// 测试环境没有平台实现,只能把这两个动作抽成函数才能验迁移);
  /// 生产走全局那份 [kSecureStorage]。
  static Future<PrefsStore> open(
    Directory supportRoot, {
    Future<String?> Function(String key)? legacyRead,
    Future<void> Function(String key)? legacyDelete,
  }) async {
    final file = File('${supportRoot.path}/settings.json');
    final map = <String, String>{};
    try {
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString());
        if (j is Map) {
          for (final e in j.entries) {
            final k = e.key, v = e.value;
            if (k is String && v is String) map[k] = v;
          }
        }
      }
    } catch (e) {
      logd('[prefs] 载入失败(按默认设置起步): $e');
    }
    final store = PrefsStore._(file, map);
    await store._migrateFromSecure(
      legacyRead ?? ((k) => kSecureStorage.read(key: k)),
      legacyDelete ?? ((k) => kSecureStorage.delete(key: k)),
    );
    return store;
  }

  /// 一次性迁移:本地没有、secure storage 里有 → 搬过来,并从 secure storage 删掉。
  ///
  /// 逐键各自 try:某一项读不出来(那正是 Keystore 故障的表现)不能连累其余项 ——
  /// 这个迁移本身就是为了应对 Keystore 不可靠,不能假设它一定能读。
  Future<void> _migrateFromSecure(
    Future<String?> Function(String key) legacyRead,
    Future<void> Function(String key) legacyDelete,
  ) async {
    var moved = 0;
    for (final k in migrateKeys) {
      if (_map.containsKey(k)) continue; // 已迁过
      try {
        final v = await legacyRead(k);
        if (v == null || v.isEmpty) continue;
        _map[k] = v;
        moved++;
        await legacyDelete(k);
      } catch (_) {
        // 这一项读不出来就算了,下次启动再试;不影响其余项
      }
    }
    if (moved > 0) {
      logd('[prefs] 已从 secure storage 迁出 $moved 项设置');
      await _flush();
    }
  }

  /// 测试用空档:不读盘、不迁移,写入落到临时目录。
  factory PrefsStore.emptyForTest(Directory root) =>
      PrefsStore._(File('${root.path}/settings.json'), <String, String>{});

  /// 同步取值(内存态)——给 `main()` 里 ProviderScope 建立前的预读用。
  String? get(String key) => _map[key];

  Future<String?> read({required String key}) async => _map[key];

  Future<void> write({required String key, required String? value}) async {
    if (value == null) return delete(key: key);
    _map[key] = value;
    await _flush();
  }

  Future<void> delete({required String key}) async {
    _map.remove(key);
    await _flush();
  }

  /// 串行落盘,不与上一次写重叠;走原子写 —— 半截 JSON 会让**全部**设置
  /// 一起回落默认值,正是这次要根除的那类故障。
  Future<void> _flush() {
    return _chain = _chain.then((_) async {
      try {
        await writeStringAtomic(_file, jsonEncode(_map));
      } catch (e) {
        logd('[prefs] 保存失败: $e');
      }
    });
  }
}
