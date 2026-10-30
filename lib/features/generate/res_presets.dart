import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import 'res_rules.dart';

/// 用户自存的分辨率预设。尺寸即身份:同尺寸只存一份。
class ResPreset {
  const ResPreset(this.name, this.width, this.height);

  final String name;
  final int width;
  final int height;

  bool sameSize(int w, int h) => width == w && height == h;

  Map<String, dynamic> toJson() => {'name': name, 'w': width, 'h': height};

  static ResPreset? fromJson(Object? j) {
    if (j is! Map) return null;
    final w = j['w'], h = j['h'];
    if (w is! int || h is! int) return null;
    final name = j['name'];
    return ResPreset(
      name is String && name.trim().isNotEmpty ? name : resAutoName(w, h),
      snapDim(w).clamp(kMinDim, kMaxDim),
      snapDim(h).clamp(kMinDim, kMaxDim),
    );
  }
}

/// 按横竖取的默认名。
String resAutoName(int w, int h) => w > h
    ? '横图'
    : w < h
    ? '竖图'
    : '方形';

const _key = 'res_presets';

class ResPresetsNotifier extends Notifier<List<ResPreset>> {
  Object? _loadError;
  @override
  List<ResPreset> build() {
    _loadError = null;
    try {
      final raw = ref.read(prefsStoreProvider).get(_key);
      if (raw == null || raw.isEmpty) return const [];
      final out = <ResPreset>[];
      for (final j in jsonDecode(raw) as List) {
        final p = ResPreset.fromJson(j);
        if (p != null && !out.any((e) => e.sameSize(p.width, p.height))) {
          out.add(p);
        }
      }
      return out;
    } catch (e) {
      _loadError = e;
      return const [];
    }
  }

  ResPreset? find(int w, int h) {
    for (final p in state) {
      if (p.sameSize(w, h)) return p;
    }
    return null;
  }

  /// 追加到末尾;同尺寸已存在则不动。
  Future<void> add(int w, int h) async {
    w = snapDim(w).clamp(kMinDim, kMaxDim);
    h = snapDim(h).clamp(kMinDim, kMaxDim);
    if (find(w, h) != null) return;
    await _set([...state, ResPreset(resAutoName(w, h), w, h)]);
  }

  Future<void> remove(int w, int h) => _set([
    for (final p in state)
      if (!p.sameSize(w, h)) p,
  ]);

  Future<void> _set(List<ResPreset> next) async {
    if (_loadError != null) throw StateError('原尺寸预设无法读取，请先恢复存档');
    state = next;
    final prefs = ref.read(prefsStoreProvider);
    await prefs.write(
      key: _key,
      value: jsonEncode([for (final p in next) p.toJson()]),
    );
    await prefs.idle;
  }
}

final resPresetsProvider =
    NotifierProvider<ResPresetsNotifier, List<ResPreset>>(
      ResPresetsNotifier.new,
    );
