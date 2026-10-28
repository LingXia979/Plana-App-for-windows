import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/backend_config.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/prompt_sections.dart';
import 'package:plana_app/features/generate/gen_modules.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';

class _Session extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async =>
      const BotSession(sessionId: 'local-test');
}

class _Backend extends BackendBaseNotifier {
  _Backend(this.base);
  final String base;
  @override
  Future<String> build() async => base;
}

class _Library extends TagLibrary {
  @override
  Future<TagLibraryState> build() async => const TagLibraryState(
    entries: [
      TagEntry(
        id: 'a',
        name: 'A',
        category: TagCategory.artist,
        positive: 'artist:foo',
        negative: 'local negative',
      ),
      TagEntry(
        id: 'unused',
        name: 'Unused',
        category: TagCategory.artist,
        positive: 'artist:unused',
        negative: 'unused negative',
      ),
    ],
  );
  void change() => state = const AsyncData(
    TagLibraryState(
      entries: [
        TagEntry(
          id: 'a',
          name: 'A',
          category: TagCategory.artist,
          positive: 'artist:foo',
          negative: 'edited during request',
        ),
      ],
    ),
  );
}

class _Rules extends RulesLibraryNotifier {
  @override
  Future<RulesLibrary> build() async => const RulesLibrary();
}

class _LocalHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in SectionImport.values) {
    test(
      'inactive canvas ${mode.name} import matches preview and fully undoes',
      () async {
        final stores = AppStores.ephemeral();
        stores.assistant.initialCurrent = const [
          AssistantMsg(
            id: 'r',
            role: MsgRole.ai,
            text: '',
            at: 1,
            draw: DrawProposal(
              positive: 'new scene, watercolor',
              negative: 'lowres, blurry',
            ),
          ),
        ];
        final c = ProviderContainer(
          overrides: [appStoresProvider.overrideWithValue(stores)],
        );
        try {
          await c.read(assistantSettingsProvider.future);
          await c
              .read(assistantSettingsProvider.notifier)
              .patch((s) => s.copyWith(importTo: mode));
          c.invalidate(assistantSettingsProvider);
          expect(
            (await c.read(assistantSettingsProvider.future)).importTo,
            mode,
          );
          final gen = c.read(generateProvider.notifier);
          final original = GenerateState.initial().copyWith(
            prompt: 'forest',
            promptRaw: '<#scene: forest#>',
            negativePrompt: 'lowres',
            sections: const [
              PromptSection.main(),
              PromptSection(
                id: 's',
                name: '风格',
                positive: 'watercolor',
                negative: 'blurry',
                positiveRaw: '<#style: watercolor#>',
                negativeRaw: '<#negative: blurry#>',
              ),
            ],
          );
          gen.applyCanvas(CanvasPrompts.of(original), force: true);
          final canvases = c.read(canvasWorkspaceProvider.notifier);
          final source = c.read(canvasWorkspaceProvider).activeId;
          final other = canvases.create();
          gen.setPrompts(positive: 'leave me alone');
          final assistant = c.read(assistantProvider.notifier);
          final preview = assistant.previewSendState('r', canvasId: source)!;
          expect(assistant.applyProposal('r', canvasId: source), isTrue);
          expect(c.read(canvasWorkspaceProvider).activeId, other);
          expect(c.read(generateProvider).prompt, 'leave me alone');
          final changed = c
              .read(canvasWorkspaceProvider)
              .find(source)!
              .prompts
              .applyTo(original);
          final sent = stripHiddenModules(changed, const GenModuleSettings());
          expect(sent.prompt, preview.prompt);
          expect(sent.negativePrompt, preview.negativePrompt);
          expect(changed.sections.length, switch (mode) {
            SectionImport.main => 2,
            SectionImport.newSection => 3,
            SectionImport.clear => 0,
          });
          if (mode != SectionImport.clear) {
            expect(
              changed.sections[1].positiveRaw,
              original.sections[1].positiveRaw,
            );
          }
          expect(assistant.undo('r'), isTrue);
          canvases.select(source);
          expect(
            PromptSnapshot.of(
              c.read(generateProvider),
            ).sameAs(PromptSnapshot.of(original)),
            isTrue,
          );
        } finally {
          c.dispose();
          await stores.flushForExit();
        }
      },
    );
  }

  test('old and unknown import preferences default to replacing main', () {
    expect(AssistantSettings.fromJson({}).importTo, SectionImport.main);
    expect(
      AssistantSettings.fromJson({'importTo': 'future-choice'}).importTo,
      SectionImport.main,
    );
  });
  test(
    'import dedup never removes members of disabled, folded or weighted groups',
    () {
      const sections = [PromptSection(id: 's', name: 's', positive: 'middle')];
      for (final group in [
        '~first, middle, last~',
        '<#fold: first, middle, last#>',
        '1.2::first, middle, last::',
        '{first, middle, last}',
        '[first, middle, last]',
      ]) {
        expect(
          dropSectionWords('$group, middle', sections, '', positive: true),
          group,
        );
        expect(
          dropSectionWords(
            'middle',
            [PromptSection(id: 's', name: 's', positive: group)],
            '',
            positive: true,
          ),
          'middle',
        );
      }
    },
  );
  test(
    'artist negatives ignore name prefixes and disabled strings but accept weights',
    () {
      const artist = TagEntry(
        id: 'a',
        name: 'a',
        category: TagCategory.artist,
        positive: 'artist:foo',
        negative: 'blurry',
      );
      for (final text in [
        'artist:foobar',
        'artist:foo (alternate)',
        '~artist:foo~',
      ]) {
        expect(
          withArtistNegatives(DrawProposal(positive: text), [artist]),
          isEmpty,
        );
      }
      expect(
        withArtistNegatives(
          const DrawProposal(positive: '1.3::artist:foo::, forest'),
          [artist],
        ),
        'blurry',
      );
    },
  );

  for (final (scope, publicFailure) in [
    for (final s in LibraryScope.values) (s, false),
    (LibraryScope.all, true),
  ]) {
    test(
      'artist negative scope ${scope.name} (public failure: $publicFailure) uses the request library and retains source sections',
      () async {
        final received = Completer<void>(), release = Completer<void>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final stores = AppStores.ephemeral();
        var publicLoads = 0;
        Map<String, dynamic>? body;
        server.listen((request) async {
          body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          received.complete();
          await release.future;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'event: final\ndata: {"positive":"<<artist:A:artist:foo>>, artist:public"}\n\n',
          );
          await request.response.close();
        });
        final c = ProviderContainer(
          overrides: [
            appStoresProvider.overrideWithValue(stores),
            botSessionProvider.overrideWith(_Session.new),
            backendBaseProvider.overrideWith(
              () => _Backend('http://127.0.0.1:${server.port}'),
            ),
            assistantEndpointProvider.overrideWithValue(null),
            agentModelsProvider.overrideWith(
              (_) async => const AgentModelList(),
            ),
            rulesLibraryProvider.overrideWith(_Rules.new),
            tagLibraryProvider.overrideWith(_Library.new),
            publicTagsProvider.overrideWith((ref, category) async {
              publicLoads++;
              await Future<void>.delayed(const Duration(milliseconds: 20));
              if (publicFailure) throw StateError('Public library unavailable');
              return const [
                TagEntry(
                  id: 'p',
                  name: 'p',
                  category: TagCategory.artist,
                  positive: 'artist:public',
                  negative: 'public negative',
                ),
              ];
            }),
          ],
        );
        final done = Completer<void>();
        final listener = c.listen(assistantProvider, (previous, next) {
          if (previous?.running == true && !next.running && !done.isCompleted) {
            done.complete();
          }
        });
        try {
          await c.read(backendBaseProvider.future);
          await c.read(assistantSettingsProvider.future);
          await c
              .read(assistantSettingsProvider.notifier)
              .patch(
                (s) => s.copyWith(
                  libraryScope: scope,
                  autoImport: true,
                  stream: false,
                ),
              );
          final gen = c.read(generateProvider.notifier);
          gen.applyCanvas(
            CanvasPrompts.of(
              GenerateState.initial().copyWith(
                sections: const [
                  PromptSection.main(),
                  PromptSection(
                    id: 'style',
                    name: 'style',
                    positive: 'watercolor',
                  ),
                ],
              ),
            ),
            force: true,
          );
          final source = c.read(canvasWorkspaceProvider).activeId;
          final assistant = c.read(assistantProvider.notifier);
          await HttpOverrides.runWithHttpOverrides(
            () => assistant.send('draw', withCanvas: true),
            _LocalHttp(),
          );
          await received.future.timeout(const Duration(seconds: 10));
          if (scope != LibraryScope.none) {
            (c.read(tagLibraryProvider.notifier) as _Library).change();
          }
          await c
              .read(assistantSettingsProvider.notifier)
              .patch((s) => s.copyWith(libraryScope: LibraryScope.none));
          final other = c.read(canvasWorkspaceProvider.notifier).create();
          gen.setPrompts(positive: 'other canvas');
          release.complete();
          await done.future.timeout(const Duration(seconds: 10));
          final reply = c.read(assistantProvider).msgs.last;
          expect(reply.role, MsgRole.ai, reason: reply.text);
          expect(reply.draw!.negative, switch (scope) {
            LibraryScope.none => '',
            LibraryScope.local => 'local negative',
            LibraryScope.all =>
              publicFailure
                  ? 'local negative'
                  : 'local negative, public negative',
          });
          expect(publicLoads, scope == LibraryScope.all ? 1 : 0);
          expect(body!['current_positive'], 'watercolor');
          expect(reply.change!.canvasId, source);
          expect(c.read(canvasWorkspaceProvider).activeId, other);
          expect(c.read(generateProvider).prompt, 'other canvas');
          expect(
            c
                .read(canvasWorkspaceProvider)
                .find(source)!
                .prompts
                .sections
                .last
                .positive,
            'watercolor',
          );
        } finally {
          if (!release.isCompleted) release.complete();
          listener.close();
          c.dispose();
          await stores.flushForExit();
          await server.close(force: true);
        }
      },
    );
  }
  test(
    'default assistant import keeps sections and undo targets the original canvas',
    () async {
      final stores = AppStores.ephemeral();
      stores.assistant.initialCurrent = const [
        AssistantMsg(
          id: 'reply',
          role: MsgRole.ai,
          text: 'reply',
          at: 1,
          draw: DrawProposal(
            positive: 'new scene, watercolor',
            negative: 'lowres, blurry',
          ),
        ),
      ];
      final c = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      try {
        final gen = c.read(generateProvider.notifier);
        gen.applyCanvas(
          CanvasPrompts.of(
            GenerateState.initial().copyWith(
              prompt: 'old scene',
              negativePrompt: 'lowres',
              sections: const [
                PromptSection.main(),
                PromptSection(
                  id: 'style',
                  name: '画风',
                  positive: 'watercolor',
                  negative: 'blurry',
                  positiveRaw: '<#style: watercolor#>',
                  artist: true,
                ),
              ],
            ),
          ),
          force: true,
        );
        final source = c.read(canvasWorkspaceProvider).activeId;
        final before = PromptSnapshot.of(c.read(generateProvider));
        final assistant = c.read(assistantProvider.notifier);
        expect(assistant.applyProposal('reply'), isTrue);
        final after = c.read(generateProvider);
        expect(after.prompt, 'new scene');
        expect(after.sections.last.positive, 'watercolor');
        expect(after.sections.last.positiveRaw, '<#style: watercolor#>');
        expect(composeSections(after).negativePrompt, 'lowres, blurry');
        final other = c.read(canvasWorkspaceProvider.notifier).create();
        gen.setPrompts(positive: 'keep this canvas');
        expect(assistant.undo('reply'), isTrue);
        expect(c.read(canvasWorkspaceProvider).activeId, other);
        expect(c.read(generateProvider).prompt, 'keep this canvas');
        c.read(canvasWorkspaceProvider.notifier).select(source);
        expect(
          PromptSnapshot.of(c.read(generateProvider)).sameAs(before),
          isTrue,
        );
      } finally {
        c.dispose();
        await stores.flushForExit();
      }
    },
  );

  test(
    'stopping during public library loading never starts the AI request',
    () async {
      final loading = Completer<void>();
      final public = Completer<List<TagEntry>>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((r) async {
        requests++;
        r.response.statusCode = 500;
        await r.response.close();
      });
      final stores = AppStores.ephemeral();
      final c = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          botSessionProvider.overrideWith(_Session.new),
          backendBaseProvider.overrideWith(
            () => _Backend('http://127.0.0.1:${server.port}'),
          ),
          assistantEndpointProvider.overrideWithValue(null),
          agentModelsProvider.overrideWith((_) async => const AgentModelList()),
          rulesLibraryProvider.overrideWith(_Rules.new),
          tagLibraryProvider.overrideWith(_Library.new),
          publicTagsProvider.overrideWith((ref, category) {
            loading.complete();
            return public.future;
          }),
        ],
      );
      try {
        await c.read(backendBaseProvider.future);
        await c.read(assistantSettingsProvider.future);
        await c
            .read(assistantSettingsProvider.notifier)
            .patch((s) => s.copyWith(libraryScope: LibraryScope.all));
        final assistant = c.read(assistantProvider.notifier);
        final send = HttpOverrides.runWithHttpOverrides(
          () => assistant.send('draw', withCanvas: false),
          _LocalHttp(),
        );
        await loading.future.timeout(const Duration(seconds: 10));
        assistant.stop();
        public.complete(const []);
        await send;
        expect(requests, 0);
        expect(c.read(assistantProvider).running, isFalse);
        expect(
          c.read(assistantProvider).msgs.where((m) => m.draw != null),
          isEmpty,
        );
      } finally {
        if (!public.isCompleted) public.complete(const []);
        c.dispose();
        await stores.flushForExit();
        await server.close(force: true);
      }
    },
  );
}
