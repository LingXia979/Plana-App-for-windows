import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/theme/theme_settings.dart';

void main() {
  test('外观设置 json 回环', () {
    const s = ThemeSettings(
      mode: ThemeMode.dark,
      seedKey: 'teal',
      textScale: 1.2,
    );
    expect(ThemeSettings.fromJson(s.toJson()), s);
  });

  test('脏数据回退默认(未知模式/未知色/类型错)', () {
    expect(
      ThemeSettings.fromJson({'mode': 'neon', 'seed': 'plaid'}),
      const ThemeSettings(),
    );
    expect(
      ThemeSettings.fromJson({'mode': 3, 'seed': 7}),
      const ThemeSettings(),
    );
    expect(ThemeSettings.fromJson({}), const ThemeSettings());
  });

  test('seed 找不到档位时回退默认档(不是列表第一个)', () {
    // 第一个是「金」,回退到那儿等于用户随便点一下就换了个不相干的色。
    expect(const ThemeSettings(seedKey: 'nope').seed.key, kDefaultSeedKey);
  });

  test('下架的档位(旧版深蓝)按脏数据回退', () {
    expect(themeSeeds.any((s) => s.key == 'blue'), isFalse);
    expect(
      ThemeSettings.fromJson({'mode': 'dark', 'seed': 'blue'}).seedKey,
      kDefaultSeedKey,
    );
  });

  test('振动开关:默认开,缺键的老存档也按开', () {
    expect(const ThemeSettings().haptics, isTrue);
    expect(ThemeSettings.fromJson({'mode': 'dark'}).haptics, isTrue);
    const off = ThemeSettings(haptics: false);
    expect(ThemeSettings.fromJson(off.toJson()).haptics, isFalse);
  });

  test('旧外观设置保留默认字号，其他修改不会重置字号', () {
    expect(ThemeSettings.fromJson({'mode': 'dark'}).textScale, 1);
    const settings = ThemeSettings(textScale: 1.2);
    expect(settings.copyWith(seedKey: 'teal').textScale, 1.2);
    expect(settings, isNot(const ThemeSettings()));
  });

  test('字号数据的类型、非有限值与上下限受到保护', () {
    for (final invalid in [null, 'large', true, double.nan, double.infinity]) {
      expect(ThemeSettings.fromJson({'textScale': invalid}).textScale, 1);
    }
    expect(ThemeSettings.fromJson({'textScale': -1}).textScale, .8);
    expect(ThemeSettings.fromJson({'textScale': 9}).textScale, 1.4);
    expect(const ThemeSettings().copyWith(textScale: double.nan).textScale, 1);
  });

  test('工具箱默认在导航栏，关闭和其他修改的偏好可恢复', () {
    expect(const ThemeSettings().showTools, isTrue);
    expect(ThemeSettings.fromJson({'mode': 'dark'}).showTools, isTrue);
    const settings = ThemeSettings(showTools: false, textScale: 1.2);
    final changed = settings.copyWith(seedKey: 'teal');
    expect(changed.showTools, isFalse);
    expect(ThemeSettings.fromJson(changed.toJson()), changed);
    expect(settings, isNot(settings.copyWith(showTools: true)));
  });
}
