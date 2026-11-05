import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/generate/canvas_models.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/prompt_sections.dart';
import 'package:plana_app/features/import/image_prompt_import.dart';

void main() {
  const section = PromptSection(
    id: 'artist1',
    name: '画师串',
    positive: 'artist:a, artist:b',
    positiveRaw: 'artist:a, artist:b, ~hidden~',
    negative: 'blurry',
    negativeRaw: 'blurry, ~old~',
    enabled: false,
  );
  const before = CanvasPrompts(
    prompt: 'old main',
    promptRaw: 'old main, ~hidden~',
    negativePrompt: 'old negative',
    negativePromptRaw: 'old negative, ~hidden~',
    sections: [PromptSection.main(), section],
  );
  var seq = 0;
  String newId() => 'import${seq++}';

  test(
    'replace main preserves every section including duplicate tags and drafts',
    () {
      final next = importImagePromptsInto(
        before,
        ImagePromptImportMode.replaceMain,
        positive: 'artist:a, artist:b, new main',
        newId: newId,
      );
      expect(next.prompt, 'artist:a, artist:b, new main');
      expect(next.promptRaw, isEmpty);
      expect(next.negativePrompt, before.negativePrompt);
      expect(next.negativePromptRaw, before.negativePromptRaw);
      expect(next.sections, before.sections);
      expect(next.sections.last, same(section));
    },
  );

  test(
    'replace all removes entire section list but only writes selected main sides',
    () {
      final next = importImagePromptsInto(
        before,
        ImagePromptImportMode.replaceAll,
        negative: 'new negative',
        newId: newId,
      );
      expect(next.sections, isEmpty);
      expect(next.prompt, before.prompt);
      expect(next.promptRaw, before.promptRaw);
      expect(next.negativePrompt, 'new negative');
      expect(next.negativePromptRaw, isEmpty);
    },
  );

  test(
    'add section retains repeated complete positive and negative strings with new numbers',
    () {
      var next = before;
      for (var n = 1; n <= 2; n++) {
        next = importImagePromptsInto(
          next,
          ImagePromptImportMode.addSection,
          positive: 'artist:a, artist:b',
          negative: 'blurry',
          newId: newId,
        );
        expect(next.sections.last.name, '图片导入$n');
        expect(next.sections.last.positive, 'artist:a, artist:b');
        expect(next.sections.last.negative, 'blurry');
      }
      expect(next.prompt, before.prompt);
      expect(next.promptRaw, before.promptRaw);
      expect(next.negativePromptRaw, before.negativePromptRaw);
      expect(next.sections[1], same(section));
      expect(next.sections.map((s) => s.id).toSet(), hasLength(4));
      expect(
        joinSections(next.sections, next.prompt, positive: true),
        'old main, artist:a, artist:b, artist:a, artist:b',
      );
    },
  );

  test(
    'numbering follows largest existing image import number, not section count',
    () {
      final current = before.copyWith(
        sections: [
          ...before.sections,
          const PromptSection(id: 'n4', name: '图片导入4'),
          const PromptSection(id: 'n1', name: '图片导入1'),
        ],
      );
      final next = importImagePromptsInto(
        current,
        ImagePromptImportMode.addSection,
        positive: 'new',
        newId: newId,
      );
      expect(next.sections.last.name, '图片导入5');
    },
  );

  test(
    'unselected prompts and empty additional content never clear or create sections',
    () {
      for (final mode in ImagePromptImportMode.values) {
        expect(
          importImagePromptsInto(before, mode, newId: newId),
          same(before),
        );
      }
      expect(
        importImagePromptsInto(
          before,
          ImagePromptImportMode.addSection,
          positive: '',
          negative: ' ',
          newId: newId,
        ),
        same(before),
      );
    },
  );

  test(
    'first additional import creates main row and preserves negative-only imports',
    () {
      const current = CanvasPrompts(prompt: 'keep main');
      final next = importImagePromptsInto(
        current,
        ImagePromptImportMode.addSection,
        negative: 'new negative',
        newId: newId,
      );
      expect(next.sections.first.isMain, isTrue);
      expect(next.sections.last.name, '图片导入1');
      expect(next.sections.last.positive, isEmpty);
      expect(next.sections.last.negative, 'new negative');
      expect(next.prompt, 'keep main');
    },
  );
}
