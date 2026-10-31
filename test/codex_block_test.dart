import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/inspiration/codex/codex_block.dart';

void main() {
  const b = CodexBlock(
    paths: [
      ['r18g/重口'],
      ['杂项涩涩', '兽交'],
    ],
  );

  test('屏蔽父级含全部子级,同级其余不受影响', () {
    expect(b.hides(['r18g/重口']), isTrue);
    expect(b.hides(['r18g/重口', '杀害']), isTrue);
    expect(b.hides(['杂项涩涩', '兽交', 'x']), isTrue);
    expect(b.hides(['杂项涩涩']), isFalse);
    expect(b.hides(['杂项涩涩', '异种']), isFalse);
    expect(b.hides(const []), isFalse);
  });

  test('读存档:坏项跳过', () {
    final r = CodexBlock.fromJson({
      'paths': [
        ['a', 'b'],
        [],
        ['c', 1],
        'd',
      ],
    });
    expect(r.paths, [
      ['a', 'b'],
    ]);
    expect(CodexBlock.fromJson(null).paths, isEmpty);
  });
}
