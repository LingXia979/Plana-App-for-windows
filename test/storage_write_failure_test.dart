import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/assistant/agent_trace.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/generate/canvas_models.dart';
import 'package:plana_app/features/generate/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('plana_write_failure_');
    addTearDown(() => root.deleteSync(recursive: true));
  });

  test(
    'workspace write failure blocks exit and latest draft can be retried',
    () async {
      final stores = await AppStores.open(rootOverride: root);
      final blocker = File('${root.path}/workspace')
        ..writeAsStringSync('block');
      stores.workspace.schedule(
        GenerateState.initial().copyWith(prompt: 'unsaved draft'),
        idSeq: 101,
      );

      await expectLater(
        stores.flushForExit(),
        throwsA(isA<FileSystemException>()),
      );
      expect(stores.saveError.value, contains('工作台保存失败'));
      blocker.deleteSync();
      await stores.flushForExit();

      final reopened = await AppStores.open(rootOverride: root);
      expect(reopened.workspace.initial?.prompt, 'unsaved draft');
    },
  );

  test(
    'assistant messages and traces survive failed writes for retry',
    () async {
      final stores = await AppStores.open(rootOverride: root);
      final blocker = File('${root.path}/assistant')
        ..writeAsStringSync('block');
      final trace = AgentTrace(
        startedAt: 1,
        route: AgentTrace.routeBackend,
        userText: 'hello',
      );
      await expectLater(
        stores.assistant.saveTraces([trace]),
        throwsA(isA<FileSystemException>()),
      );
      stores.assistant.schedule([
        const AssistantMsg(id: 'm1', role: MsgRole.user, text: 'hello', at: 1),
      ], const []);
      await expectLater(
        stores.flushForExit(),
        throwsA(isA<FileSystemException>()),
      );
      expect(stores.saveError.value, contains('助手会话保存失败'));

      blocker.deleteSync();
      await stores.flushForExit();
      final reopened = await AppStores.open(rootOverride: root);
      expect(reopened.assistant.initialCurrent.single.text, 'hello');
      expect(reopened.assistant.initialTraces.single.userText, 'hello');
    },
  );

  test(
    'an older failed write cannot replace newer multi-canvas drafts',
    () async {
      final stores = await AppStores.open(rootOverride: root);
      final blocker = Directory('${root.path}/workspace/state.json.tmp')
        ..createSync(recursive: true);
      stores.workspace.schedule(
        GenerateState.initial().copyWith(prompt: 'obsolete'),
        idSeq: 101,
      );
      stores.workspace.flush();
      final medium = GenerateState.initial().copyWith(
        prompt: 'first canvas',
        promptRaw: 'first uncommitted draft',
        negativePrompt: 'rain',
        negativePromptRaw: 'rain, unfinished',
        params: GenerateState.initial().params.copyWith(
          model: 'NAI 5.0 Full',
          naiEffort: NaiEffort.medium,
          steps: 37,
        ),
      );
      final high = medium.copyWith(
        prompt: 'second canvas',
        promptRaw: 'second uncommitted draft',
        params: medium.params.copyWith(naiEffort: NaiEffort.high, steps: 45),
      );
      stores.workspace.schedule(
        high,
        canvases: CanvasWorkspace(
          canvases: [
            CanvasDraft(
              id: 'canvas1',
              name: kDefaultCanvasName,
              prompts: CanvasPrompts.of(medium),
            ),
            CanvasDraft(
              id: 'canvas2',
              name: 'Second',
              prompts: CanvasPrompts.of(high),
            ),
          ],
          activeId: 'canvas2',
          nextId: 3,
        ),
        idSeq: 202,
      );
      await expectLater(
        stores.workspace.idle,
        throwsA(isA<FileSystemException>()),
      );
      // Repeated failures must keep the new snapshot, including inactive canvases.
      await expectLater(
        stores.flushForExit(),
        throwsA(isA<FileSystemException>()),
      );
      blocker.deleteSync();
      await stores.flushForExit();
      final reopened = await AppStores.open(rootOverride: root);
      final canvases = reopened.workspace.initialCanvases!;
      expect(canvases.activeId, 'canvas2');
      expect(canvases.nextId, 3);
      expect(reopened.workspace.idSeq, 202);
      expect(canvases.canvases.map((c) => c.prompts.prompt), [
        'first canvas',
        'second canvas',
      ]);
      expect(canvases.canvases.map((c) => c.prompts.promptRaw), [
        'first uncommitted draft',
        'second uncommitted draft',
      ]);
      expect(
        canvases.canvases.first.prompts.negativePromptRaw,
        'rain, unfinished',
      );
      expect(
        canvases.canvases.first.prompts.sampling!.naiEffort,
        NaiEffort.medium,
      );
      expect(canvases.active.prompts.sampling!.naiEffort, NaiEffort.high);
      expect(canvases.canvases.first.prompts.sampling!.steps, 37);
      expect(canvases.active.prompts.sampling!.steps, 45);
    },
  );

  test('assistant retries the latest messages, archives and traces', () async {
    final stores = await AppStores.open(rootOverride: root);
    final blocker = File('${root.path}/assistant')..writeAsStringSync('block');
    const old = AssistantMsg(
      id: 'old',
      role: MsgRole.user,
      text: 'obsolete',
      at: 1,
    );
    const latest = AssistantMsg(
      id: 'new',
      role: MsgRole.user,
      text: 'latest',
      at: 2,
    );
    stores.assistant.schedule([old], const []);
    stores.assistant.flush();
    stores.assistant.schedule(
      [latest],
      const [
        ArchivedSession(id: 1, msgs: [old], at: 1),
      ],
    );
    await expectLater(
      stores.assistant.idle,
      throwsA(isA<FileSystemException>()),
    );
    AgentTrace trace(String text) => AgentTrace(
      startedAt: 1,
      route: AgentTrace.routeBackend,
      userText: text,
    );
    final oldTrace = stores.assistant.saveTraces([trace('obsolete')]);
    final newTrace = stores.assistant.saveTraces([trace('latest')]);
    await Future.wait([
      expectLater(oldTrace, throwsA(isA<FileSystemException>())),
      expectLater(newTrace, throwsA(isA<FileSystemException>())),
    ]);
    blocker.deleteSync();
    await stores.flushForExit();
    final reopened = await AppStores.open(rootOverride: root);
    expect(reopened.assistant.initialCurrent.single.text, 'latest');
    expect(
      reopened.assistant.initialSessions.single.msgs.single.text,
      'obsolete',
    );
    expect(reopened.assistant.initialTraces.single.userText, 'latest');
  });

  test(
    'failed trace writes do not stop session writes or hide the error',
    () async {
      final stores = await AppStores.open(rootOverride: root);
      final blocker = Directory('${root.path}/assistant/traces.json.tmp')
        ..createSync(recursive: true);
      await expectLater(
        stores.assistant.saveTraces([
          AgentTrace(
            startedAt: 1,
            route: AgentTrace.routeBackend,
            userText: 'trace',
          ),
        ]),
        throwsA(isA<FileSystemException>()),
      );
      stores.assistant.schedule(const [
        AssistantMsg(
          id: 'm1',
          role: MsgRole.user,
          text: 'saved session',
          at: 1,
        ),
      ], const []);
      await expectLater(
        stores.flushForExit(),
        throwsA(isA<FileSystemException>()),
      );
      final saved = await AppStores.open(rootOverride: root);
      expect(saved.assistant.initialCurrent.single.text, 'saved session');
      expect(saved.assistant.initialTraces, isEmpty);
      blocker.deleteSync();
      await stores.flushForExit();
      final retried = await AppStores.open(rootOverride: root);
      expect(retried.assistant.initialTraces.single.userText, 'trace');
    },
  );
}
