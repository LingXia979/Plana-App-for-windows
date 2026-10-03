// 折叠体就是一段提示词,里面本来就可能带尖括号 —— 画师串常见
// `<artist>…</artist>` 这种包裹。老实现拿裸 `>` 当尾巴、「段尾是 `>` 就收」,
// 于是折叠在 `<artist>` 那个 `>` 上提前收尾:正文里只留下一枚吞了 `<artist>`
// 的空壳,整串画师裸在外面,末尾还剩一个多余的 `>`(真机截图)。
//
// 现在写入用**专用记号** [kFoldClose](`#>`),内容里撞不上;老草稿的裸 `>`
// 仍读得回(数尖括号兜底),读回来再存一次就换成新写法。两种写法这一组都钉。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/editor/editor_models.dart';

void main() {
  group('专用收尾记号:内容里的尖括号撞不上', () {
    test('写入一律用 #> 收尾', () {
      expect(foldWrap('串', 'a, b'), '<#串: a, b#>');
      expect(
        foldWrap('串', '<artist>x, y</artist>'),
        '<#串: <artist>x, y</artist>#>',
      );
    });

    test('新写法解析回来一字不差', () {
      const d = '<#串: <artist>\nx, y\n</artist>#>, solo';
      final (text, bodies) = collapseFolds(d);
      expect(text, '${foldRefLiteral('串')}, solo');
      expect(bodies['串'], '<artist>\nx, y\n</artist>');
      expect(expandFolds(text, bodies), d);
    });

    // 这三样在裸 `>` 下都是雷:孤零零的 `<`、SD 的 `<lora:…>`、颜文字。
    // 新记号根本不看尖括号,一律无感。
    test('孤零零的 < / <lora:x:1> / 颜文字都不影响尾部判定', () {
      for (final body in [
        'a < b, c',
        '<lora:foo:1>, 1girl',
        '>_<, <3, smile',
        '<artist>a, b</artist>',
      ]) {
        final d = '<#串: $body#>';
        expect(parseFolds(d).length, 1, reason: body);
        expect(parseFolds(d).single.end, d.length, reason: body);
        expect(collapseFolds(d).$2['串'], body, reason: body);
      }
    });

    test('内容本身以 # 结尾也切得干净', () {
      const d = '<#串: a, tag##>';
      final (text, bodies) = collapseFolds(d);
      expect(bodies['串'], 'a, tag#');
      expect(expandFolds(text, bodies), d);
    });

    test('折叠止于自己的记号,不吞后文', () {
      const d = '<#串: <artist>\na, b\n</artist>#>, solo, 1girl';
      final (text, bodies) = collapseFolds(d);
      expect(text, '${foldRefLiteral('串')}, solo, 1girl');
      expect(bodies['串'], '<artist>\na, b\n</artist>');
      expect(expandFolds(text, bodies), d);
    });
  });

  group('老草稿(裸 > 收尾)仍读得回', () {
    // 截图那一串的结构:名字 + `<artist>` 换行 + 一堆带权重的画师 + `</artist>` + 折叠尾
    const artistDraft =
        '<#测试画风: <artist>\n'
        '0.5::artist:fixture_a::,\n'
        '0.7::artist:fixture_b::,\n'
        'artist:fixture_c, 0.5::artist:fixture_d::,\n'
        '1.5::artist:fixture_e::, 0.8::artist:fixture_f::,\n'
        '0.8::artist:fixture_g, artist:fixture_h::\n'
        '</artist>>';

    test('截图那一串:整串都在折叠里,不再提前收尾', () {
      final folds = parseFolds(artistDraft);
      expect(folds.length, 1);
      expect(folds.single.start, 0);
      expect(folds.single.end, artistDraft.length); // 老实现停在 18
      expect(folds.single.name, '测试画风');

      final (text, bodies) = collapseFolds(artistDraft);
      // 正文只剩一枚占位符,画师串一个字都没漏在外面
      expect(text, foldRefLiteral('测试画风'));
      expect(bodies['测试画风']!.startsWith('<artist>'), isTrue);
      expect(bodies['测试画风']!.endsWith('</artist>'), isTrue);
    });

    test('读回后重存 = 自动换成新记号,内容一字不差', () {
      final (text, bodies) = collapseFolds(artistDraft);
      expect(
        expandFolds(text, bodies),
        '${artistDraft.substring(0, artistDraft.length - 1)}$kFoldClose',
      );
    });

    test('逗号分隔的老写法同样收对', () {
      const d = '<#串: <artist>, a, b, </artist>>';
      expect(parseFolds(d).single.end, d.length);
    });

    test('老写法:包裹后面还有别的词条,不吞后文', () {
      const d = '<#串: <artist>\na, b\n</artist>>, solo, 1girl';
      final (text, bodies) = collapseFolds(d);
      expect(text, '${foldRefLiteral('串')}, solo, 1girl');
      expect(bodies['串'], '<artist>\na, b\n</artist>');
    });

    test('老写法:多层包裹也数得清', () {
      const d = '<#串: <a><b>x, y</b></a>>';
      expect(parseFolds(d).single.end, d.length);
    });

    test('老写法:>_< / <3 颜文字不算一层,不会吃掉真尾巴', () {
      const d = '<#串: >_<, <3, smile>';
      final (text, bodies) = collapseFolds(d);
      expect(text, foldRefLiteral('串'));
      expect(bodies['串'], '>_<, <3, smile');
    });

    test('老写法:没有包裹的普通折叠照旧', () {
      const d = '<#串: a, b>, c';
      final (text, bodies) = collapseFolds(d);
      expect(text, '${foldRefLiteral('串')}, c');
      expect(bodies['串'], 'a, b');
    });
  });
}
