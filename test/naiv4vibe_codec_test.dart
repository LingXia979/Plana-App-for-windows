import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/vibe_library/naiv4vibe_codec.dart';

void main() {
  group('jsNum(JS Number 字符串语义)', () {
    test('整数值去 .0', () {
      expect(jsNum(1.0), '1');
      expect(jsNum(0.0), '0');
    });
    test('小数原样', () {
      expect(jsNum(0.8), '0.8');
      expect(jsNum(0.61), '0.61');
      expect(jsNum(0.05), '0.05');
      expect(jsNum(.712345678901234), '0.712345678901234');
      expect(jsNum(.000001), '0.000001');
      expect(jsNum(.0000001), '1e-7');
    });
  });

  group('官方哈希口径(参考值由独立实现算出)', () {
    test('hashKey = SHA256("information_extracted:" + jsNum)', () {
      expect(
        vibeEncodingHashKey(1.0),
        'b36a8472fe418d9f80d6bb1c54e3a6e62c62936aa7bf31dae2bcf7e929f6430f',
      );
      expect(
        vibeEncodingHashKey(0.8),
        'e993570541f3ba1a57f9bd05314523150445b96abc9d34e7c8571b65ef14b5ee',
      );
      expect(
        vibeEncodingHashKey(0.61),
        '50b617ccbd9470405811bb8e8e4ae468ed026e5cb88352cbaee0e8587b55f967',
      );
    });
    test('vibe id = SHA256(base64 文本)', () {
      expect(
        naiVibeIdOfBase64('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });

  group('.naiv4vibe 解析', () {
    test('单文件 + encodings 拍扁', () {
      final text = jsonEncode({
        'identifier': 'novelai-vibe-transfer',
        'version': 1,
        'type': 'image',
        'image': 'AAAA',
        'id': 'someid',
        'name': 'test',
        'createdAt': 123,
        'importInfo': {
          'model': 'nai-diffusion-4-5-full',
          'information_extracted': 0.8,
          'strength': 0.5,
        },
        'tags': ['a', 'b'],
        'encodings': {
          'v4-5full': {
            vibeEncodingHashKey(0.8): {
              'encoding': 'ENC1',
              'params': {'information_extracted': 0.8},
            },
            'nohash': {'encoding': 'ENC2'}, // 无 params 的条目
          },
        },
      });
      final list = parseVibeFileText(text);
      expect(list, hasLength(1));
      final p = list.first;
      expect(p.imageBase64, 'AAAA');
      expect(p.name, 'test');
      expect(p.defaultStrength, 0.5);
      expect(p.defaultInfoExtracted, 0.8);
      expect(p.tags, ['a', 'b']);
      expect(p.supportedModelKeys, ['v4-5full']);
      final items = p.encodingItems;
      expect(items, hasLength(2));
      expect(items.first.encoding, 'ENC1');
      expect(items.first.infoExtracted, 0.8);
      expect(items.last.infoExtracted, isNull);
    });

    test('bundle 拆条 + 无效条目跳过', () {
      final text = jsonEncode({
        'identifier': 'novelai-vibe-transfer-bundle',
        'version': 1,
        'vibes': [
          {'identifier': 'novelai-vibe-transfer', 'name': 'a'},
          {'identifier': 'wrong'},
          {'identifier': 'novelai-vibe-transfer', 'name': 'b'},
        ],
      });
      final list = parseVibeFileText(text);
      expect(list.map((p) => p.name), ['a', 'b']);
    });

    test('格式不对抛 FormatException', () {
      expect(() => parseVibeFileText('not json'), throwsFormatException);
      expect(
        () => parseVibeFileText('{"identifier":"x"}'),
        throwsFormatException,
      );
    });
  });

  test('mergeEncodingIntoRaw 往返(导出合并后可再解析命中)', () {
    final raw = newImageVibeRaw(
      imageBase64: 'AAAA',
      name: 'n',
      thumbnailDataUrl: 'data:image/png;base64,xx',
      createdAtMs: 1,
    );
    mergeEncodingIntoRaw(
      raw,
      modelKey: 'v4-5full',
      infoExtracted: 1.0,
      encoding: 'E1',
    );
    mergeEncodingIntoRaw(
      raw,
      modelKey: 'v4-5full',
      infoExtracted: 0.8,
      encoding: 'E2',
    );
    mergeEncodingIntoRaw(
      raw,
      modelKey: 'v4full',
      infoExtracted: 1.0,
      encoding: 'E3',
    );
    final p = parseVibeFileText(jsonEncode(raw)).single;
    expect(p.id, naiVibeIdOfBase64('AAAA'));
    expect(p.supportedModelKeys.toSet(), {'v4-5full', 'v4full'});
    expect(p.encodingItems, hasLength(3));
    // hashKey 可与 web 互认
    final encs = (raw['encodings'] as Map)['v4-5full'] as Map;
    expect(encs.containsKey(vibeEncodingHashKey(1.0)), isTrue);
    expect(encs.containsKey(vibeEncodingHashKey(0.8)), isTrue);
  });
}
