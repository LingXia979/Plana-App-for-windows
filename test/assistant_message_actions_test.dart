import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/backend_config.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/core/util/image_pick.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_page.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';
import 'package:plana_app/features/generate/generate_state.dart';

class _FixtureAssistant extends AssistantNotifier {
  final retries = <(String, String?)>[];
  final sentImages = <Uint8List?>[];
  void seed(AssistantState value) => state = value;

  @override
  Future<void> retryFrom(String userMsgId, {String? text}) async {
    retries.add((userMsgId, text));
  }

  @override
  Future<void> send(
    String text, {
    Uint8List? image,
    List<Uint8List> images = const [],
    bool withCanvas = false,
    void Function()? onAccepted,
  }) async {
    sentImages.add(image ?? images.firstOrNull);
    onAccepted?.call();
  }
}

class _TestSession extends BotSessionNotifier {
  _TestSession(this.authorized);
  final bool authorized;
  @override
  Future<BotSession?> build() async =>
      authorized ? const BotSession(sessionId: 'local-test') : null;
}

class _TestSettings extends AssistantSettingsNotifier {
  @override
  Future<AssistantSettings> build() async => const AssistantSettings(
    introVersion: kAssistantIntroVersion,
    libraryScope: LibraryScope.none,
  );
}

class _TestRules extends RulesLibraryNotifier {
  @override
  Future<RulesLibrary> build() async => const RulesLibrary();
}

class _RealHttp extends HttpOverrides {}

const _messages = [
  AssistantMsg(id: 'u1', role: MsgRole.user, text: '第一条提问', at: 1),
  AssistantMsg(id: 'a1', role: MsgRole.ai, text: '第一条回复\n完整的第二行', at: 2),
  AssistantMsg(id: 'u2', role: MsgRole.user, text: '后续提问', at: 3),
  AssistantMsg(id: 'a2', role: MsgRole.ai, text: '后续回复', at: 4),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer c;

  setUp(() {
    stores = AppStores.ephemeral();
    stores.assistant.initialCurrent = _messages;
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        assistantBotAuthorizedProvider.overrideWithValue(true),
        assistantProvider.overrideWith(_FixtureAssistant.new),
        assistantSettingsProvider.overrideWith(_TestSettings.new),
        rulesLibraryProvider.overrideWith(_TestRules.new),
        agentModelsProvider.overrideWith((ref) async => const AgentModelList()),
      ],
    );
  });

  tearDown(() async {
    c.dispose();
    stores.flushNow();
    await stores.assistant.idle;
  });

  Future<void> mount(WidgetTester tester, {bool desktop = true}) async {
    tester.view.physicalSize = const Size(880, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (!desktop) {
      c.dispose();
      c = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          desktopModeProvider.overrideWithValue(false),
          assistantBotAuthorizedProvider.overrideWithValue(true),
          assistantProvider.overrideWith(_FixtureAssistant.new),
          assistantSettingsProvider.overrideWith(_TestSettings.new),
          rulesLibraryProvider.overrideWith(_TestRules.new),
          agentModelsProvider.overrideWith(
            (ref) async => const AgentModelList(),
          ),
        ],
      );
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: AssistantPage(embedded: true)),
        ),
      ),
    );
    if (c.read(assistantProvider).running) {
      await tester.pump(const Duration(milliseconds: 400));
    } else {
      await tester.pumpAndSettle();
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Finder menu(String id) => find.byKey(ValueKey('assistant-message-menu-$id'));
  Finder editor() => find.byKey(const ValueKey('assistant-message-editor'));

  testWidgets(
    'desktop right click copies the complete reply and its proposal',
    (tester) async {
      const reply = AssistantMsg(
        id: 'a2',
        role: MsgRole.ai,
        text: '完整回复\n第二行',
        at: 4,
        noDraw: true,
        draw: DrawProposal(positive: 'white hair', negative: 'blurry'),
      );
      (c.read(assistantProvider.notifier) as _FixtureAssistant).seed(
        AssistantState(msgs: [_messages[0], reply]),
      );
      String? clipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await mount(tester);
      await tester.tap(
        find.byKey(const ValueKey('assistant-message-a2')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.text('复制内容'));
      await tester.pumpAndSettle();
      expect(clipboard, replayText(reply));
      expect(find.text('编辑该信息'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets('cancel editing keeps the conversation and unsent draft intact', (
    tester,
  ) async {
    await mount(tester);
    final input = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '想画什么、想改哪里…',
    );
    await tester.enterText(input, '尚未发送的草稿');
    await tester.tap(menu('u1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑该信息'));
    await tester.pumpAndSettle();
    await tester.enterText(editor(), '取消掉的编辑');
    expect(c.read(assistantProvider).msgs, _messages);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(c.read(assistantProvider).msgs, _messages);
    expect(tester.widget<TextField>(input).controller!.text, '尚未发送的草稿');
    expect(
      (c.read(assistantProvider.notifier) as _FixtureAssistant).retries,
      isEmpty,
    );
    await finish(tester);
  });

  testWidgets('confirmed user edit regenerates from that question', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(menu('u1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑该信息'));
    await tester.pumpAndSettle();
    expect(find.textContaining('替换之后的对话'), findsOneWidget);
    await tester.enterText(editor(), '确认后的新提问');
    await tester.tap(find.text('保存并重新回答'));
    await tester.pumpAndSettle();
    expect((c.read(assistantProvider.notifier) as _FixtureAssistant).retries, [
      ('u1', '确认后的新提问'),
    ]);
    await finish(tester);
  });

  testWidgets(
    'AI editing persists only the changed reply and retains later turns',
    (tester) async {
      await mount(tester);
      await tester.tap(menu('a1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑该信息'));
      await tester.pumpAndSettle();
      await tester.enterText(editor(), '已修正的回复');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(c.read(assistantProvider).msgs.map((m) => m.text), [
        '第一条提问',
        '已修正的回复',
        '后续提问',
        '后续回复',
      ]);
      await tester.runAsync(() async {
        stores.assistant.flush();
        await stores.assistant.idle;
        await stores.assistant.load();
      });
      expect(stores.assistant.initialCurrent[1].text, '已修正的回复');
      expect(stores.assistant.initialCurrent.last.id, 'a2');
      await finish(tester);
    },
  );

  testWidgets(
    'running replies allow copying but disable edits and regeneration',
    (tester) async {
      (c.read(assistantProvider.notifier) as _FixtureAssistant).seed(
        const AssistantState(msgs: _messages, running: true),
      );
      await mount(tester);
      await tester.tap(menu('a2'));
      await tester.pump(const Duration(milliseconds: 400));
      final choices = tester
          .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
          .toList();
      expect(choices.singleWhere((m) => m.value == 'copy').enabled, isTrue);
      expect(choices.singleWhere((m) => m.value == 'edit').enabled, isFalse);
      expect(choices.singleWhere((m) => m.value == 'retry').enabled, isFalse);
      expect(
        c.read(assistantProvider.notifier).editReply('a1', '不应保存'),
        isFalse,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      (c.read(assistantProvider.notifier) as _FixtureAssistant).seed(
        const AssistantState(msgs: _messages),
      );
      await finish(tester);
    },
  );

  testWidgets('older reply regeneration asks before replacing later turns', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(menu('a1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从这里重新生成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      (c.read(assistantProvider.notifier) as _FixtureAssistant).retries,
      isEmpty,
    );
    await tester.tap(menu('a1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从这里重新生成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('丢掉'));
    await tester.pumpAndSettle();
    expect((c.read(assistantProvider.notifier) as _FixtureAssistant).retries, [
      ('u1', null),
    ]);
    await finish(tester);
  });

  testWidgets('mobile keeps its long press sheet', (tester) async {
    await mount(tester, desktop: false);
    expect(find.byTooltip('消息操作'), findsNothing);
    await tester.longPress(find.text('后续提问'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('复制内容'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets(
    'composer drops stay pending until send and are disabled while running',
    (tester) async {
      await mount(tester);
      final notifier = c.read(assistantProvider.notifier) as _FixtureAssistant;
      final png = Uint8List.fromList(
        img.encodePng(img.Image(width: 4, height: 4)),
      );
      final drop = find.byKey(const ValueKey('assistant-image-drop'));
      final receiver = tester.widget<ImageDropRegion>(drop);
      expect(receiver.enabled, isTrue);
      expect(receiver.multiple, isTrue);
      await receiver.onDrop([
        PickedImage('canvas.png', png),
      ], ImageDropPayload.image(name: 'canvas.png', load: () async => png));
      await tester.pump();
      expect(notifier.sentImages, isEmpty);
      await tester.tap(find.byTooltip('发送 (Enter) · Shift + Enter 换行'));
      await tester.pump();
      expect(notifier.sentImages.single, png);
      notifier.seed(const AssistantState(msgs: _messages, running: true));
      await tester.pump();
      expect(tester.widget<ImageDropRegion>(drop).enabled, isFalse);
      notifier.seed(const AssistantState(msgs: _messages));
      await finish(tester);
    },
  );

  Future<void> bootState({bool authorized = true, String? base}) async {
    c.dispose();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        botSessionProvider.overrideWith(() => _TestSession(authorized)),
        assistantEndpointProvider.overrideWithValue(null),
        assistantSettingsProvider.overrideWith(_TestSettings.new),
        rulesLibraryProvider.overrideWith(_TestRules.new),
      ],
    );
    await c.read(assistantSettingsProvider.future);
    if (base != null) await c.read(backendBaseProvider.notifier).save(base);
  }

  test(
    'missing authorization or missing attachment never truncates old messages',
    () async {
      await bootState(authorized: false);
      await c.read(assistantProvider.notifier).retryFrom('u1', text: '新的问题');
      expect(c.read(assistantProvider).msgs.take(4), _messages);
      expect(c.read(assistantProvider).msgs.last.role, MsgRole.error);
      c.dispose();
      stores.assistant.initialCurrent = [
        const AssistantMsg(
          id: 'missing',
          role: MsgRole.user,
          text: '图片问题',
          at: 1,
          imageHash: 'missing-attachment',
        ),
        _messages[1],
      ];
      c = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      await c.read(assistantProvider.notifier).retryFrom('missing');
      expect(
        c.read(assistantProvider).msgs.take(2),
        stores.assistant.initialCurrent,
      );
      expect(c.read(assistantProvider).msgs.last.text, contains('附件无法读取'));
    },
  );

  test(
    'retry uses only earlier context, keeps attachments, recovers from failure and persists',
    () async {
      final image = Uint8List.fromList([1, 2, 3, 4]);
      final hash = await stores.assistant.putImage(image);
      const resources = {
        'artists': {'A1': 'soft light'},
      };
      stores.assistant.initialCurrent = [
        _messages[0],
        const AssistantMsg(
          id: 'a1',
          role: MsgRole.ai,
          text: '先前回复',
          at: 2,
          resources: resources,
        ),
        AssistantMsg(
          id: 'u2',
          role: MsgRole.user,
          text: '原提问',
          at: 3,
          imageHash: hash,
          withCanvas: true,
        ),
        _messages[3],
        const AssistantMsg(
          id: 'u3',
          role: MsgRole.user,
          text: '不应发出的后续提问',
          at: 5,
        ),
        const AssistantMsg(
          id: 'a3',
          role: MsgRole.ai,
          text: '不应发出的后续回答',
          at: 6,
        ),
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
              : 'event: final\ndata: {"thinking":"重新回答成功"}\n\n',
        );
        await request.response.close();
      });
      await bootState(base: 'http://127.0.0.1:${server.port}');
      c.read(generateProvider.notifier).setPrompts(positive: '当前画布');
      Future<void> waitTurn(Future<void> Function() start) async {
        final finished = Completer<void>();
        final subscription = c.listen(assistantProvider, (previous, next) {
          if (previous?.running == true &&
              !next.running &&
              !finished.isCompleted) {
            finished.complete();
          }
        });
        try {
          await HttpOverrides.runWithHttpOverrides(start, _RealHttp());
          await finished.future.timeout(const Duration(seconds: 10));
        } finally {
          subscription.close();
        }
      }

      await waitTurn(
        () => c.read(assistantProvider.notifier).retryFrom('u2', text: '改后的提问'),
      );
      expect(requests.single['history'], [
        {'role': 'user', 'content': '第一条提问'},
        {'role': 'assistant', 'content': '先前回复'},
      ]);
      expect(requests.single['user_request'], '改后的提问');
      expect(requests.single['image_b64'], base64Encode(image));
      expect(requests.single['current_positive'], '当前画布');
      expect(requests.single['resources'], resources);
      expect(c.read(assistantProvider).msgs.map((m) => m.text), [
        '第一条提问',
        '先前回复',
        '改后的提问',
        '本地模拟失败',
      ]);
      await waitTurn(() => c.read(assistantProvider.notifier).retryLast());
      expect(requests.last['history'], requests.first['history']);
      expect(requests.last['image_b64'], base64Encode(image));
      stores.assistant.flush();
      await stores.assistant.idle;
      await stores.assistant.load();
      expect(stores.assistant.initialCurrent.last.text, '重新回答成功');
      expect(stores.assistant.initialCurrent[2].imageHash, hash);
      expect(
        stores.assistant.initialCurrent.map((m) => m.id),
        isNot(contains('u3')),
      );
    },
  );
}
