import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/util/prompt_tokens.dart';
import 'package:plana_app/features/editor/data/tag_index.dart';

/// 离线词库索引:进包的文件与 TSV 同步,读取端与建库口径逐键一致。
void main() {
  final spec = TagIndexSpec.fromTsv(File(kTagTsv).readAsStringSync());
  final built = spec.encode();
  final idx = TagIndex(ByteData.sublistView(built));

  test('进包的索引与 TSV 同步', () {
    final shipped = File(kTagIndexAsset).readAsBytesSync();
    var same = shipped.length == built.length;
    for (var i = 0; same && i < built.length; i++) {
      same = shipped[i] == built[i];
    }
    expect(
      same,
      isTrue,
      reason: '改了 TSV 或建库口径要重跑 dart run tool/build_tag_index.dart',
    );
  });

  test('注音 / 帖子数 / 角色三张表逐键一致,查不到的回空', () {
    final bad = <String>[];
    void check(String what, Object? got, Object? want) {
      if (got != want && bad.length < 20) bad.add('$what: $got ≠ $want');
    }

    final keys = {
      ...spec.metaRow.keys,
      ...spec.postRow.keys,
      ...spec.charRow.keys,
    };
    for (final k in keys) {
      final meta = spec.metaRow[k];
      check('trans $k', idx.transOf(k), spec.transOf(k));
      check(
        'count $k',
        idx.countOf(k),
        meta == null ? null : spec.rows[meta].count,
      );
      final post = spec.postRow[k];
      check(
        'post $k',
        idx.postCountOf(k),
        post == null ? 0 : spec.rows[post].count,
      );
      final char = spec.charRow[k];
      final hit = idx.charactersIn({k});
      check(
        'char $k',
        hit.map((e) => e.tag).join(),
        char == null ? '' : spec.rows[char].tag,
      );
      if (char != null && hit.isNotEmpty) {
        check('char zh $k', hit.single.zh, spec.rows[char].zh);
        check('char count $k', hit.single.count, spec.rows[char].count);
      }
      final miss = '$k|无此键|';
      check('miss $k', idx.transOf(miss) ?? idx.countOf(miss), null);
    }
    expect(bad, isEmpty);
  });

  test('帖子数与角色的口径跟着分词走', () {
    final toks = tokenizeSet(
      '1.2::long_hair::, {{hires}}, Ganyu_(Genshin_Impact), 独一无二的描述',
    );
    expect(idx.postCountOf('long hair'), greaterThan(100000));
    expect(
      idx.postCountOf('hires'),
      idx.postCountOf('highres'),
      reason: '别名记正名的帖子数',
    );
    expect(idx.postCountOf('独一无二的描述'), 0);
    expect(idx.postCountOf(''), 0);
    expect(idx.charactersIn(toks).map((e) => e.tag), [
      'ganyu_(genshin_impact)',
    ]);
  });

  test('补全与后端逐条一致(对拍 tool/autocomplete_parity.py 导出的结果)', () {
    final fx =
        jsonDecode(
              File('test/fixtures/autocomplete_parity.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final limit = fx['limit'] as int;
    final bad = <String>[];
    for (final c in fx['cases'] as List) {
      final q = c['q'] as String;
      final want = (c['want'] as List).cast<String>();
      final got = [for (final h in idx.search(q, limit: limit)) h.tag];
      if (got.join('|') != want.join('|') && bad.length < 20) {
        bad.add('$q\n  后端 $want\n  本地 $got');
      }
    }
    expect(bad, isEmpty);
  });

  test('拼写纠错:口径同 Danbooru autocorrect(样本取自 Danbooru 线上结果)', () {
    List<String> fix(String q) => [
      for (final h in idx.correct(q, limit: 12)) h.tag,
    ];
    expect(fix('scholl uniform').first, 'school_uniform');
    expect(fix('blonde har').first, 'blonde_hair');
    expect(fix('pleted skirt').take(2), ['pleated_skirt', 'pleated_shirt']);
    expect(fix('hatsune mku').first, 'hatsune_miku');
    expect(fix('yed_hair').take(3), ['red_hair', 'wet_hair', 'leg_hair']);
    expect(fix('qqxxzzqq'), isEmpty, reason: '没有相近的');
    expect(fix('a_b'), isEmpty, reason: '字母数字不足 3 个');
    expect(fix('/lhh'), isEmpty, reason: '斜杠开头是快捷别名');
    expect(fix('长发头发'), isEmpty, reason: '只纠英文');
  });

  test('补全结果带类目与首段译名', () {
    final miku = idx.search('hatsune miku', limit: 1).single;
    expect(miku.tag, 'hatsune_miku');
    expect(miku.category, 4);
    expect(miku.zh, spec.rows.firstWhere((r) => r.tag == 'hatsune_miku').zh);
    expect(idx.search('vocaloid', limit: 1).single.category, 3);
    expect(
      idx.search('/lh', limit: 1).single.tag,
      'long_hair',
      reason: '快捷别名 /lh',
    );
  });
}
