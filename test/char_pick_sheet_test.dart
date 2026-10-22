import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/inspiration/widgets/char_pick_sheet.dart';
import 'package:plana_app/features/inspiration/widgets/scope_seg_tabs.dart';
import 'package:plana_app/features/inspiration/widgets/tag_card.dart';
import 'package:plana_app/features/inspiration/widgets/tag_filter_chips.dart';

const _mine = TagEntry(
  id: 'mine',
  category: TagCategory.character,
  name: '我的角色',
  positive: 'blue hair',
  negative: 'bad hands',
  tags: ['常用'],
);
const _favorite = TagEntry(
  id: 'favorite',
  category: TagCategory.character,
  name: '收藏的角色',
  positive: 'silver hair',
  tags: ['银发'],
  origin: TagOrigin.favorited,
  publicId: 'favorite',
);
const _public = TagEntry(
  id: 'pub_other',
  category: TagCategory.character,
  name: '公共角色',
  positive: 'red hair',
  publicId: 'other',
  createdBy: 'someone-else',
);
const _ownedPublic = TagEntry(
  id: 'pub_owned',
  category: TagCategory.character,
  name: '我发布的角色',
  positive: 'black hair',
  publicId: 'owned',
  createdBy: 'me',
);

class _Library extends TagLibrary {
  @override
  Future<TagLibraryState> build() async => const TagLibraryState(
    entries: [_mine, _favorite],
    pools: {
      TagCategory.character: ['常用', '空标签'],
    },
  );

  @override
  Future<void> markUsed(TagCategory category, List<String> ids) async {
    final current = state.requireValue;
    state = AsyncData(
      current.copyWith(usage: {...current.usage, category: ids}),
    );
  }

  void removeFilterTag() {
    final current = state.requireValue;
    state = AsyncData(
      current.copyWith(
        pools: {},
        entries: [for (final e in current.entries) e.copyWith(tags: [])],
      ),
    );
  }
}

class _Session extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async =>
      const BotSession(sessionId: 'test', botUserId: 'me');
}

class _Harness {
  _Harness(this.container);
  final ProviderContainer container;
  final navigator = GlobalKey<NavigatorState>();
  bool completed = false;
  List<PickedChar>? result;

  _Library get library =>
      container.read(tagLibraryProvider.notifier) as _Library;
}

Future<_Harness> _open(WidgetTester tester, {int max = 3}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      tagLibraryProvider.overrideWith(_Library.new),
      botSessionProvider.overrideWith(_Session.new),
      publicTagsProvider(
        TagCategory.character,
      ).overrideWith((_) async => const [_public, _ownedPublic]),
      tagAuthorNamesProvider.overrideWith((_) async => const {}),
      tagTranslationServiceProvider.overrideWith((ref) {
        final service = TagTranslationService(enabled: false, baseUrl: '');
        ref.onDispose(service.dispose);
        return service;
      }),
    ],
  );
  addTearDown(container.dispose);
  final harness = _Harness(container);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        navigatorKey: harness.navigator,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  harness.result = await showCharPickSheet(context, max: max);
                  harness.completed = true;
                },
                child: const Text('打开选择器'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开选择器'));
  await tester.pumpAndSettle();
  return harness;
}

Finder _card(String id) => find.byWidgetPredicate(
  (widget) => widget is TagCard && widget.entry.id == id,
);

void main() {
  for (final max in [1, 3]) {
    testWidgets('没有库切换，仅我的角色可${max == 1 ? '替换' : '勾选'}', (tester) async {
      final harness = await _open(tester, max: max);
      expect(find.byType(ScopeSegTabs), findsNothing);
      expect(find.byType(TabBarView), findsNothing);
      expect(find.text('公共库'), findsNothing);
      expect(_card('pub_other'), findsNothing);
      expect(find.byType(TagFilterChips), findsOneWidget);
      await tester.tap(_card('mine'));
      await tester.pumpAndSettle();
      if (max > 1) {
        expect(harness.completed, isFalse);
        expect(tester.widget<TagCard>(_card('mine')).selected, isTrue);
        await tester.tap(find.text('加入角色 (1)'));
      }
      await tester.pumpAndSettle();
      expect(harness.completed, isTrue);
      expect(harness.result!.single.entry.id, 'mine');
      expect(harness.result!.single.entry.negative, 'bad hands');
      expect(
        harness.container
            .read(tagLibraryProvider)
            .requireValue
            .usage[TagCategory.character],
        ['mine'],
      );
    });
  }

  testWidgets('用户标签包含标签池和在用标签，可与搜索叠加并筛收藏', (tester) async {
    await _open(tester);
    expect(_card('pub_owned'), findsOneWidget);
    final filters = tester.widget<TagFilterChips>(find.byType(TagFilterChips));
    expect(filters.tags, containsAll(['常用', '空标签', '银发']));
    await tester.tap(find.widgetWithText(ChoiceChip, '常用'));
    await tester.pumpAndSettle();
    expect(_card('mine'), findsOneWidget);
    expect(_card('favorite'), findsNothing);
    await tester.enterText(find.byType(TextField), 'silver');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的角色'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'blue');
    await tester.pumpAndSettle();
    expect(_card('mine'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.widgetWithText(ChoiceChip, '收藏'));
    await tester.pumpAndSettle();
    expect(_card('favorite'), findsOneWidget);
    expect(_card('mine'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, '全部'));
    await tester.pumpAndSettle();
    expect(_card('mine'), findsOneWidget);
    expect(_card('favorite'), findsOneWidget);
  });

  testWidgets('标签被移除后回到全部，不留下无效筛选', (tester) async {
    final harness = await _open(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, '常用'));
    await tester.pumpAndSettle();
    harness.library.removeFilterTag();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TagFilterChips>(find.byType(TagFilterChips)).filter,
      isNull,
    );
    expect(_card('favorite'), findsOneWidget);
    expect(_card('mine'), findsOneWidget);
  });

  testWidgets('收藏的和我发布的角色仍能多选，按选择顺序加入', (tester) async {
    final harness = await _open(tester);
    await tester.tap(_card('favorite'));
    await tester.tap(_card('pub_owned'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入角色 (2)'));
    await tester.pumpAndSettle();
    expect(harness.result!.map((p) => p.entry.id), ['favorite', 'pub_owned']);
    expect(harness.result!.last.entry.origin, TagOrigin.created);
  });
}
