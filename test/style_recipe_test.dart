import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/style_recipes.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

const _nai = StyleRecipe(
  model: 'v4.5-full',
  steps: 28,
  cfg: 5,
  sampler: 'Euler Ancestral',
  scheduler: 'karras',
  cfgRescale: .2,
  varietyPlus: true,
);

TagEntry _artist({
  String id = 'a1',
  String name = '水彩',
  StyleRecipe? recipe,
  List<String> models = const [],
}) => TagEntry(
  id: id,
  category: TagCategory.artist,
  name: name,
  positive: 'artist:foo',
  models: models,
  recipe: recipe,
);

class _Session extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async =>
      const BotSession(sessionId: 's', botUserId: 'me');
}

class _Library extends TagLibrary {
  @override
  Future<TagLibraryState> build() async => const TagLibraryState();
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('推荐参数随条目存取；缺关键字段当没记', () {
    final e = _artist(recipe: _nai);
    final back = TagEntry.fromJson(e.toJson())!;
    expect(back.recipe!.toJson(), _nai.toJson());
    expect(StyleRecipe.fromJson({'model': 'v4.5-full', 'steps': 28}), isNull);
    expect(_artist().toJson().containsKey('recipe'), isFalse);
  });

  test('copyWith 保留适用模型与推荐参数；clearRecipe 才清掉', () {
    final e = _artist(recipe: _nai, models: ['v4.5-full']);
    final renamed = e.copyWith(name: '水彩 2');
    expect(renamed.models, ['v4.5-full']);
    expect(renamed.recipe, same(_nai));
    expect(e.copyWith(recipe: TagEntry.clearRecipe).recipe, isNull);
  });

  test('云备份带上推荐参数和适用模型，恢复回到字段里而不是 extra', () {
    final e = _artist(recipe: _nai, models: ['v4.5-full', 'v5-full']);
    final j = encodeBackupEntry(e);
    expect(j['recipe'], _nai.toJson());
    expect(j['models'], ['v4.5-full', 'v5-full']);
    final back = decodeBackupEntry(TagCategory.artist, j)!;
    expect(back.recipe!.toJson(), _nai.toJson());
    expect(back.models, ['v4.5-full', 'v5-full']);
    expect(back.extra.containsKey('recipe'), isFalse);
    expect(back.extra.containsKey('models'), isFalse);
  });

  test('早先恢复时落进 extra 的适用模型搬回字段；清空后备份不再带出旧值', () {
    final e = TagEntry.fromJson({
      'id': 'a1',
      'category': tagCategoryDef(TagCategory.artist).webId,
      'name': '水彩',
      'positive': 'x',
      'extra': {
        'models': ['v5-full'],
        'foo': 1,
      },
    })!;
    expect(e.models, ['v5-full']);
    expect(e.extra.containsKey('models'), isFalse);
    expect(e.extra['foo'], 1);
    final j = encodeBackupEntry(e.copyWith(models: const []));
    expect(j.containsKey('models'), isFalse);
    expect(j.containsKey('recipe'), isFalse);
    expect(j['foo'], 1);
  });

  test('公共库：列表带回推荐参数，发布带上，清掉发 {}，转让不碰', () async {
    final sent = <String, Map<String, dynamic>>{};
    final mock = MockClient((req) async {
      if (req.method == 'GET') {
        return _json({
          'artists': [
            {
              'id': 'p1',
              'name': '水彩',
              'artist_string': 'artist:foo',
              'models': ['v4.5-full'],
              'recipe': _nai.toJson(),
            },
            {
              'id': 'p2',
              'name': '半套',
              'artist_string': 'artist:bar',
              'recipe': {'model': 'v4.5-full', 'steps': 28},
            },
          ],
        });
      }
      sent['${req.method} ${req.url.path}'] =
          jsonDecode(req.body) as Map<String, dynamic>;
      return _json({
        'artist': {'id': 'p3', 'name': '新的'},
      });
    });
    final container = ProviderContainer(
      overrides: [
        backendClientProvider.overrideWithValue(
          BackendClient('https://plana.test'),
        ),
        botSessionProvider.overrideWith(_Session.new),
      ],
    );
    addTearDown(container.dispose);

    await http.runWithClient(() async {
      final pub = await container.read(
        publicTagsProvider(TagCategory.artist).future,
      );
      expect(pub[0].recipe!.toJson(), _nai.toJson());
      expect(pub[0].models, ['v4.5-full']);
      expect(pub[1].recipe, isNull);

      final client = container.read(backendClientProvider);
      await client.createPublicArtist(
        sessionId: 's',
        artistString: 'artist:foo',
        recipe: _nai.toJson(),
      );
      await client.updatePublicArtist(
        sessionId: 's',
        id: 'p1',
        recipe: const {},
      );
      await client.updatePublicArtist(sessionId: 's', id: 'p2', addedBy: 'x');
    }, () => mock);

    expect(sent['POST /api/artists/create']!['recipe'], _nai.toJson());
    expect(sent['PUT /api/artists/p1']!['recipe'], isEmpty);
    expect(sent['PUT /api/artists/p2']!.containsKey('recipe'), isFalse);
  });

  test('收藏公共画风：适用模型和推荐参数一起拷进本地副本', () async {
    final container = ProviderContainer(
      overrides: [tagLibraryProvider.overrideWith(_Library.new)],
    );
    addTearDown(container.dispose);
    await container.read(tagLibraryProvider.future);
    final pub = _artist(
      id: 'pub_p1',
      recipe: _nai,
      models: ['v4.5-full'],
    ).copyWith(publicId: 'p1');

    expect(
      await container.read(tagLibraryProvider.notifier).collect(pub),
      isTrue,
    );
    final fav = container.read(tagLibraryProvider).requireValue.entries.single;
    expect(fav.origin, TagOrigin.favorited);
    expect(fav.models, ['v4.5-full']);
    expect(fav.recipe!.toJson(), _nai.toJson());
  });

  test('模型对得上才套：NAI 4 / 4.5 一套、NAI 5 一套，Anima / Krea 按档位', () {
    expect(recipeFits(_nai, 'NAI 4.5 Curated'), isTrue);
    expect(recipeFits(_nai, 'NAI 4.0 Full'), isTrue);
    expect(recipeFits(_nai, 'NAI 5.0 Full'), isFalse);
    final turbo = recipeOf(
      const GenParams().copyWith(model: 'Anima Turbo').recallModalSampling(),
    );
    expect(turbo.model, 'anima-turbo');
    expect(recipeFits(turbo, 'Anima Turbo'), isTrue);
    expect(recipeFits(turbo, 'Anima Aesthetic'), isFalse);
    expect(recipeFits(turbo, 'NAI 4.5 Full'), isFalse);
  });

  // 网页端后来才有的模型:不认识就别套,当成 NAI 4 / 4.5 会把别家的采样器写进来
  test('记下时的模型这边不认识:哪个模型都对不上', () {
    const future = StyleRecipe(
      model: 'some-new-model',
      steps: 8,
      cfg: 1,
      sampler: 'er_sde',
      scheduler: 'simple',
    );
    for (final m in ['NAI 4.5 Full', 'NAI 4.0 Curated', 'NAI 5.0 Full']) {
      expect(recipeFits(future, m), isFalse, reason: m);
    }
    expect(recipeFits(future, 'Anima Turbo'), isFalse);
  });

  test('从当前参数记下、再套回去，只动当前模型那一套', () {
    final nai = const GenParams().copyWith(
      model: 'NAI 4.5 Full',
      steps: 30,
      cfg: 6.5,
      sampler: 'DPM++ 2M',
      noiseSchedule: 'exponential',
      cfgRescale: .3,
      varietyPlus: true,
    );
    final r = recipeOf(nai);
    final applied = withRecipe(const GenParams(), r);
    expect(applied.steps, 30);
    expect(applied.cfg, 6.5);
    expect(applied.sampler, 'DPM++ 2M');
    expect(applied.noiseSchedule, 'exponential');
    expect(applied.cfgRescale, .3);
    expect(applied.varietyPlus, isTrue);
    expect(applied.animaSteps, const GenParams().animaSteps);

    final anima = const GenParams().copyWith(
      model: 'Anima Aesthetic',
      animaSteps: 40,
      animaCfg: 5,
      animaSampler: 'euler',
      animaScheduler: 'beta',
    );
    final back = withRecipe(
      const GenParams().copyWith(model: 'Anima Aesthetic'),
      recipeOf(anima),
    );
    expect(back.animaSteps, 40);
    expect(back.animaScheduler, 'beta');
    expect(back.steps, const GenParams().steps);
  });

  test('一次导入多条：按选择顺序取第一条对得上的', () {
    const v5 = StyleRecipe(
      model: 'v5-full',
      steps: 23,
      cfg: 5,
      sampler: 'Euler Ancestral',
      scheduler: 'karras',
    );
    final entries = [
      _artist(id: 'a', name: '没记'),
      _artist(id: 'b', name: 'V5 的', recipe: v5),
      _artist(id: 'c', name: '4.5 的', recipe: _nai),
      _artist(id: 'd', name: '也是 4.5', recipe: _nai),
    ];
    expect(recipeToOffer(entries, 'NAI 4.5 Full')!.name, '4.5 的');
    expect(recipeToOffer(entries, 'NAI 5.0 Curated')!.name, 'V5 的');
    expect(recipeToOffer(entries, 'Anima Turbo'), isNull);
  });

  test('摘要：模型、步数、CFG，再列采样器和调度', () {
    expect(recipeBrief(_nai), 'NAI 4.5 Full · 28 步 · CFG 5');
    expect(
      recipeDetail(_nai),
      '28 步 · CFG 5 · Euler Ancestral · karras · Rescale 0.2 · Variety+',
    );
  });
}
