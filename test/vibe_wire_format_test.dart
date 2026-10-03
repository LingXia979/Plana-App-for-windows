import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/features/generate/bot_request.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/vibe_cache.dart';
import 'package:plana_app/features/vibe_library/naiv4vibe_codec.dart';

void main() {
  test(
    'direct and Bot encoding requests serialize numeric 1 and 0.7 without padding',
    () async {
      final sent = <String>[];
      final client = MockClient((request) async {
        sent.add(request.body);
        if (request.url.path.endsWith('encode-vibe')) {
          return http.Response.bytes([1, 2, 3], 200);
        }
        return http.Response(
          '{"encoding":"AQID"}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      await http.runWithClient(() async {
        for (final ie in [1.0, .70, .654321123456789]) {
          await NaiClient(base: 'https://example.invalid').encodeVibe(
            token: 'test',
            imageBase64: 'AAAA',
            infoExtracted: ie,
            model: 'nai-diffusion-4-5-full',
          );
          await BackendClient('https://example.invalid').encodeVibe(
            sessionId: 'test',
            imageBase64: 'AAAA',
            informationExtracted: ie,
            model: 'nai-diffusion-4-5-full',
          );
        }
      }, () => client);
      expect(sent, hasLength(6));
      for (var i = 0; i < sent.length; i++) {
        expect(
          sent[i],
          contains(
            '"information_extracted":${['1', '0.7', '0.654321123456789'][i ~/ 2]},',
          ),
        );
        expect(
          (jsonDecode(sent[i]) as Map)['information_extracted'],
          isA<num>(),
        );
      }
      final params = buildBotParams(
        GenerateState.initial(),
        seed: 1,
        presetId: 'heavy',
        vibes: [(encodedVibe: 'AQID', strength: .7, infoExtracted: 1)],
      );
      expect(
        jsonEncode(params['vibeReferences']),
        '[{"encodedVibe":"AQID","strength":0.7,"informationExtracted":1}]',
      );
    },
  );

  test(
    'single and bundle exports repair legacy decimal hashes without touching encodings',
    () {
      final wrong = sha256
          .convert(utf8.encode('information_extracted:1.00'))
          .toString();
      const right =
          'b36a8472fe418d9f80d6bb1c54e3a6e62c62936aa7bf31dae2bcf7e929f6430f';
      final raw = <String, dynamic>{
        'identifier': 'novelai-vibe-transfer',
        'id': 'legacy-id',
        'image': 'AAAA',
        'custom': {'keep': true},
        'importInfo': {'information_extracted': 1.0, 'strength': .70},
        'encodings': {
          'v4-5full': {
            wrong: {
              'encoding': 'opaque-legacy-full',
              'params': {'information_extracted': 1.00},
              'extra': 42,
            },
            vibeEncodingHashKey(.7): {
              'encoding': 'opaque-full07',
              'params': {'information_extracted': .70},
            },
          },
          'v4-5curated': {
            wrong: {
              'encoding': 'opaque-curated',
              'params': {'information_extracted': 1.0},
            },
          },
        },
      };
      final single = buildVibeText(raw);
      expect(single, contains('"information_extracted":1}'));
      expect(single, isNot(contains('"information_extracted":1.0')));
      expect(single, contains('"strength":0.7'));
      for (final output in [
        single,
        buildBundleText([raw]),
      ]) {
        final parsed = parseVibeFileText(output).single;
        expect(parsed.id, 'legacy-id');
        expect(parsed.raw['custom'], {'keep': true});
        final full = (parsed.raw['encodings'] as Map)['v4-5full'] as Map;
        expect(full.keys, containsAll([right, vibeEncodingHashKey(.7)]));
        expect(full, isNot(contains(wrong)));
        expect(full[right]['encoding'], 'opaque-legacy-full');
        expect(full[right]['extra'], 42);
        final curated = (parsed.raw['encodings'] as Map)['v4-5curated'] as Map;
        expect(curated[right]['encoding'], 'opaque-curated');
      }
      // The source object/file is preserved; normalization only affects the export.
      expect((raw['encodings'] as Map)['v4-5full'], contains(wrong));
      expect(raw['id'], 'legacy-id');
    },
  );

  test(
    'old 1.00 and 0.70 cache filenames reuse the existing paid encodings',
    () async {
      final root = await Directory.systemTemp.createTemp('plana-vibe-wire-');
      try {
        final dir = Directory('${root.path}/vibe_encodings')..createSync();
        await File(
          '${dir.path}/hash_v4-5full_1.00.enc',
        ).writeAsString('paid-full1');
        await File(
          '${dir.path}/hash_v4-5full_0.70.enc',
        ).writeAsString('paid-full07');
        await File(
          '${dir.path}/hash_v4-5curated_1.0.enc',
        ).writeAsString('paid-curated1');
        final cache = await VibeEncodeCache.load(supportRoot: root);
        expect(
          await cache.get('hash', 'nai-diffusion-4-5-full', 1),
          'paid-full1',
        );
        expect(await cache.get('hash', 'v4-5full', .7), 'paid-full07');
        expect(await cache.get('hash', 'v4-5curated', 1), 'paid-curated1');
        expect(await cache.get('hash', 'v4-5curated', .7), isNull);
        final raw = newImageVibeRaw(
          imageBase64: 'AAAA',
          name: 'n',
          thumbnailDataUrl: '',
          createdAtMs: 0,
        );
        for (final entry in cache.entriesForImage('hash')) {
          mergeEncodingIntoRaw(
            raw,
            modelKey: entry.modelKey,
            infoExtracted: entry.ie,
            encoding: (await cache.get('hash', entry.modelKey, entry.ie))!,
          );
        }
        expect(
          parseVibeFileText(buildVibeText(raw)).single.encodingItems,
          hasLength(3),
        );
        expect(
          await File('${dir.path}/hash_v4-5full_1.00.enc').readAsString(),
          'paid-full1',
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
