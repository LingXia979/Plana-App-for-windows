import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/widgets/rich_tag_controller.dart';

List<TextStyle> stylesByOffset(TextSpan root) {
  final result = <TextStyle>[];
  void visit(TextSpan span, TextStyle inherited) {
    final style = inherited.merge(span.style);
    result.addAll(List.filled(span.text?.length ?? 0, style));
    for (final child in span.children ?? <InlineSpan>[]) {
      visit(child as TextSpan, style);
    }
  }

  visit(root, const TextStyle());
  return result;
}

void main() {
  for (final theme in [AppTheme.light(), AppTheme.dark()]) {
    testWidgets(
      'weight syntax stays neutral across single tags and groups (${theme.brightness.name})',
      (tester) async {
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Builder(
              builder: (value) {
                context = value;
                return const SizedBox();
              },
            ),
          ),
        );
        final controller = RichTagController()..showTrans = false;
        addTearDown(controller.dispose);
        final scheme = theme.colorScheme;
        for (final text in [
          for (final weight in ['1.3', '5', '0.7', '0', '-2', '1']) ...[
            '$weight::coat::',
            '$weight::coat, long sleeves::',
            '$weight::coat, long sleeves', // still being typed
          ],
          '{coat}, [hat], {coat, hat}, [coat, hat]',
          '1.3::{coat, [hat, ribbon]}::, year 2025, artist:min (120716)',
          '1.5::collar::, -2::bib, halter::, 1.2::folder, documents::',
        ]) {
          controller.text = text;
          final span = controller.buildTextSpan(
            context: context,
            withComposing: false,
          );
          expect(span.toPlainText(), text);
          final styles = stylesByOffset(span);
          expect(styles.length, text.length);
          for (var i = 0; i < text.length; i++) {
            if (text[i] == ',' || text[i] == ' ') continue;
            final marker = ':{}[]'.contains(text[i]);
            expect(
              styles[i].color,
              marker
                  ? scheme.onSurface.withValues(alpha: .45)
                  : scheme.onSurface,
              reason: 'Unexpected foreground at $i in "$text"',
            );
            expect(styles[i].decoration, isNull);
          }
        }
      },
    );
  }

  testWidgets('neutral weight syntax preserves disabled tags and fold colors', (
    tester,
  ) async {
    late BuildContext context;
    final theme = AppTheme.light();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );
    final text =
        '~1.3::coat::~, 1.2::ribbon, ~hat~::, ${foldRefLiteral('saved')}';
    final controller = RichTagController(text: text)
      ..foldBodies = {'saved': '0.7::mist, fog::'};
    addTearDown(controller.dispose);
    final span = controller.buildTextSpan(
      context: context,
      withComposing: false,
    );
    expect(span.toPlainText(), text);
    final styles = stylesByOffset(span);
    final scheme = theme.colorScheme;
    for (final word in ['1.3', 'coat', 'hat']) {
      final start = text.indexOf(word);
      for (var i = start; i < start + word.length; i++) {
        expect(styles[i].color, scheme.outline);
        expect(styles[i].decoration, TextDecoration.lineThrough);
      }
    }
    expect(styles[text.indexOf('ribbon')].color, scheme.onSurface);
    expect(styles[text.indexOf('ribbon')].decoration, isNull);
    expect(styles[text.indexOf(',')].color, scheme.outline);
    expect(styles[text.indexOf('saved')].color, scheme.primary);
    expect(
      styles[text.indexOf(kFoldZw)].color,
      scheme.primary.withValues(alpha: .4),
    );
  });
}
