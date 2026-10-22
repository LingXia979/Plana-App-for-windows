// 编辑器标签收藏:托盘点收藏插进正文的口径,以及收藏表本身的去重 / 撤销 / 落盘。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/editor/data/tag_favorites.dart';
import 'package:plana_app/features/editor/editor_models.dart';

void main() {
  group('insertUnitAt:在光标处插一枚', () {
    test('空正文直接落词', () {
      expect(insertUnitAt('', 0, 'smile'), ('smile', 5));
      expect(insertUnitAt('  ', 2, 'smile'), ('smile', 5));
    });

    test('接在词后补 `, `,右边还有词再补一个', () {
      expect(insertUnitAt('a', 1, 'x'), ('a, x', 4));
      expect(insertUnitAt('a, b', 1, 'x'), ('a, x, b', 4));
    });

    test('逗号后只补空格,不叠出 `,,`', () {
      expect(insertUnitAt('a, ', 3, 'x'), ('a, x', 4));
      expect(insertUnitAt('a, b', 2, 'x'), ('a, x, b', 4));
    });

    test('文首、换行后直接接', () {
      expect(insertUnitAt('a', 0, 'x'), ('x, a', 1));
      expect(insertUnitAt('a,\nb', 3, 'x'), ('a,\nx, b', 4));
    });
  });

  group('收藏表', () {
    late AppStores stores;
    late ProviderContainer c;

    setUp(() {
      stores = AppStores.ephemeral();
      c = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
    });

    tearDown(() async {
      c.dispose();
      stores.flushNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    ProviderContainer reopen() {
      final c2 = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      addTearDown(c2.dispose);
      return c2;
    }

    /// 先清掉默认的那几枚,从空表起步。
    TagFavoritesNotifier emptied() {
      final n = c.read(tagFavoritesProvider.notifier);
      for (final d in TagFavoritesNotifier.defaults) {
        n.remove(d);
      }
      return n;
    }

    test('首次打开带默认收藏', () {
      expect(c.read(tagFavoritesProvider), [
        'fur dataset',
        'transparent background',
      ]);
    });

    test('删掉的默认收藏重开不再补回来', () {
      c.read(tagFavoritesProvider.notifier).remove('fur dataset');
      expect(reopen().read(tagFavoritesProvider), ['transparent background']);
    });

    test('已存过的收藏表补一次默认,写法不同的不重复补', () async {
      await stores.prefs.write(
        key: 'editor_tag_favorites',
        value: '["Transparent_Background", "smile"]',
      );
      expect(reopen().read(tagFavoritesProvider), [
        'Transparent_Background',
        'smile',
        'fur dataset',
      ]);
    });

    test('新收的在前;下划线 / 大小写不同的同一标签算一枚', () {
      final n = emptied();
      n.toggle('long hair');
      n.toggle('blue_eyes');
      expect(c.read(tagFavoritesProvider), ['blue_eyes', 'long hair']);
      expect(c.read(tagFavoriteKeysProvider), {'blue eyes', 'long hair'});
      n.toggle('Blue Eyes'); // 同一枚:取消收藏
      expect(c.read(tagFavoritesProvider), ['long hair']);
    });

    test('移出后撤销放回原位', () {
      final n = emptied();
      for (final t in ['c', 'b', 'a']) {
        n.toggle(t);
      }
      final at = n.remove('b');
      expect(c.read(tagFavoritesProvider), ['a', 'c']);
      n.restore('b', at);
      expect(c.read(tagFavoritesProvider), ['a', 'b', 'c']);
      expect(n.remove('missing'), -1);
    });

    test('写进设置,重开还在', () {
      emptied().toggle('smile');
      expect(reopen().read(tagFavoritesProvider), ['smile']);
    });
  });
}
