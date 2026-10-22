import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/nai_request.dart';
import 'package:plana_app/features/generate/state_codec.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

TagEntry entry({
  String name = '樱花',
  String positive = 'pink hair, blue eyes',
  String negative = 'red hair, red eyes',
  TagCategory category = TagCategory.character,
}) => TagEntry(
  id: 'test-$name-$positive',
  category: category,
  name: name,
  positive: positive,
  negative: negative,
);

GenerateState imported(Iterable<TagEntry> entries, {GenerateState? into}) {
  final base = into ?? GenerateState.initial();
  final result = appendTagPromptsFolded(
    positiveDraft: pickEditorText(base.promptRaw, base.prompt),
    negativeDraft: pickEditorText(base.negativePromptRaw, base.negativePrompt),
    links: base.promptFoldLinks,
    entries: entries,
  );
  final positive = outputOf(result.positiveDraft);
  final negative = outputOf(result.negativeDraft);
  return base.copyWith(
    prompt: positive,
    negativePrompt: negative,
    promptRaw: draftOf(result.positiveDraft, positive),
    negativePromptRaw: draftOf(result.negativeDraft, negative),
    promptFoldLinks: result.links,
  );
}

void main() {
  late AppStores stores;
  late ProviderContainer container;
  late GenerateNotifier gen;
  late EditorNotifier editor;

  setUp(() {
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    gen = container.read(generateProvider.notifier);
    editor = container.read(editorProvider.notifier);
  });
  tearDown(() async {
    container.dispose();
    stores.flushNow();
    await stores.workspace.idle;
  });

  void use(GenerateState source) {
    gen.setPrompts(
      positive: source.prompt,
      negative: source.negativePrompt,
      positiveRaw: source.promptRaw,
      negativeRaw: source.negativePromptRaw,
      promptFoldLinks: source.promptFoldLinks,
    );
  }

  void load({bool positive = true, String? charId}) {
    final input = container.read(generateProvider);
    final character = input.characters.where((c) => c.id == charId).firstOrNull;
    editor.load(
      positive: pickEditorText(
        character?.positiveRaw ?? input.promptRaw,
        character?.positive ?? input.prompt,
      ),
      negative: pickEditorText(
        character?.negativeRaw ?? input.negativePromptRaw,
        character?.negative ?? input.negativePrompt,
      ),
      startPositive: positive,
      charId: charId,
    );
  }

  void remove(String name) {
    final state = container.read(editorProvider);
    final fold = parseFoldRefs(
      state.activeText,
      state.foldBodies,
    ).singleWhere((r) => r.name == name);
    editor.editActive(
      deleteFoldRef(state.activeText, fold).$1,
      structural: true,
    );
  }

  test(
    'all inspiration categories fold both sides, including single words, without exposing IDs',
    () {
      final source = imported([
        for (final category in TagCategory.values)
          entry(
            name: '条目-${category.name}',
            category: category,
            positive: '${category.name} positive',
            negative: '${category.name} negative',
          ),
      ]);
      expect(parseFolds(source.promptRaw), hasLength(4));
      expect(parseFolds(source.negativePromptRaw), hasLength(4));
      expect(source.promptFoldLinks, hasLength(4));
      expect(
        source.promptFoldLinks.map((link) => link.id).toSet(),
        hasLength(4),
      );
      for (final link in source.promptFoldLinks) {
        expect(link.negativeName, '${link.positiveName}·排除');
        expect(source.promptRaw, isNot(contains(link.id)));
        expect(source.negativePromptRaw, isNot(contains(link.id)));
      }
      final body = buildNaiPayload(source, presetId: '').body;
      final request = jsonEncode(body);
      expect(request, isNot(contains('<#')));
      expect(request, isNot(contains('foldLinks')));
      expect(request, isNot(contains('条目-')));
      for (final link in source.promptFoldLinks) {
        expect(request, isNot(contains(link.id)));
        expect(request, contains(link.positiveBody));
        expect(request, contains(link.negativeBody));
      }
    },
  );

  test(
    'dedup imports only new weighted words and never adopts pre-existing text',
    () {
      final source = imported(
        [
          entry(
            positive: '1.4::pink hair, blue eyes::',
            negative: '{red hair, red eyes}',
          ),
        ],
        into: GenerateState.initial().copyWith(
          prompt: 'pink hair',
          negativePrompt: 'red hair',
        ),
      );
      final link = source.promptFoldLinks.single;
      expect(link.positiveBody, isNot(contains('pink hair')));
      expect(link.negativeBody, isNot(contains('red hair')));
      expect(parseToks(link.positiveBody).single.effMult, closeTo(1.4, 1e-9));
      expect(parseToks(link.negativeBody).single.effMult, closeTo(1.05, 1e-9));
      use(source);
      load();
      remove(container.read(editorProvider).foldLinks.single.positiveName);
      expect(editor.outputPositive(), 'pink hair');
      expect(editor.outputNegative(), 'red hair');
      final repeated = imported([
        entry(
          positive: '1.4::pink hair, blue eyes::',
          negative: '{red hair, red eyes}',
        ),
      ], into: source);
      expect(repeated.promptRaw, source.promptRaw);
      expect(repeated.negativePromptRaw, source.negativePromptRaw);
      expect(repeated.promptFoldLinks, source.promptFoldLinks);
    },
  );

  test(
    'one-sided new import is folded but does not bind the existing other side',
    () {
      final source = imported(
        [entry()],
        into: GenerateState.initial().copyWith(prompt: 'pink hair, blue eyes'),
      );
      expect(source.promptFoldLinks, isEmpty);
      expect(source.promptRaw, isEmpty);
      expect(parseFolds(source.negativePromptRaw), hasLength(1));
      use(source);
      load(positive: false);
      remove(
        parseFoldRefs(
          container.read(editorProvider).negativeText,
          container.read(editorProvider).foldBodies,
        ).single.name,
      );
      expect(editor.outputPositive(), source.prompt);
      expect(editor.outputNegative(), isEmpty);
    },
  );

  for (final positive in [true, false]) {
    test(
      'deleting ${positive ? 'positive' : 'negative'} removes only its pair and undo restores both',
      () {
        final original = imported(
          [
            entry(name: '同名'),
            entry(name: '同名', positive: 'forest, moon', negative: 'city, noon'),
          ],
          into: GenerateState.initial().copyWith(
            prompt: 'unrelated positive',
            negativePrompt: 'unrelated negative',
            promptRaw: '<#同名: unrelated positive#>',
            negativePromptRaw: '<#同名: unrelated negative#>',
          ),
        );
        use(original);
        load(positive: positive);
        final before = container.read(editorProvider);
        final link = before.foldLinks.first;
        remove(positive ? link.positiveName : link.negativeName);
        expect(editor.outputPositive(), 'unrelated positive, forest, moon');
        expect(editor.outputNegative(), 'unrelated negative, city, noon');
        expect(container.read(editorProvider).foldLinks, [
          before.foldLinks.last,
        ]);
        editor.flushWriteBack();
        expect(container.read(generateProvider).promptFoldLinks, [
          before.foldLinks.last,
        ]);
        editor.undo();
        expect(
          container.read(editorProvider).positiveText,
          before.positiveText,
        );
        expect(
          container.read(editorProvider).negativeText,
          before.negativeText,
        );
        expect(container.read(editorProvider).foldLinks, before.foldLinks);
        editor.flushWriteBack();
        expect(
          container.read(generateProvider).promptFoldLinks,
          before.foldLinks,
        );
      },
    );
  }

  test(
    'registered manual same-name same-body fold keeps independent identity',
    () {
      use(imported([entry()]));
      load();
      final original = container.read(editorProvider).foldLinks.single;
      final name = editor.registerFold(
        original.positiveName,
        original.positiveBody,
      );
      expect(name, isNot(original.positiveName));
      editor.editActive(
        '${container.read(editorProvider).positiveText}, ${foldRefLiteral(name)}',
        structural: true,
      );
      remove(original.positiveName);
      expect(editor.outputPositive(), original.positiveBody);
      expect(editor.outputNegative(), isEmpty);
      expect(
        parseFoldRefs(
          container.read(editorProvider).positiveText,
          container.read(editorProvider).foldBodies,
        ).single.name,
        name,
      );
    },
  );

  test(
    'explicit multi-unfold detaches both groups without deleting negative words',
    () {
      use(
        imported([
          entry(),
          entry(name: '夜景', positive: 'night', negative: 'day'),
        ]),
      );
      load();
      final before = container.read(editorProvider);
      var text = before.activeText;
      for (final fold in parseFoldRefs(text, before.foldBodies).reversed) {
        text = unfoldRef(text, fold, before.foldBodies);
      }
      editor.editActive(text, structural: true, detachRemovedFolds: true);
      expect(editor.outputNegative(), 'red hair, red eyes, day');
      expect(container.read(editorProvider).foldLinks, isEmpty);
      editor.setActivePositive(false);
      remove(before.foldLinks.first.negativeName);
      expect(editor.outputPositive(), 'pink hair, blue eyes, night');
      editor.undo();
      editor.undo();
      expect(container.read(editorProvider).foldLinks, before.foldLinks);
      expect(container.read(editorProvider).positiveText, before.positiveText);
    },
  );

  for (final wrapper in ['{}', '1.3::::', '~~']) {
    test(
      'manual unfolding within $wrapper wrapper does not delete counterpart',
      () {
        use(imported([entry()]));
        load();
        final before = container.read(editorProvider);
        final wrapped = switch (wrapper) {
          '{}' => '{${before.positiveText}}',
          '~~' => '~${before.positiveText}~',
          _ => '1.3::${before.positiveText}::',
        };
        editor.editActive(wrapped, structural: true);
        final state = container.read(editorProvider);
        final outputBeforeUnfold = outputOf(
          expandFolds(state.activeText, state.foldBodies),
        );
        final fold = parseFoldRefs(state.activeText, state.foldBodies).single;
        editor.editActive(
          unfoldRef(state.activeText, fold, state.foldBodies),
          structural: true,
          detachRemovedFolds: true,
        );
        expect(editor.outputPositive(), outputBeforeUnfold);
        expect(editor.outputNegative(), 'red hair, red eyes');
        expect(container.read(editorProvider).foldLinks, isEmpty);
        editor.flushWriteBack();
        load(positive: false);
        remove(
          parseFoldRefs(
            container.read(editorProvider).activeText,
            container.read(editorProvider).foldBodies,
          ).single.name,
        );
        expect(
          editor.outputPositive(),
          wrapper == '~~'
              ? ''
              : outputOf(
                  wrapped.replaceAll(
                    foldRefLiteral(before.foldLinks.single.positiveName),
                    before.foldLinks.single.positiveBody,
                  ),
                ),
        );
      },
    );
  }

  test(
    'renaming or replacing a fold detaches without deleting opposite content',
    () {
      use(imported([entry()]));
      load();
      final before = container.read(editorProvider);
      final newName = editor.registerFold(
        '改名',
        before.foldLinks.single.positiveBody,
      );
      editor.editActive(foldRefLiteral(newName), structural: true);
      expect(editor.outputNegative(), 'red hair, red eyes');
      expect(container.read(editorProvider).foldLinks, isEmpty);
      editor.undo();
      expect(container.read(editorProvider).foldLinks, before.foldLinks);
    },
  );

  test(
    'old unlinked drafts and ambiguous duplicate anchors never infer a pair',
    () {
      final original = imported([entry()]);
      for (final source in [
        original.copyWith(promptFoldLinks: []),
        original.copyWith(
          prompt: '${original.prompt}, ${original.prompt}',
          promptRaw: '${original.promptRaw}, ${original.promptRaw}',
        ),
      ]) {
        use(source);
        load();
        expect(container.read(editorProvider).foldLinks, isEmpty);
        final state = container.read(editorProvider);
        editor.editActive(
          deleteFoldRef(
            state.activeText,
            parseFoldRefs(state.activeText, state.foldBodies).first,
          ).$1,
          structural: true,
        );
        expect(editor.outputNegative(), original.negativePrompt);
      }
    },
  );

  test(
    'external prompt/raw replacement clears stale links, parameter edits retain them',
    () {
      final original = imported([entry()]);
      expect(
        original
            .copyWith(params: original.params.copyWith(seed: '42'))
            .promptFoldLinks,
        original.promptFoldLinks,
      );
      expect(original.copyWith(prompt: 'external').promptFoldLinks, isEmpty);
      expect(original.copyWith(negativePromptRaw: '').promptFoldLinks, isEmpty);
      use(original);
      gen.setPrompts(negative: 'external');
      expect(container.read(generateProvider).promptFoldLinks, isEmpty);
      use(original);
      gen.setPrompts(promptFoldLinks: []);
      expect(container.read(generateProvider).promptFoldLinks, isEmpty);
      expect(container.read(generateProvider).promptRaw, original.promptRaw);
    },
  );

  test(
    'codec and actual workspace reload preserve links, character scope and pure request words',
    () async {
      final original = imported([entry()]);
      use(original);
      gen.addNamedCharactersFrom([
        (
          avatar: null,
          name: '角色',
          positive: original.prompt,
          negative: original.negativePrompt,
        ),
      ]);
      final id = container.read(generateProvider).characters.single.id;
      gen.updateCharacter(
        id,
        positiveRaw: original.promptRaw,
        negativeRaw: original.negativePromptRaw,
        foldLinks: original.promptFoldLinks,
      );
      final encoded = await encodeGenerateState(
        container.read(generateProvider),
        stores.blobs,
      );
      final decoded = await decodeGenerateState(
        jsonDecode(jsonEncode(encoded.json)),
        stores.blobs,
      );
      expect(decoded.promptFoldLinks, original.promptFoldLinks);
      expect(decoded.characters.single.foldLinks, original.promptFoldLinks);
      final malformed = Map<String, dynamic>.from(encoded.json)
        ..['promptFoldLinks'] = [
          {'id': 'incomplete'},
          null,
        ];
      expect(
        (await decodeGenerateState(malformed, stores.blobs)).promptFoldLinks,
        isEmpty,
      );
      stores.workspace.flush();
      await stores.workspace.idle;
      await stores.workspace.load();
      container.dispose();
      container = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      gen = container.read(generateProvider.notifier);
      editor = container.read(editorProvider.notifier);
      expect(
        container.read(generateProvider).promptFoldLinks,
        original.promptFoldLinks,
      );
      load(positive: false, charId: id);
      remove(container.read(editorProvider).foldLinks.single.negativeName);
      editor.flushWriteBack();
      final after = container.read(generateProvider);
      expect(after.prompt, original.prompt);
      expect(after.negativePrompt, original.negativePrompt);
      expect(after.characters.single.positive, isEmpty);
      expect(after.characters.single.negative, isEmpty);
      expect(after.characters.single.foldLinks, isEmpty);
      editor.undo();
      editor.flushWriteBack();
      expect(
        container.read(generateProvider).characters.single.foldLinks,
        original.promptFoldLinks,
      );
      gen.removeCharacter(id);
      editor.flushWriteBack();
      expect(container.read(generateProvider).characters, isEmpty);
      expect(
        container.read(generateProvider).promptFoldLinks,
        original.promptFoldLinks,
      );
    },
  );

  test(
    'editor reload remaps imported anchors around same-name archived bodies and retains undo',
    () {
      gen.setPrompts(
        positive: 'old',
        negative: 'old exclusion',
        positiveRaw: '<#樱花: old#>',
        negativeRaw: '<#樱花·排除: old exclusion#>',
      );
      load();
      use(imported([entry()]));
      load();
      final mapped = container.read(editorProvider).foldLinks.single;
      expect(mapped.positiveName, '樱花 2');
      expect(mapped.negativeName, '樱花·排除 2');
      editor.flushWriteBack();
      load(positive: false);
      remove(mapped.negativeName);
      editor.flushWriteBack();
      load();
      editor.undo();
      editor.flushWriteBack();
      final restored = container.read(generateProvider);
      expect(restored.promptFoldLinks.single, mapped);
      expect(restored.prompt, 'pink hair, blue eyes');
      expect(restored.negativePrompt, 'red hair, red eyes');
    },
  );
}
