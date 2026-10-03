import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/agent_stream.dart';
import 'package:plana_app/core/net/backend_config.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/agent_trace.dart';
import 'package:plana_app/features/assistant/assistant_images.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/direct_agent.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';
import 'package:plana_app/features/assistant/session_store.dart';

class _TestSession extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async =>
      const BotSession(sessionId: 'local-test');
}

class _TestSettings extends AssistantSettingsNotifier {
  @override
  Future<AssistantSettings> build() async => const AssistantSettings(
    introVersion: kAssistantIntroVersion,
    libraryScope: LibraryScope.none,
    stream: false,
  );
}

class _TestRules extends RulesLibraryNotifier {
  @override
  Future<RulesLibrary> build() async => const RulesLibrary();
}

class _TestBackend extends BackendBaseNotifier {
  _TestBackend(this.base);
  final String base;
  @override
  Future<String> build() async => base;
}

class _LocalHttp extends HttpOverrides {}

Uint8List picture(int width, int height, img.Color color) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: color);
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppStores stores;
  ProviderContainer? container;

  setUp(() {
    stores = AppStores.ephemeral();
    temp = stores.desktopOutput.root.parent;
  });

  tearDown(() async {
    container?.dispose();
    container = null;
    stores.flushNow();
    await stores.assistant.idle;
    await stores.workspace.idle;
    await stores.ledger.idle;
    await stores.albums.idle;
    await stores.gallery.idle;
    await stores.desktopOutput.idle;
    await temp.delete(recursive: true);
  });

  Future<ProviderContainer> boot(String base) async {
    final c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        botSessionProvider.overrideWith(_TestSession.new),
        assistantEndpointProvider.overrideWithValue(null),
        backendBaseProvider.overrideWith(() => _TestBackend(base)),
        assistantSettingsProvider.overrideWith(_TestSettings.new),
        rulesLibraryProvider.overrideWith(_TestRules.new),
      ],
    );
    container = c;
    await c.read(backendBaseProvider.future);
    await c.read(assistantSettingsProvider.future);
    return c;
  }

  Future<void> turn(ProviderContainer c, Future<void> Function() start) async {
    final completed = Completer<void>();
    final listener = c.listen(assistantProvider, (before, after) {
      if (before?.running == true && !after.running && !completed.isCompleted) {
        completed.complete();
      }
    });
    try {
      await HttpOverrides.runWithHttpOverrides(start, _LocalHttp());
      await completed.future.timeout(const Duration(seconds: 15));
    } finally {
      listener.close();
    }
  }

  test(
    'old imageHash joins ordered attachments and copy/JSON keep all images',
    () {
      const legacy = AssistantMsg(
        id: 'old',
        role: MsgRole.user,
        text: '',
        at: 1,
        imageHash: 'old-hash',
      );
      expect(legacy.imageHashes, ['old-hash']);
      final decoded = AssistantMsg.fromJson({
        'id': 'legacy',
        'role': 'user',
        'imageHash': 'old-hash',
      });
      expect(decoded.imageHashes, ['old-hash']);
      const multiple = AssistantMsg(
        id: 'new',
        role: MsgRole.user,
        text: 'all',
        at: 2,
        imageHashes: ['first', 'second', 'first'],
      );
      final restored = AssistantMsg.fromJson(
        multiple.copyWith(text: 'edited').toJson(),
      );
      expect(restored.text, 'edited');
      expect(restored.imageHash, 'first');
      expect(restored.imageHashes, ['first', 'second', 'first']);
      expect(() => restored.imageHashes.add('mutated'), throwsUnsupportedError);
      expect(restored.toJson()['imageHash'], 'first');
    },
  );

  test(
    'current and archived attachment originals survive restart and blob GC',
    () async {
      final originals = [
        picture(7, 12, img.ColorRgb8(240, 20, 20)),
        picture(12, 7, img.ColorRgb8(20, 20, 240)),
        picture(9, 9, img.ColorRgb8(20, 240, 20)),
      ];
      final hashes = await stores.assistant.putImages(originals);
      stores.assistant.schedule(
        [
          AssistantMsg(
            id: 'current',
            role: MsgRole.user,
            text: '',
            at: 1,
            imageHashes: hashes.take(2).toList(),
          ),
        ],
        [
          ArchivedSession(
            id: 3,
            at: 3,
            msgs: [
              AssistantMsg(
                id: 'archived',
                role: MsgRole.user,
                text: '',
                at: 3,
                imageHash: hashes.last,
              ),
            ],
          ),
        ],
      );
      expect(await stores.assistant.liveRefs(), hashes.toSet());
      stores.assistant.flush();
      await stores.assistant.idle;
      final restored = AssistantStore(stores.blobs, temp);
      await restored.load();
      expect(
        restored.initialCurrent.single.imageHashes,
        hashes.take(2).toList(),
      );
      expect(restored.initialSessions.single.msgs.single.imageHashes, [
        hashes.last,
      ]);
      final live = await restored.liveRefs(strict: true);
      expect(live, hashes.toSet());
      await stores.blobs.gc(live, minAge: Duration.zero);
      for (var i = 0; i < originals.length; i++) {
        expect(await restored.image(hashes[i]), originals[i]);
      }
    },
  );

  test(
    'numbered reference sheet preserves portrait/landscape corners and order',
    () async {
      final portrait = picture(60, 120, img.ColorRgb8(240, 20, 20));
      final landscape = picture(120, 60, img.ColorRgb8(20, 20, 240));
      final encoded = await prepareAssistantReferenceSheet([
        portrait,
        landscape,
      ]);
      final sheet = img.decodeJpg(encoded)!;
      expect(sheet.width, 2096);
      expect(sheet.height, 1056);
      // 1024px cells with a 40px number band, centered without upscaling/cropping.
      final firstX = 16 + (1024 - 60) ~/ 2;
      final firstY = 16 + 40 + (984 - 120) ~/ 2;
      final secondX = 1056 + (1024 - 120) ~/ 2;
      final secondY = 16 + 40 + (984 - 60) ~/ 2;
      for (final point in [
        (firstX + 3, firstY + 3),
        (firstX + 56, firstY + 116),
      ]) {
        final pixel = sheet.getPixel(point.$1, point.$2);
        expect(pixel.r, greaterThan(200));
        expect(pixel.b, lessThan(60));
      }
      for (final point in [
        (secondX + 3, secondY + 3),
        (secondX + 116, secondY + 56),
      ]) {
        final pixel = sheet.getPixel(point.$1, point.$2);
        expect(pixel.b, greaterThan(200));
        expect(pixel.r, lessThan(60));
      }
      for (final x in [16, 1056]) {
        final band = img.copyCrop(sheet, x: x, y: 16, width: 80, height: 40);
        expect(
          band.any((pixel) => pixel.r < 100 && pixel.g < 100 && pixel.b < 100),
          isTrue,
        );
      }
    },
  );

  for (final format in AgentApiFormat.values) {
    test(
      '${format.name}: real HTTP sends all image blocks again after a tool hop',
      () async {
        final originals = [
          picture(6, 10, img.ColorRgb8(230, 20, 10)),
          picture(10, 6, img.ColorRgb8(10, 20, 230)),
        ];
        final requests = <Map<String, dynamic>>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          requests.add(
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>,
          );
          final reply = requests.length == 1
              ? '```tool_call\n{"name":"search_artist","arguments":{"query":"test"}}\n```'
              : '全部图片已收到';
          final response = switch (format) {
            AgentApiFormat.openai => {
              'choices': [
                {
                  'message': {'content': reply},
                },
              ],
            },
            AgentApiFormat.google => {
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': reply},
                    ],
                  },
                },
              ],
            },
            AgentApiFormat.anthropic => {
              'content': [
                {'type': 'text', 'text': reply},
              ],
            },
          };
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(response));
          await request.response.close();
        });
        final endpoint = CustomEndpoint(
          id: 'local',
          name: 'fake',
          format: format,
          baseUrl: 'http://127.0.0.1:${server.port}',
          apiPath: '/reply',
          apiKey: 'fake-only-key',
          model: 'local-fake-model',
        );
        final trace = AgentTrace(
          startedAt: 1,
          route: AgentTrace.routeCustom,
          userText: '两张',
        );
        final events = await HttpOverrides.runWithHttpOverrides(
          () => streamDirectPrompt(
            endpoint: endpoint,
            backendBase: '',
            sessionId: '',
            userRequest: '两张',
            // Exercise the retained single-image parameter together with images.
            image: originals.first,
            images: [originals.last],
            rules: const [],
            libraryScope: 'none',
            stream: false,
            trace: trace,
          ).toList(),
          _LocalHttp(),
        );
        expect(events.last, isA<AgentDone>());
        expect(requests, hasLength(2));
        for (final request in requests) {
          final messages =
              request[format == AgentApiFormat.google ? 'contents' : 'messages']
                  as List;
          final user = messages.firstWhere((m) => m['role'] == 'user') as Map;
          final parts =
              user[format == AgentApiFormat.google ? 'parts' : 'content']
                  as List;
          expect(parts, hasLength(3));
          final actual = <String>[
            for (final part in parts.take(2))
              switch (format) {
                AgentApiFormat.openai =>
                  (part['image_url']['url'] as String).split(',').last,
                AgentApiFormat.google => part['inlineData']['data'] as String,
                AgentApiFormat.anthropic => part['source']['data'] as String,
              },
          ];
          expect(actual, originals.map(base64Encode).toList());
        }
        final log = jsonEncode(trace.toJson());
        for (final original in originals) {
          expect(log, isNot(contains(base64Encode(original))));
        }
        expect(log, isNot(contains('fake-only-key')));
        expect(trace.messages!.single['images'], contains('#2'));
      },
    );
  }

  test(
    'bot HTTP gets one complete numbered sheet; failure/retry preserves all originals',
    () async {
      final originals = [
        picture(10, 20, img.ColorRgb8(230, 20, 20)),
        picture(20, 10, img.ColorRgb8(20, 20, 230)),
      ];
      final requests = <Map<String, dynamic>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          requests.length == 1
              ? 'event: error\ndata: {"message":"本地模拟失败"}\n\n'
              : 'event: final\ndata: {"thinking":"两张已收到"}\n\n',
        );
        await request.response.close();
      });
      final c = await boot('http://127.0.0.1:${server.port}');
      var accepted = 0;
      await turn(
        c,
        () => c
            .read(assistantProvider.notifier)
            .send(
              '',
              images: originals,
              onAccepted: () {
                accepted++;
                expect(c.read(assistantProvider).running, isTrue);
                expect(
                  c.read(assistantProvider).msgs.last.imageHashes,
                  hasLength(2),
                );
              },
            ),
      );
      expect(accepted, 1);
      final ask = c.read(assistantProvider).msgs.first;
      expect(ask.text, '');
      expect(ask.imageHashes, hasLength(2));
      expect(requests.single['user_request'], contains('#1 至 #2'));
      final sheet = img.decodeJpg(
        base64Decode(requests.single['image_b64'] as String),
      )!;
      expect(sheet.width, 2096);
      expect(sheet.getPixel(528, 548).r, greaterThan(200));
      expect(sheet.getPixel(1568, 548).b, greaterThan(200));
      expect(requests.single.containsKey('images_b64'), isFalse);
      for (var i = 0; i < originals.length; i++) {
        expect(await stores.assistant.image(ask.imageHashes[i]), originals[i]);
      }
      await turn(
        c,
        () =>
            c.read(assistantProvider.notifier).retryFrom(ask.id, text: '比较这两张'),
      );
      expect(requests.last['image_b64'], requests.first['image_b64']);
      expect(requests.last['user_request'], startsWith('比较这两张'));
      expect(c.read(assistantProvider).msgs.first.imageHashes, ask.imageHashes);
      stores.assistant.flush();
      await stores.assistant.idle;
      await stores.assistant.load();
      expect(
        stores.assistant.initialCurrent.first.imageHashes,
        ask.imageHashes,
      );
      expect(stores.assistant.initialCurrent.last.text, '两张已收到');
      final log = await File(
        '${temp.path}/assistant/traces.json',
      ).readAsString();
      expect(log, isNot(contains(requests.first['image_b64'] as String)));
      for (final original in originals) {
        expect(log, isNot(contains(base64Encode(original))));
      }
    },
  );

  test(
    'a missing later attachment cancels retry without truncating old dialogue',
    () async {
      final first = await stores.assistant.putImage(
        picture(3, 5, img.ColorRgb8(255, 0, 0)),
      );
      final original = [
        AssistantMsg(
          id: 'u',
          role: MsgRole.user,
          text: '原问题',
          at: 1,
          imageHashes: [first!, 'missing-second-image'],
        ),
        const AssistantMsg(id: 'a', role: MsgRole.ai, text: '原回答', at: 2),
      ];
      stores.assistant.initialCurrent = original;
      final c = await boot('http://127.0.0.1:1');
      await c.read(assistantProvider.notifier).retryFrom('u', text: '新问题');
      expect(c.read(assistantProvider).msgs.take(2), original);
      expect(c.read(assistantProvider).msgs.last.text, contains('附件无法读取'));
      expect(c.read(assistantProvider).running, isFalse);
    },
  );

  test(
    'failed sheet preparation never accepts or sends only its first image',
    () async {
      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add(request.uri.path);
        request.response.statusCode = 500;
        await request.response.close();
      });
      final original = const [
        AssistantMsg(id: 'a', role: MsgRole.ai, text: '保留', at: 1),
      ];
      stores.assistant.initialCurrent = original;
      final c = await boot('http://127.0.0.1:${server.port}');
      var accepted = false;
      await HttpOverrides.runWithHttpOverrides(
        () => c
            .read(assistantProvider.notifier)
            .send(
              '全部发出',
              images: [
                picture(3, 5, img.ColorRgb8(255, 0, 0)),
                Uint8List.fromList([1, 2, 3]),
              ],
              onAccepted: () => accepted = true,
            ),
        _LocalHttp(),
      );
      expect(accepted, isFalse);
      expect(requests, isEmpty);
      expect(c.read(assistantProvider).msgs.first, original.first);
      expect(c.read(assistantProvider).msgs.last.role, MsgRole.error);
    },
  );

  test(
    'partial attachment storage failure keeps old dialogue and does not accept',
    () async {
      final images = [
        picture(7, 12, img.ColorRgb8(255, 0, 0)),
        picture(12, 7, img.ColorRgb8(0, 0, 255)),
      ];
      final secondHash = await stores.blobs.hashOf(images.last);
      await Directory(
        '${temp.path}/blobs/$secondHash.bin',
      ).create(recursive: true);
      const original = AssistantMsg(
        id: 'old',
        role: MsgRole.ai,
        text: '原对话',
        at: 1,
      );
      stores.assistant.initialCurrent = const [original];
      final c = await boot('http://127.0.0.1:1');
      var accepted = false;
      await c
          .read(assistantProvider.notifier)
          .send('比较', images: images, onAccepted: () => accepted = true);
      expect(accepted, isFalse);
      expect(c.read(assistantProvider).msgs.first, original);
      expect(
        c.read(assistantProvider).msgs.where((m) => m.role == MsgRole.user),
        isEmpty,
      );
      expect(c.read(assistantProvider).msgs.last.text, contains('附件保存失败'));
      expect(
        await stores.assistant.image(await stores.blobs.hashOf(images.first)),
        images.first,
      );
    },
  );

  test(
    'an over-limit batch is rejected intact before the acceptance callback',
    () async {
      final c = await boot('http://127.0.0.1:1');
      var accepted = false;
      await c
          .read(assistantProvider.notifier)
          .send(
            '',
            images: List.filled(
              kAssistantMaxAttachments + 1,
              Uint8List.fromList([1]),
            ),
            onAccepted: () => accepted = true,
          );
      expect(accepted, isFalse);
      expect(c.read(assistantProvider).msgs.single.role, MsgRole.error);
      expect(
        c.read(assistantProvider).msgs.single.text,
        contains('$kAssistantMaxAttachments'),
      );
      expect(await stores.assistant.liveRefs(), isEmpty);
    },
  );
}
