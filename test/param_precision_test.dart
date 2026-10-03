import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/nai_request.dart';
import 'package:plana_app/features/generate/state_codec.dart';
import 'package:plana_app/features/generate/widgets/common.dart';

void main() {
  test(
    'workspace serialization preserves long decimal generation and reference parameters',
    () async {
      final stores = AppStores.ephemeral();
      const precision = .712345678901234;
      final source = GenerateState.initial().copyWith(
        params: const GenParams(
          cfg: 5.1121111234567,
          cfgRescale: precision,
          animaCfg: 3.123456789,
          kreaCfg: 4.123456789,
        ),
        vibes: const [
          VibeItem(
            id: 'vibe',
            strength: precision,
            infoExtracted: precision,
            encodedByModel: {'v4-5full': 'test'},
          ),
        ],
        charRefs: [
          CharRefItem(
            id: 'char',
            image: Uint8List.fromList([1, 2, 3]),
            strength: precision,
            infoExtracted: precision,
          ),
        ],
        img2img: Img2ImgConfig(
          image: Uint8List.fromList([1, 2, 3]),
          strength: precision,
          noise: precision,
        ),
      );
      final stored = await encodeGenerateState(source, stores.blobs);
      final restored = await decodeGenerateState(
        jsonDecode(jsonEncode(stored.json)) as Map<String, dynamic>,
        stores.blobs,
      );
      expect(restored.params.cfg, source.params.cfg);
      expect(restored.params.cfgRescale, precision);
      expect(restored.params.animaCfg, source.params.animaCfg);
      expect(restored.params.kreaCfg, source.params.kreaCfg);
      expect(restored.vibes.single.strength, precision);
      expect(restored.vibes.single.infoExtracted, precision);
      expect(restored.charRefs.single.strength, precision);
      expect(restored.charRefs.single.infoExtracted, precision);
      expect(restored.img2img!.strength, precision);
      expect(restored.img2img!.noise, precision);
      stores.flushNow();
    },
  );
  testWidgets(
    'long decimal edits stay exact through commit, refocus, blur and cancellation',
    (tester) async {
      var value = .612345678901234;
      var commits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  InlineParamInput(
                    label: '强度',
                    value: value,
                    min: 0,
                    max: 1,
                    divisions: 100,
                    onCommit: (v) => setState(() {
                      value = v;
                      commits++;
                    }),
                  ),
                  const TextField(key: ValueKey('outside')),
                ],
              ),
            ),
          ),
        ),
      );
      final input = find.byKey(const ValueKey('inline-param-强度'));
      String text() => tester.widget<TextField>(input).controller!.text;
      expect(text(), '0.61');
      await tester.tap(input);
      await tester.pump();
      expect(text(), '0.612345678901234');
      await tester.tap(find.byKey(const ValueKey('outside')));
      await tester.pump();
      expect(value, .612345678901234);
      expect(
        commits,
        0,
        reason: 'Looking at a rounded readout must never rewrite precision',
      );
      await tester.enterText(input, '0.71211112345678');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(value, .71211112345678);
      expect(commits, 1);
      expect(text(), '0.71');
      await tester.tap(input);
      await tester.pump();
      expect(text(), '0.71211112345678');
      await tester.enterText(input, '0.456789');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(value, .71211112345678);
      expect(commits, 1);
      for (final invalid in ['NaN', 'Infinity', '1.1', '-0.1']) {
        await tester.enterText(input, invalid);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(value, .71211112345678);
        expect(find.byTooltip('请输入 0 ～ 1'), findsOneWidget);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    },
  );

  testWidgets(
    'ordinary and live sliders preserve typed decimals while steps remain integral',
    (tester) async {
      var cfg = 5.5;
      var reference = .6;
      var steps = 18.0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [desktopModeProvider.overrideWithValue(true)],
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Column(
                  children: [
                    ParamSlider(
                      label: 'CFG',
                      value: cfg,
                      min: 0,
                      max: 25,
                      divisions: 250,
                      valueText: cfg.toStringAsFixed(1),
                      onChanged: (v) => setState(() => cfg = v),
                    ),
                    LiveParamSlider(
                      label: '参考',
                      value: reference,
                      divisions: 100,
                      onCommit: (v) => setState(() => reference = v),
                    ),
                    ParamSlider(
                      label: '步数',
                      value: steps,
                      min: 1,
                      max: 50,
                      divisions: 49,
                      snapInputToDivisions: true,
                      onChanged: (v) => setState(() => steps = v),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> enter(String label, String value) async {
        final input = find.byKey(ValueKey('inline-param-$label'));
        await tester.enterText(input, value);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
      }

      await enter('CFG', '5.1121111234567');
      await enter('参考', '0.71345678901234');
      await enter('步数', '18.8');
      expect(cfg, 5.1121111234567);
      expect(reference, .71345678901234);
      expect(steps, 19);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('inline-param-CFG')))
            .controller!
            .text,
        '5.1',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('inline-param-参考')))
            .controller!
            .text,
        '0.71',
      );

      final payload = buildNaiPayload(
        GenerateState.initial().copyWith(
          params: GenParams(
            cfg: cfg,
            cfgRescale: reference,
            normalizeVibe: false,
          ),
        ),
        presetId: 'heavy',
        vibes: [(encoded: 'test', strength: reference)],
        img2img: (
          image: 'test',
          strength: reference,
          noise: reference,
          upscaledEnhance: false,
        ),
        charRefs: [
          (
            image: 'test',
            mode: 'character&style',
            strength: reference,
            fidelity: reference,
          ),
        ],
      );
      final params =
          (jsonDecode(jsonEncode(payload.body)) as Map)['parameters'] as Map;
      expect(params['scale'], cfg);
      expect(params['cfg_rescale'], reference);
      expect(params['strength'], reference);
      expect(params['noise'], reference);
      expect(params['reference_strength_multiple'], [reference]);
      expect(params['director_reference_strength_values'], [reference]);
      expect(params['director_reference_secondary_strength_values'], [
        1 - reference,
      ]);
    },
  );

  testWidgets(
    'dialog reopens exact decimals and its nudge preserves the fractional tail',
    (tester) async {
      var value = .612345678901;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('edit'),
                onPressed: () async {
                  final next = await showParamInput(
                    context,
                    title: '强度',
                    value: value,
                    divisions: 100,
                  );
                  if (next != null) value = next;
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        value.toString(),
      );
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(value, closeTo(.622345678901, 1e-15));
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '0.73456789012345');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(value, .73456789012345);
    },
  );
}
