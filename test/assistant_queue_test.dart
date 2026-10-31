import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/backend_config.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';

class _Session extends BotSessionNotifier {
  final ready = Completer<BotSession?>();
  @override
  Future<BotSession?> build() => ready.future;
}

class _Settings extends AssistantSettingsNotifier {
  @override
  Future<AssistantSettings> build() async => const AssistantSettings(
    libraryScope: LibraryScope.none,
    autoImport: true,
    introVersion: kAssistantIntroVersion,
  );
}

class _Rules extends RulesLibraryNotifier {
  @override
  Future<RulesLibrary> build() async => const RulesLibrary();
}

class _Backend extends BackendBaseNotifier {
  _Backend(this.base);
  final String base;
  @override
  Future<String> build() async => base;
}

class _Http extends HttpOverrides {}

class _Turn {
  _Turn(this.request, this.body);
  final HttpRequest request;
  final Map<String, dynamic> body;
  Future<void> finish({bool fail = false, String positive = ''}) async {
    if (request.uri.path == '/reply') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'direct answer'},
            },
          ],
        }),
      );
      await request.response.close();
      return;
    }
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    request.response.write(
      fail
          ? 'event: error\ndata: {"message":"本地模拟失败"}\n\n'
          : 'event: final\ndata: ${jsonEncode({'thinking': '完成', if (positive.isNotEmpty) 'positive': positive})}\n\n',
    );
    try {
      await request.response.close();
    } catch (_) {
      /* Cancelled client. */
    }
  }
}

Future<void> until(bool Function() condition) async {
  final limit = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(limit)) {
      fail('Timed out waiting for local assistant state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer c;
  late AssistantNotifier n;
  late HttpServer server;
  late _Session session;
  late HttpOverrides? originalHttp;
  CustomEndpoint? custom;
  final turns = <_Turn>[];

  setUp(() async {
    originalHttp = HttpOverrides.current;
    HttpOverrides.global = _Http();
    turns.clear();
    custom = null;
    stores = AppStores.ephemeral();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path != '/api/agent/prompt/stream' &&
          request.uri.path != '/reply') {
        // Auxiliary tools/rules endpoints return empty local fixtures.
        if (request.method == 'GET') {
          request.response.headers.contentType = ContentType.json;
          request.response.write('{}');
          await request.response.close();
          return;
        }
      }
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      turns.add(_Turn(request, body));
    });
    session = _Session();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        botSessionProvider.overrideWith(() => session),
        backendBaseProvider.overrideWith(
          () => _Backend('http://127.0.0.1:${server.port}'),
        ),
        assistantEndpointProvider.overrideWith((_) => custom),
        assistantSettingsProvider.overrideWith(_Settings.new),
        rulesLibraryProvider.overrideWith(_Rules.new),
      ],
    );
    await c.read(backendBaseProvider.future);
    await c.read(assistantSettingsProvider.future);
    n = c.read(assistantProvider.notifier);
  });

  tearDown(() async {
    n.stop();
    c.dispose();
    await server.close(force: true);
    await stores.flushForExit();
    await stores.desktopOutput.root.parent.delete(recursive: true);
    HttpOverrides.global = originalHttp;
  });

  Future<void> start() async {
    session.ready.complete(const BotSession(sessionId: 'local-only'));
    await n.submit('first');
    await until(() => turns.length == 1);
  }

  test(
    'FIFO accepts once; queued ID becomes user ID; no second request until done',
    () async {
      await start();
      var accepted = 0;
      await n.submit('second', onAccepted: () => accepted++);
      await n.submit('third', onAccepted: () => accepted++);
      final ids = c.read(assistantProvider).queue.map((q) => q.id).toList();
      expect(accepted, 2);
      expect(turns, hasLength(1));
      await turns.first.finish();
      await until(() => turns.length == 2);
      expect(turns[1].body['user_request'], 'second');
      expect(c.read(assistantProvider).msgs.last.id, ids[0]);
      await turns[1].finish();
      await until(() => turns.length == 3);
      expect(turns[2].body['user_request'], 'third');
      expect(c.read(assistantProvider).msgs.last.id, ids[1]);
      await turns[2].finish();
      await until(() => !c.read(assistantProvider).running);
      expect(c.read(assistantProvider).queue, isEmpty);
      expect(c.read(assistantProvider).msgs.map((m) => m.role), [
        MsgRole.user,
        MsgRole.ai,
        MsgRole.user,
        MsgRole.ai,
        MsgRole.user,
        MsgRole.ai,
      ]);
    },
  );

  test(
    'custom route queues all images and exports no request header credentials',
    () async {
      custom = CustomEndpoint(
        id: 'local',
        name: 'test',
        format: AgentApiFormat.openai,
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiPath: '/reply',
        apiKey: 'only-test-key',
        model: 'test-model',
        headers: {'X-Private': 'only-test-header'},
      );
      c.invalidate(assistantEndpointProvider);
      await start();
      final images = [
        for (var i = 0; i < 2; i++)
          Uint8List.fromList(img.encodePng(img.Image(width: i + 3, height: 4))),
      ];
      await n.submit('multiple direct', images: images);
      await turns.first.finish();
      await until(() => turns.length == 2);
      final messages = turns[1].body['messages'] as List;
      final parts = (messages.last as Map)['content'] as List;
      expect(parts.where((p) => p['type'] == 'image_url'), hasLength(2));
      expect(turns[1].request.headers.value('X-Private'), 'only-test-header');
      await turns[1].finish();
      await until(() => !c.read(assistantProvider).running);
      await stores.assistant.idle;
      final log = n.exportTrace();
      expect(log, isNot(contains('only-test-key')));
      expect(log, isNot(contains('only-test-header')));
      for (final bytes in images) {
        expect(log, isNot(contains(base64Encode(bytes))));
      }
      final traceFile = File(
        '${stores.desktopOutput.root.parent.path}/assistant/traces.json',
      );
      final saved = await traceFile.readAsString();
      expect(saved, isNot(contains('only-test-header')));
    },
  );

  test(
    'attachment storage failure keeps queued bytes and resumes after repair',
    () async {
      await start();
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 3, height: 4)),
      );
      final hash = await stores.blobs.hashOf(bytes);
      final blocker = Directory(
        '${stores.desktopOutput.root.parent.path}/blobs/$hash.bin',
      );
      await blocker.create(recursive: true);
      await n.submit('retry attachment', images: [bytes]);
      final id = c.read(assistantProvider).queue.single.id;
      await turns.first.finish();
      await until(
        () => c.read(assistantProvider).msgs.last.role == MsgRole.error,
      );
      expect(c.read(assistantProvider).queue.single.id, id);
      expect(c.read(assistantProvider).queue.single.images.single, bytes);
      expect(turns, hasLength(1));
      await blocker.delete();
      await n.resumeQueue();
      await until(() => turns.length == 2);
      expect(c.read(assistantProvider).msgs.last.id, id);
      expect(await stores.assistant.image(hash), bytes);
      await turns[1].finish();
      await until(() => !c.read(assistantProvider).running);
    },
  );

  for (final fail in [false, true]) {
    test(
      'stop/error pauses remaining queue; resume exactly once, error=$fail',
      () async {
        await start();
        await n.submit('waiting');
        final id = c.read(assistantProvider).queue.single.id;
        if (fail) {
          await turns.first.finish(fail: true);
          await until(() => !c.read(assistantProvider).running);
        } else {
          n.stop();
          await turns.first.finish(positive: 'stale');
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(turns, hasLength(1));
        expect(c.read(assistantProvider).queue.single.id, id);
        await Future.wait([n.resumeQueue(), n.resumeQueue()]);
        await until(() => turns.length == 2);
        expect(c.read(assistantProvider).msgs.last.id, id);
        await turns[1].finish();
        await until(() => !c.read(assistantProvider).running);
        expect(c.read(assistantProvider).queue, isEmpty);
        expect(c.read(generateProvider).prompt, isNot('stale'));
      },
    );
  }

  for (final deleted in [false, true]) {
    test(
      'queued images and canvas snapshot survive edits and switching, deleted=$deleted',
      () async {
        await start();
        final canvases = c.read(canvasWorkspaceProvider.notifier);
        final a = canvases.create();
        c.read(generateProvider.notifier).setPrompts(positive: 'snapshot A');
        final images = [
          for (var i = 1; i <= 2; i++)
            Uint8List.fromList(
              img.encodePng(img.Image(width: i + 2, height: 3)),
            ),
        ];
        final originals = images.map((x) => Uint8List.fromList(x)).toList();
        await n.submit('compare', images: images, withCanvas: true);
        final q = c.read(assistantProvider).queue.single;
        images.first.fillRange(0, images.first.length, 0);
        expect(q.images.first, originals.first);
        expect(() => q.images.first[0] = 1, throwsUnsupportedError);
        expect(() => q.images.add(originals.first), throwsUnsupportedError);
        final b = canvases.create();
        c.read(generateProvider.notifier).setPrompts(positive: 'untouched B');
        if (deleted) canvases.remove(a);
        await turns.first.finish();
        await until(() => turns.length == 2);
        expect(turns[1].body['current_positive'], contains('snapshot A'));
        expect(turns[1].body['user_request'], contains('#1 至 #2'));
        final msg = c.read(assistantProvider).msgs.last;
        expect(msg.imageHashes, hasLength(2));
        for (var i = 0; i < 2; i++) {
          expect(
            await stores.assistant.image(msg.imageHashes[i]),
            originals[i],
          );
        }
        await turns[1].finish(positive: 'result for A');
        await until(() => !c.read(assistantProvider).running);
        expect(c.read(canvasWorkspaceProvider).activeId, b);
        expect(c.read(generateProvider).prompt, 'untouched B');
        if (deleted) {
          expect(c.read(canvasWorkspaceProvider).find(a), isNull);
        } else {
          expect(
            c.read(canvasWorkspaceProvider).find(a)!.prompts.prompt,
            'result for A',
          );
        }
      },
    );
  }

  test(
    'cancel during authorization invalidates old attempt and permits resume',
    () async {
      final preparing = n.send('cancel first');
      await n.submit('keep second');
      n.stop();
      session.ready.complete(const BotSession(sessionId: 'local-only'));
      await preparing;
      expect(turns, isEmpty);
      expect(c.read(assistantProvider).msgs, isEmpty);
      await n.resumeQueue();
      await until(() => turns.isNotEmpty);
      expect(turns.single.body['user_request'], 'keep second');
      await turns.single.finish();
      await until(() => !c.read(assistantProvider).running);
    },
  );

  test(
    'cancel preparing queue head cannot resurrect it after authorization',
    () async {
      final preparing = n.send('cancel first');
      await n.submit('cancel queued');
      final id = c.read(assistantProvider).queue.single.id;
      n.stop();
      final draining = n.resumeQueue();
      n.unqueue(id);
      session.ready.complete(const BotSession(sessionId: 'local-only'));
      await Future.wait([preparing, draining]);
      expect(turns, isEmpty);
      expect(c.read(assistantProvider).queue, isEmpty);
      expect(c.read(assistantProvider).msgs, isEmpty);
    },
  );

  test(
    'new session while preparing discards old queue and old async callbacks',
    () async {
      final preparing = n.send('old');
      await n.submit('old queued');
      n.archiveCurrent();
      session.ready.complete(const BotSession(sessionId: 'local-only'));
      await preparing;
      expect(c.read(assistantProvider).queue, isEmpty);
      expect(c.read(assistantProvider).msgs, isEmpty);
      expect(turns, isEmpty);
      await n.send('new');
      await until(() => turns.isNotEmpty);
      expect(turns.single.body['user_request'], 'new');
      await turns.single.finish();
      await until(() => !c.read(assistantProvider).running);
    },
  );

  test(
    'opening history cancels running request and never migrates queued messages',
    () async {
      await start();
      await turns.first.finish();
      await until(() => !c.read(assistantProvider).running);
      n.archiveCurrent();
      final id = c.read(assistantProvider).sessions.single.id;
      await n.send('second session');
      await until(() => turns.length == 2);
      await n.submit('never migrate');
      n.openSession(id);
      await turns[1].finish(positive: 'stale');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(c.read(assistantProvider).queue, isEmpty);
      expect(c.read(assistantProvider).msgs.first.text, 'first');
      expect(c.read(assistantProvider).msgs, hasLength(2));
      expect(c.read(assistantProvider).running, isFalse);
    },
  );

  test(
    'invalid enqueue leaves running turn, queue and acceptance untouched',
    () async {
      await start();
      var accepted = false;
      await expectLater(
        n.submit(
          'bad',
          images: [Uint8List(0)],
          onAccepted: () => accepted = true,
        ),
        throwsStateError,
      );
      expect(accepted, isFalse);
      expect(c.read(assistantProvider).queue, isEmpty);
      expect(c.read(assistantProvider).running, isTrue);
      await turns.first.finish();
      await until(() => !c.read(assistantProvider).running);
    },
  );
}
