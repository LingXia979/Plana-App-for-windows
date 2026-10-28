// 芯片模式(编辑器第二种正文形态)独有的两条文本改写口径。
//
// 芯片流没有光标:加词只能往末尾追,改字只能整名替换。这两件事在文本模式里
// 由 TextField 天然承担,搬到芯片模式后成了显式的文本操作 —— 而**用户的排版**
// (换行分段、已有的逗号)必须在这两条路上原样活下来,否则「加了一个词,整段
// 排版被拍平成一行」这种事一次就能劝退。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/widgets/chip_flow_view.dart';

/// 按名字取第 n 枚词条(改名用例要拿到精确的 Tok)。
Tok _tok(String text, String name) =>
    parseToks(text).firstWhere((t) => t.name == name);

void main() {
  // 空框退格删最后一枚(见 editor_page 的 _chipBackspace)。芯片流没有光标,
  // 标签也不是输入框里的字符,退格落不到它们身上 —— 这条口径就是那一下的定义。
  group('退格删末枚', () {
    int lastIdx(String t) => topLevelUnits(t, const {}).length - 1;
    String back(String t) => deleteUnits(t, const {}, {lastIdx(t)}).$1;

    test('逐枚删,前面的原样留着', () {
      expect(back('a, b, c'), 'a, b');
      expect(back(back('a, b, c')), 'a');
      expect(back(back(back('a, b, c'))), '');
    });

    test('权重记号跟着自己那枚一起走,不留半截', () {
      expect(parseToks(back('a, {b}, 1.3::c::')).map((t) => t.name), [
        'a',
        'b',
      ]);
      expect(back('a, {b}, 1.3::c::').contains('::'), isFalse);
    });

    // 换行是用户分的段。删掉段里最后一枚,那个换行要留着 —— 否则下一枚
    // 输入又被拼回上一段,用户排的版被一次退格抹平(与 appendUnit 同一口径)。
    test('用户的换行分段活下来', () {
      expect(back('a, b\nc'), 'a, b\n');
    });
  });

  // ⊕ 画在哪儿、以及面板上那颗「移动」能不能点,读的都是这一份判据。
  // 两处各写各的迟早出现「按钮亮着但一个 ⊕ 都没有」。
  group('chipValidGaps:哪些落点是有意义的', () {
    test('单枚:自己两侧那两个间隙是空操作,其余都算', () {
      // 5 枚里选中第 2 枚(下标 1):间隙 1、2 搬过去还是原位
      expect(chipValidGaps({1}, 5), {0, 3, 4, 5});
    });

    test('连续多枚当整块看,块两端同样是空操作', () {
      expect(chipValidGaps({1, 2}, 5), {0, 4, 5});
    });

    // 跳选的那批搬到哪儿都会并拢成一块,所以每个间隙都会改变顺序 ——
    // 一个都不该被判成空操作(这条正是"只按左右相邻是否选中"判不出来的)。
    test('跳选:每个间隙都有意义(搬过去会并拢)', () {
      expect(chipValidGaps({0, 2}, 4), {0, 1, 2, 3, 4});
    });

    test('全选中 / 空选 / 空正文都没得搬', () {
      expect(chipValidGaps({0, 1}, 2), isEmpty);
      expect(chipValidGaps(const {}, 5), isEmpty);
      expect(chipValidGaps({0}, 0), isEmpty);
    });

    test('只有一枚时搬到哪儿都是原位', () {
      expect(chipValidGaps({0}, 1), isEmpty);
    });
  });

  group('appendUnit:尾部输入框的落地口径', () {
    test('空正文直接落词,不带前导逗号', () {
      expect(appendUnit('', '1girl'), '1girl');
      expect(appendUnit('   ', '1girl'), '1girl');
      expect(appendUnit('\n\n', '1girl'), '1girl');
    });

    test('常规追加补 `, `', () {
      expect(appendUnit('1girl', 'smile'), '1girl, smile');
      expect(appendUnit('a, b', 'c'), 'a, b, c');
    });

    test('正文已以逗号收尾:只补空格,不叠出 `,,`', () {
      expect(appendUnit('1girl,', 'smile'), '1girl, smile');
      expect(appendUnit('1girl, ', 'smile'), '1girl, smile');
      expect(appendUnit('1girl，', 'smile'), '1girl， smile'); // 全角原样保留
    });

    // 换行是用户分的段(画师串一行、场景一行)。trim 掉再拼 `, ` 会把两段
    // 并成一行,用户排了半天的版被一次输入抹平。
    test('正文以换行收尾:新词落在新行开头,不把段落拼回一行', () {
      expect(appendUnit('a, b\n', 'c'), 'a, b\nc');
      expect(appendUnit('a, b\n  ', 'c'), 'a, b\nc'); // 行内空白吃掉,换行留着
      expect(appendUnit('a,\n\n', 'c'), 'a,\n\nc'); // 空行(段间距)也留着
    });

    test('空词不改正文;词自身两端空白剪掉', () {
      expect(appendUnit('a', ''), 'a');
      expect(appendUnit('a', '   '), 'a');
      expect(appendUnit('a', '  smile  '), 'a, smile');
    });

    test('追加进来的词是正经的顶层单元(解析得出、算得进定稿)', () {
      final t = appendUnit('1girl, {smile}', '1.2::sky::');
      expect([for (final k in parseToks(t)) k.name], ['1girl', 'smile', 'sky']);
      expect(outputOf(t), '1girl, {smile}, 1.2::sky::');
    });
  });

  group('renameTok:词条栏的行内改名', () {
    test('只换名字,权重/禁用记号原样留着', () {
      const t = '1.2::blue eyes::, smile';
      expect(
        renameTok(t, _tok(t, 'blue eyes'), 'red eyes'),
        '1.2::red eyes::, smile',
      );
      const b = '{smile}, a';
      expect(renameTok(b, _tok(b, 'smile'), 'grin'), '{grin}, a');
      const d = '~off~, a';
      expect(renameTok(d, _tok(d, 'off'), 'on'), '~on~, a');
    });

    test('空名当没改 —— 删词有专门的入口,别从改名掉进去', () {
      const t = 'a, b';
      expect(renameTok(t, _tok(t, 'a'), ''), t);
      expect(renameTok(t, _tok(t, 'a'), '   '), t);
    });

    test('新名两端空白剪掉', () {
      const t = 'a, b';
      expect(renameTok(t, _tok(t, 'a'), '  1girl  '), '1girl, b');
    });

    test('组内改名不动组记号', () {
      const t = '1.5::a, b::, c';
      final out = renameTok(t, _tok(t, 'b'), 'x');
      expect(out, '1.5::a, x::, c');
      // 组还在:x 仍吃 1.5 倍
      expect(parseToks(out).firstWhere((k) => k.name == 'x').effMult, 1.5);
    });
  });

  // 形态是「用惯了哪种」的问题,得跨会话记住;老存档没有这个键时回落文本形态,
  // 不能让升级后的用户莫名其妙换了个编辑器。
  group('EditorSettings.chipMode 持久化', () {
    test('默认文本形态', () {
      expect(const EditorSettings().chipMode, isFalse);
    });

    test('往返不丢', () {
      final on = const EditorSettings().copyWith(chipMode: true);
      expect(EditorSettings.fromJson(on.toJson()).chipMode, isTrue);
      expect(EditorSettings.fromJson(on.toJson()), on);
    });

    test('老存档缺键 → 文本形态', () {
      expect(
        EditorSettings.fromJson(const {'showTranslation': false}).chipMode,
        isFalse,
      );
    });
  });

  // 字号与权重步进从「三五个档位」改成了大范围连续调。读回时**夹住**而不是
  // 回退默认:上下界改动过、或者存进来一个越界值时,把用户调过的偏好整个丢回
  // 默认比夹一下更讨厌。
  group('字号 / 权重步进:范围而非档位', () {
    double fs(Object? v) => EditorSettings.fromJson({'fontSize': v}).fontSize;
    double ws(Object? v) =>
        EditorSettings.fromJson({'weightStep': v}).weightStep;

    test('区间内的任意值原样留着(老档位表外的数不再被打回默认)', () {
      expect(fs(15), 15);
      expect(fs(23), 23);
      expect(ws(0.03), 0.03);
      expect(ws(0.25), 0.25);
    });

    test('越界夹回上下界', () {
      expect(fs(4), EditorSettings.fontSizeMin);
      expect(fs(99), EditorSettings.fontSizeMax);
      expect(ws(0), EditorSettings.weightStepMin);
      expect(ws(9), EditorSettings.weightStepMax);
    });

    test('缺键回默认', () {
      expect(const EditorSettings().fontSize, 16);
      expect(const EditorSettings().weightStep, 0.1);
      expect(EditorSettings.fromJson(const {}).fontSize, 16);
      expect(EditorSettings.fromJson(const {}).weightStep, 0.1);
    });

    test('往返不丢', () {
      final v = const EditorSettings().copyWith(fontSize: 21, weightStep: 0.07);
      expect(EditorSettings.fromJson(v.toJson()), v);
    });
  });

  // 芯片模式过去把 `1.3::a, b::` 摊成「每颗各挂一个 ×1.3」——同一件事说 N 遍,
  // 还看不出这几枚是一起被加权的。改成圈一块、读数只报一次,判据全在 unitGroups。
  group('unitGroups:一个权重罩住几枚才算组', () {
    List<UnitGroup> g(String t) => unitGroups(t, topLevelUnits(t, const {}));

    test('罩住两枚以上 = 组,给出首末下标与该层倍率', () {
      final r = g('1.3::empty eyes, panting::, hello');
      expect(r.length, 1);
      expect(r.single.first, 0);
      expect(r.single.last, 1);
      expect(r.single.mult, closeTo(1.3, 1e-9));
      // 原文区间含记号 —— 整组搬动搬的就是这一段
      expect(
        '1.3::empty eyes, panting::, hello'.substring(
          r.single.start,
          r.single.end,
        ),
        '1.3::empty eyes, panting::',
      );
    });

    test('只罩住一枚 = 它自己的权重,不成组(芯片照常内联报数)', () {
      expect(g('1.2::solo::, a'), isEmpty);
      expect(g('{solo}, a'), isEmpty);
    });

    test('括号组同样算:{a, b} 也是一块', () {
      final r = g('{a, b}, c');
      expect(r.length, 1);
      expect((r.single.first, r.single.last), (0, 1));
    });

    test('挨着的两个同倍率组各算各的,不并成一块', () {
      final r = g('1.3::a, b::, 1.3::c, d::');
      expect(r.length, 2);
      expect((r[0].first, r[0].last), (0, 1));
      expect((r[1].first, r[1].last), (2, 3));
    });

    // 嵌套只取最外层。内层那点倍率由成员芯片自己内联报出:effMult 除掉
    // 框已经报掉的部分,合起来仍是它真正的有效权重。
    test('嵌套只出最外那层,内层留给成员自己报', () {
      const t = '1.2::a, {b, c}, d::';
      final r = g(t);
      expect(r.length, 1);
      expect((r.single.first, r.single.last), (0, 3));
      expect(r.single.mult, closeTo(1.2, 1e-9));

      final toks = parseToks(t);
      final band = r.single.mult;
      // a / d 被框全额报掉,自己没得报;b / c 还剩那层 {}
      expect(toks[0].effMult / band, closeTo(1.0, 1e-9));
      expect(toks[3].effMult / band, closeTo(1.0, 1e-9));
      expect(toks[1].effMult / band, closeTo(1.05, 1e-9));
    });

    test('没有权重记号就没有组', () {
      expect(g('a, b, c'), isEmpty);
      expect(g('a'), isEmpty);
      expect(g(''), isEmpty);
    });
  });

  // 组记号(`1.3::` 与收尾的 `::`)落在词条 seg 之外,搬动时跟着组员走。
  group('搬动时权重组记号跟着组员走', () {
    String mv(String t, Set<int> sel, int to) =>
        moveUnits(t, const {}, sel, to);

    test('选中整组搬到末尾:记号跟着走,不留下来吞别的词', () {
      expect(mv('1.3::a, b::, c, d', {0, 1}, 4), 'c, d, 1.3::a, b::');
    });

    test('选中整组搬到中间:落点前后都不被卷进组里', () {
      expect(mv('1.3::a, b::, c, d', {0, 1}, 3), 'c, 1.3::a, b::, d');
    });

    test('括号组同样整只走', () {
      expect(mv('{a, b}, c, d', {0, 1}, 4), 'c, d, {a, b}');
    });

    test('组不在开头也搬得动', () {
      expect(mv('x, 1.3::a, b::, y', {1, 2}, 0), '1.3::a, b::, x, y');
    });

    test('只挑组里一枚搬出去:这枚不带权重,组收边,不吞后一枚', () {
      expect(
        mv('1.3::empty eyes, panting::, hello', {0}, 3),
        '1.3::panting::, hello, empty eyes',
      );
    });

    test('组外一枚搬进两枚组员之间:入组,原组员一个不少', () {
      expect(mv('a, 1.3::b, c::, d', {0}, 2), '1.3::b, a, c::, d');
      expect(mv('a, 1.3::b, c::, d', {3}, 2), 'a, 1.3::b, d, c::');
      expect(mv('{a, b}, c, d', {3}, 1), '{a, d, b}, c');
    });

    test('组外一枚搬到组的首尾边上:落在组外', () {
      expect(mv('1.3::b, c::, d', {2}, 0), 'd, 1.3::b, c::');
      expect(mv('a, 1.3::b, c::, d', {3}, 1), 'a, d, 1.3::b, c::');
    });

    test('组员搬进另一个组:离开原组,进新组', () {
      expect(
        mv('1.3::a, b::, 0.8::c, d::', {0}, 3),
        '1.3::b::, 0.8::c, a, d::',
      );
    });

    test('没收口的组:搬到它后面的词补上收口,不被吞进去', () {
      expect(mv('x, 1.2::a, b', {0}, 3), '1.2::a, b::, x');
    });

    test('组内换位不受影响', () {
      expect(
        mv('1.3::empty eyes, panting::, hello', {1}, 0),
        '1.3::panting, empty eyes::, hello',
      );
    });

    // 单枚自带的权重本来就在自己 seg 里,一直是跟着走的,别改坏了
    test('单枚自带权重照旧跟着走', () {
      expect(mv('1.2::solo::, a, b', {0}, 3), 'a, b, 1.2::solo::');
    });

    test('整组搬动是可逆的:搬走再搬回来还是原样', () {
      const t = '1.3::a, b::, c, d';
      final moved = mv(t, {0, 1}, 4);
      expect(mv(moved, {2, 3}, 0), t);
    });
  });

  // 正文与芯片的字号后来拆成了两项。老存档里只有那个合并值:芯片得跟着它,
  // 不然升一次级,调过字号的人打开芯片模式会发现整片 chip 变了大小。
  group('正文 / 芯片字号各调各的', () {
    test('老存档只有 fontSize:芯片跟着它,不回默认', () {
      final old = EditorSettings.fromJson(const {'fontSize': 22.0});
      expect(old.fontSize, 22);
      expect(old.chipFontSize, 22);
    });

    test('两项都在时各读各的', () {
      final v = EditorSettings.fromJson(const {
        'fontSize': 14.0,
        'chipFontSize': 20.0,
      });
      expect(v.fontSize, 14);
      expect(v.chipFontSize, 20);
    });

    test('改一项不动另一项', () {
      final v = const EditorSettings().copyWith(chipFontSize: 24);
      expect(v.chipFontSize, 24);
      expect(v.fontSize, 16);
    });
  });
}
