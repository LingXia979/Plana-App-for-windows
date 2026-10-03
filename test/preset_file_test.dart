import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/generate/preset_file.dart';

void main() {
  test('native preset file retains prompts, scope and placement', () {
    final presets = parsePresetFile(
      jsonEncode({
        'activeId': 'example',
        'custom': [
          {
            'id': 'example',
            'name': '模型预设',
            'positive': '  a,\n b  ',
            'negative': 'bad anatomy',
            'scope': 'v5',
            'positivePlacement': 'suffix',
            'createdAt': 42,
          },
        ],
        'order': ['example'],
      }),
    );
    final preset = presets.single;
    expect(preset.id, 'example');
    expect(preset.name, '模型预设');
    expect(preset.positive, '  a,\n b  ');
    expect(preset.negative, 'bad anatomy');
    expect(preset.scope, 'v5');
    expect(preset.suffixPositive, isTrue);
    expect(preset.createdAt, 42);
  });

  test('single preset, JSON list and presets wrapper are accepted', () {
    final source = {'positive': 'a', 'scope': 'legacy'};
    for (final json in [
      source,
      [source],
      {
        'presets': [source],
      },
    ]) {
      final preset = parsePresetFile('\uFEFF${jsonEncode(json)}').single;
      expect(preset.name, '导入的预设');
      expect(preset.positive, 'a');
      expect(preset.negative, '');
      expect(preset.scope, 'legacy');
      expect(preset.suffixPositive, isFalse);
    }
  });

  test(
    'missing IDs are stable across repeated imports and default placement',
    () {
      final source = {'name': '收藏', 'positive': 'x', 'negative': 'y'};
      final first = parsePresetFile(jsonEncode(source)).single;
      final again = parsePresetFile(jsonEncode(source)).single;
      final explicitPrefix = parsePresetFile(
        jsonEncode({...source, 'positivePlacement': 'prefix'}),
      ).single;
      final suffix = parsePresetFile(
        jsonEncode({...source, 'positivePlacement': 'suffix'}),
      ).single;
      expect(first.id, again.id);
      expect(first.id, explicitPrefix.id);
      expect(first.id, isNot(suffix.id));
    },
  );

  test(
    'same IDs update once and imported defaults cannot replace built-ins',
    () {
      final presets = parsePresetFile(
        jsonEncode([
          {'id': 'heavy', 'positive': 'do not replace'},
          {'id': 'built-in', 'positive': 'ignored', 'isDefault': true},
          {'id': 'same', 'positive': 'old'},
          {'id': 'same', 'positive': 'new', 'negative': 'b'},
        ]),
      );
      expect(presets, hasLength(1));
      expect(presets.single.id, 'same');
      expect(presets.single.positive, 'new');
      expect(presets.single.negative, 'b');
    },
  );

  test('invalid file or invalid entry rejects the complete import', () {
    for (final json in [
      null,
      2,
      [],
      {'custom': 'not a list'},
      {'name': 'missing prompt'},
      {'positive': 10},
      {'positive': 'x', 'scope': 'unknown'},
      {'positive': 'x', 'positivePlacement': 'after'},
      {'positive': 'x', 'positivePlacement': true},
      {'positive': 'x', 'createdAt': 4.5},
      {'positive': 'x', 'isDefault': 'true'},
      [
        {'positive': 'valid'},
        {'negative': []},
      ],
    ]) {
      expect(
        () => parsePresetFile(jsonEncode(json)),
        throwsFormatException,
        reason: '$json',
      );
    }
    expect(() => parsePresetFile('not JSON'), throwsFormatException);
  });
}
