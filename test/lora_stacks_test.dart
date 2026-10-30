import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/lora/lora_stacks.dart';

ActiveLora _lr(
  String name, {
  double weight = 0.8,
  bool enabled = true,
  double? clipWeight,
  LoraPending? pending,
}) => ActiveLora(
  name: name,
  displayName: '$name 名',
  weight: weight,
  enabled: enabled,
  clipWeight: clipWeight,
  pending: pending,
);

LoraStack _stack(List<LoraStackEntry> loras) => LoraStack(
  id: 'ls_1',
  name: '堆',
  base: 'anima',
  loras: loras,
  createdAt: 1,
  updatedAt: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('已挂列表转堆条目:占位条不进堆,参数原样带上', () {
    final entries = stackEntriesFromActive([
      _lr('LR1', weight: 1.2, clipWeight: 0.5),
      _lr('pending:9', pending: const LoraPending(versionId: 9)),
      _lr('LR2', enabled: false),
    ]);
    expect([for (final e in entries) e.name], ['LR1', 'LR2']);
    expect(entries.first.weight, 1.2);
    expect(entries.first.clipWeight, 0.5);
    expect(entries.last.enabled, isFalse);
  });

  test('默认名用展示名连起来,超长截断', () {
    expect(defaultLoraStackName([_lr('A'), _lr('B')]), 'A 名 + B 名');
    final long = defaultLoraStackName([
      for (var i = 0; i < 10; i++) _lr('LR$i'),
    ]);
    expect(long.length, kLoraStackNameMax);
    expect(long.endsWith('…'), isTrue);
  });

  test('存档读写:clipFollow 与各条 clip_weight 对得上网页端格式', () {
    final s = _stack([
      const LoraStackEntry(name: 'LR1', displayName: 'a', weight: 1),
      const LoraStackEntry(
        name: 'LR2',
        displayName: 'b',
        weight: 0.6,
        clipWeight: 0.3,
        enabled: false,
      ),
    ]);
    final json = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
    expect(json['clipFollow'], isFalse);
    final back = LoraStack.fromJson(json)!;
    expect(back.loras.first.clipWeight, isNull);
    expect(back.loras.last.clipWeight, 0.3);
    expect(back.loras.last.enabled, isFalse);

    // 网页端整堆跟随权重时,条目里残留的 clip_weight 不生效
    json['clipFollow'] = true;
    expect(LoraStack.fromJson(json)!.loras.last.clipWeight, isNull);

    expect(LoraStack.fromJson({'id': 'x', 'name': ' '}), isNull);
  });

  test('按库还原:缺失与未就绪的跳过,触发词等取库里最新的', () {
    final r = resolveLoraStack(
      _stack([
        const LoraStackEntry(
          name: 'LR1',
          displayName: '旧名',
          weight: 1.1,
          clipWeight: 0.4,
          enabled: false,
        ),
        const LoraStackEntry(name: 'LR2', displayName: '没了', weight: 1),
        const LoraStackEntry(name: 'LR3', displayName: '推送中', weight: 1),
      ]),
      const [
        LoraCardInfo(
          name: 'LR1',
          displayName: '新名',
          triggerWords: ['tw'],
          hasTe: true,
        ),
        LoraCardInfo(name: 'LR3', displayName: '推送中', syncStatus: 'uploading'),
      ],
    );
    expect(r.missing, ['没了']);
    expect(r.notReady, ['推送中']);
    expect(r.loras, hasLength(1));
    final l = r.loras.single;
    expect(l.displayName, '新名');
    expect(l.triggerWords, ['tw']);
    expect(l.weight, 1.1);
    expect(l.clipWeight, 0.4);
    expect(l.enabled, isFalse);
  });

  test('应用:整组替换,下载中的占位条留在前面', () {
    final stores = AppStores.ephemeral();
    final c = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(() async {
      c.dispose();
      stores.flushNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    final n = c.read(generateProvider.notifier);
    n.applyLoraSelection([
      _lr('LR1'),
      _lr('pending:7', pending: const LoraPending(versionId: 7)),
    ]);
    n.applyLoraStack([_lr('LR5', weight: 1.3), _lr('LR6')]);
    final loras = c.read(generateProvider).loras;
    expect([for (final l in loras) l.name], ['pending:7', 'LR5', 'LR6']);
    expect(loras[1].weight, 1.3);
    expect(c.read(generateProvider).openPanels, contains(Panel.lora));
  });
}
