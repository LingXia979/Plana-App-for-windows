import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/nai_credential_login.dart';

void main() {
  group('deriveNaiAccessKey', () {
    // 参考向量由 Python argon2-cffi + hashlib.blake2b 按 NAI 官方算法生成
    // (scratchpad/nai_vectors.py 一次性脚本)。任何一组对不上都说明
    // 盐构造 / Argon2id 参数 / 截断规则被改坏 —— 用户会登录失败且报错
    // 看起来像"密码错了",极难排查,所以钉死在这。
    const vectors = {
      ('test@example.com', 'password123'):
          '5TjO-5RT1mNI59hEHZXjBJZpp2yvC4L0LJUeIhRwkZHxgIHEutHp8EgOwvynvwLu',
      ('plana@bluearchive.example', 'sh1roko&Hoshino!'):
          'vTV7krPuzXivvbcoWUL0Erg8V_g7CGdwNFk7vDMj3iMDF30EaTsaceq9GuYcXnxq',
      // 密码不足 6 字符:pre_salt 的前缀取整个密码,不能越界
      ('a@b.c', '12345'):
          'mDxuuOtzDs3N5zGt_Jzs27weSY2b6k2oWDZ6zGFX2ef7qfmX2JEoUHZyq9Aito8s',
    };

    for (final entry in vectors.entries) {
      final (email, password) = entry.key;
      test('$email 派生结果与 Python 参考一致', () async {
        expect(await deriveNaiAccessKey(email, password), entry.value);
      });
    }

    test('结果恒为 64 字符 base64url', () async {
      final key = await deriveNaiAccessKey('x@y.z', 'p@ss word 长');
      expect(key.length, 64);
      expect(RegExp(r'^[A-Za-z0-9_-]{64}$').hasMatch(key), isTrue);
    });
  });

  group('naiEmailForms', () {
    // 顺序与官网登录页一致:小写 → 原始输入 → 首字母大写,去重保序。
    // NAI 注册邮箱从未规范化,漏形态的症状是「官网能登、App 报密码错误」。
    test('全小写输入 → 小写 + 首字母大写', () {
      expect(naiEmailForms('user@ex.com'), ['user@ex.com', 'User@ex.com']);
    });
    test('混合大小写输入 → 三种形态', () {
      expect(naiEmailForms('User@Ex.com'), [
        'user@ex.com',
        'User@Ex.com',
        'User@ex.com',
      ]);
    });
    test('首字母大写输入(与形态③重合)→ 两种', () {
      expect(naiEmailForms('User@ex.com'), ['user@ex.com', 'User@ex.com']);
    });
    test('前后空白剔除', () {
      expect(naiEmailForms('  a@b.c '), ['a@b.c', 'A@b.c']);
    });
  });

  group('naiJwtExpiry', () {
    test('解出三段式 JWT 的 exp', () {
      // header {"alg":"HS256","typ":"JWT"} + payload {"exp":1787675712,...},
      // 签名段内容不参与解析,给占位即可。
      const jwt =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
          'eyJleHAiOjE3ODc2NzU3MTIsImlhdCI6MTc4NTA4MzcxMn0.'
          'sig';
      expect(
        naiJwtExpiry(jwt),
        DateTime.fromMillisecondsSinceEpoch(1787675712 * 1000, isUtc: true),
      );
    });

    test('pst 令牌与坏输入返回 null', () {
      expect(naiJwtExpiry('pst-test-token'), isNull);
      expect(naiJwtExpiry('not a jwt'), isNull);
      expect(naiJwtExpiry('a.%%%.c'), isNull);
      expect(naiJwtExpiry(''), isNull);
    });
  });
}
