import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/bot_session_store.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/platform/desktop.dart';
import '../../../core/ui/selection_bar.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import '../codex/codex_card.dart';
import '../codex/codex_favorites.dart';
import '../codex/codex_models.dart';
import '../codex/codex_providers.dart';
import '../codex/codex_sheets.dart' show showCodexDetailSheet;
import '../public_tags.dart';
import '../tag_library.dart';
import '../tag_models.dart';
import 'tag_card.dart';
import 'tag_filter_chips.dart';
import 'tag_sheets.dart';

/// 选中的一个条目:条目 + 它该显示的预览(按 publicId 补过,见 [tagPreviewOf])。
typedef PickedChar = ({TagEntry entry, String? preview});

/// 灵感库面板勾的一项:标签库条目或法典收藏,两者恰有一个。
typedef LibraryPick = ({PickedChar? tag, CodexFavorite? codex});

/// 灵感库面板选中的全部,按勾选的先后(跨分类、跨标签库与法典)。
typedef LibraryPicks = List<LibraryPick>;

/// 创作页灵感库面板给哪几类标签库,顺序同灵感页(法典另算);「其他」不放。
/// 「存到灵感库」也只给这几类,存进「其他」在面板里就选不到了。
const kPanelTagCats = [
  TagCategory.character,
  TagCategory.artist,
  TagCategory.scene,
];

/// 从灵感角色库选角色 —— 角色卡的头像、角色卡头的「角色库」共用。
/// 形态照相册「移动到」那张面板:标题 + 封面卡网格,卡片就是灵感页那种竖版封面卡。
///
/// 仅展示「我的」角色，带用户标签筛选。
/// [max] 为 1:点一张即选定并关闭,卡上不画选择圈(给单张角色卡换人)。
/// 大于 1:点卡勾选,底栏「加入角色」确认,最多 [max] 个。取消返回 null。
Future<List<PickedChar>?> showCharPickSheet(
  BuildContext context, {
  int max = 1,
}) async {
  final picks = await _showPickSheet(context, library: false, max: max);
  return picks == null ? null : [for (final p in picks) ?p.tag];
}

/// 从灵感库挑 —— 提示词卡头的「灵感库」。角色、画风、场景只列「我的」,法典只列
/// 收藏;顶上一排分段切换分类,勾选跨分类保留,底栏「加入」一次带走。
Future<LibraryPicks?> showLibraryPickSheet(BuildContext context) =>
    _showPickSheet(context, library: true, max: 99);

Future<LibraryPicks?> _showPickSheet(
  BuildContext context, {
  required bool library,
  required int max,
}) {
  final desktop = ProviderScope.containerOf(context).read(desktopModeProvider);
  if (desktop) {
    return showDialog<LibraryPicks>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 960,
          height: MediaQuery.sizeOf(context).height * .85,
          child: _PickSheet(library: library, max: max),
        ),
      ),
    );
  }
  return showModalBottomSheet<LibraryPicks>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _PickSheet(library: library, max: max),
  );
}

class _PickSheet extends ConsumerStatefulWidget {
  const _PickSheet({required this.library, required this.max});

  /// true = 整个灵感库(可切分类 + 法典收藏);false = 只选角色。
  final bool library;
  final int max;

  @override
  ConsumerState<_PickSheet> createState() => _PickSheetState();
}

class _PickSheetState extends ConsumerState<_PickSheet> {
  static const _pad = 12.0, _gap = 8.0;

  /// 灵感库面板上次停在哪一类(进程内记着,下次打开接着看);null = 法典收藏。
  static TagCategory? _lastCat = TagCategory.artist;

  /// 当前分类;null = 法典收藏(只有灵感库面板有)。
  late TagCategory? _cat = widget.library ? _lastCat : TagCategory.character;

  final _searchCtrl = TextEditingController();
  String _search = '';
  String? _filter;

  /// 已勾选的,插入序即勾选顺序(也就是加进去的顺序)。标签库条目的键带分类
  /// (各类 id 各自发号),法典收藏的键同收藏夹([CodexFavorite.key])。
  final _picks = <String, LibraryPick>{};

  static String _tagKey(TagEntry e) => 'tag:${e.category.name}/${e.id}';
  static String _codexKey(CodexFavorite f) => 'codex:${f.key}';

  bool get _multi => widget.max > 1;
  int get _count => _picks.length;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _switch(TagCategory? cat) {
    if (cat == _cat) return;
    setState(() {
      _cat = cat;
      _lastCat = cat;
      _searchCtrl.clear();
      _search = '';
      _filter = null;
    });
  }

  bool _roomFull() {
    if (_count < widget.max) return false;
    hintSnack(context, '最多选 ${widget.max} 个', icon: Icons.block_outlined);
    return true;
  }

  void _toggle(TagEntry e, String? preview) {
    final LibraryPick pick = (tag: (entry: e, preview: preview), codex: null);
    if (!_multi) return _done([pick]);
    _flip(_tagKey(e), pick);
  }

  void _toggleCodex(CodexFavorite f) =>
      _flip(_codexKey(f), (tag: null, codex: f));

  void _flip(String key, LibraryPick pick) {
    if (_picks.containsKey(key)) {
      setState(() => _picks.remove(key));
    } else if (!_roomFull()) {
      setState(() => _picks[key] = pick);
    }
  }

  void _done(LibraryPicks picks) {
    // 「最近使用」与灵感页确认时同一口径,按分类各记各的
    final byCat = <TagCategory, List<String>>{};
    for (final p in picks) {
      final t = p.tag;
      if (t != null) (byCat[t.entry.category] ??= []).add(t.entry.id);
    }
    final lib = ref.read(tagLibraryProvider.notifier);
    for (final MapEntry(key: cat, value: ids) in byCat.entries) {
      unawaited(lib.markUsed(cat, ids));
    }
    Navigator.pop(context, picks);
  }

  bool _matches(TagEntry e, String q) {
    if (q.isEmpty) return true;
    bool has(String s) => s.toLowerCase().contains(q);
    return has(e.name) ||
        e.aliases.any(has) ||
        has(e.positive) ||
        e.tags.any(has);
  }

  String? _validFilter(TagCategory cat, TagLibraryState lib) {
    final filter = _filter;
    if (filter == null || filter == TagFilterChips.favorites) return filter;
    return lib.knownTags(cat).contains(filter) ? filter : null;
  }

  /// 我的:自建 / 我发布的在前,收藏来的在后。组内画风按编号自然序
  /// (A1 < A2 < A10),其余最新在前,各自同灵感页的默认排法。
  List<TagEntry> _mineList(
    TagCategory cat,
    TagLibraryState lib,
    List<TagEntry>? pub,
  ) {
    final q = _search.trim().toLowerCase();
    final filter = _validFilter(cat, lib);
    final list = [
      for (final e in mergeMineTags(
        lib.of(cat),
        ref.watch(botSessionProvider).value?.botUserId,
        pub,
      ))
        if (_matches(e, q) &&
            (filter == null ||
                (filter == TagFilterChips.favorites
                    ? e.origin == TagOrigin.favorited
                    : e.tags.contains(filter))))
          e,
    ];
    int fav(TagEntry e) => e.origin == TagOrigin.favorited ? 1 : 0;
    list.sort((a, b) {
      final c = fav(a) - fav(b);
      if (c != 0) return c;
      return cat == TagCategory.artist
          ? naturalCompare(a.name, b.name)
          : b.createdAt.compareTo(a.createdAt);
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final lib = ref.watch(tagLibraryProvider).value ?? const TagLibraryState();
    final cat = _cat;
    return FractionallySizedBox(
      heightFactor: ref.watch(desktopModeProvider) ? 1 : .85,
      child: Padding(
        // 搜索时键盘顶上来,底栏跟着上移,别被盖住
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          children: [
            if (ref.watch(desktopModeProvider))
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.library ? '选择灵感' : '选择角色',
                        style: context.texts.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: widget.library
                  ? const EdgeInsets.fromLTRB(_pad, 0, _pad, 10)
                  : const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: widget.library
                  ? _catTabs()
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: Text('选择角色', style: context.texts.titleLarge),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _pad),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _search = v),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: cat == null
                      ? '搜索标题 / 提示词…'
                      : tagCategoryDef(cat).searchHint,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  filled: true,
                  fillColor: scheme.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (cat != null)
              TagFilterChips(
                tags: lib.knownTags(cat),
                filter: _validFilter(cat, lib),
                onChanged: (filter) => setState(() => _filter = filter),
                onManageTags: () => showTagPoolSheet(context, ref, cat),
                edge: _pad,
              ),
            Expanded(child: cat == null ? _codexGrid() : _tagGrid(cat, lib)),
            if (_multi)
              SelectionBar(
                visible: _count > 0,
                onClear: () => setState(_picks.clear),
                primary: FilledButton.icon(
                  onPressed: _count > 0
                      ? () => _done(_picks.values.toList())
                      : null,
                  style: selectionPrimaryStyle(),
                  icon: Icon(
                    widget.library ? Icons.add : Icons.person_add_alt,
                    size: 18,
                  ),
                  label: Text(
                    widget.library ? '加入 ($_count)' : '加入角色 ($_count)',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 分类横排:角色、画风、场景 + 法典(只列收藏),某类勾了几个跟在名字后面。
  /// 「其他」不放进来。
  Widget _catTabs() {
    final cats = kPanelTagCats;
    int pickedIn(TagCategory c) =>
        _picks.values.where((p) => p.tag?.entry.category == c).length;
    final cat = _cat;
    return _CatSegTabs(
      labels: [for (final c in cats) tagCategoryDef(c).label, '法典'],
      counts: [
        for (final c in cats) pickedIn(c),
        _picks.values.where((p) => p.codex != null).length,
      ],
      index: cat == null ? cats.length : cats.indexOf(cat),
      onTap: (i) => _switch(i < cats.length ? cats[i] : null),
    );
  }

  Widget _tagGrid(TagCategory cat, TagLibraryState lib) {
    final def = tagCategoryDef(cat);
    final pubAsync = ref.watch(publicTagsProvider(cat));
    final pubPreview = publicPreviewsOf(pubAsync.value);
    final list = _mineList(cat, lib, pubAsync.value);
    if (list.isEmpty) {
      return _empty(
        def.icon,
        _search.trim().isEmpty && _validFilter(cat, lib) == null
            ? '还没有${def.label}'
            : '没有匹配的${def.label}',
      );
    }
    // 画风是横图,三列太小看不清,两列
    final cols = cat == TagCategory.artist ? 2 : 3;
    return LayoutBuilder(
      builder: (context, box) {
        final cellW = (box.maxWidth - _pad * 2 - _gap * (cols - 1)) / cols;
        return GridView.builder(
          padding: _gridPadding(context),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: _gap,
            crossAxisSpacing: _gap,
            childAspectRatio: def.previewAspect,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final e = list[i];
            final preview = tagPreviewOf(e, pubPreview);
            return TagCard(
              key: ValueKey(e.id),
              entry: e,
              previewUrl: preview,
              decodeWidth: cellW,
              selected: _picks.containsKey(_tagKey(e)),
              isPublic: false,
              showCheck: _multi,
              onTap: () => _toggle(e, preview),
              onLongPress: () => showTagDetailSheet(context, e),
            );
          },
        );
      },
    );
  }

  /// 法典收藏:同收藏夹那张网格(两列等比),长按看词条详情。
  Widget _codexGrid() {
    final scheme = context.scheme;
    final favs = ref.watch(codexFavoritesProvider).value ?? const [];
    final index = ref.watch(codexIndexProvider).value ?? const <CodexMeta>[];
    final media = ref.watch(codexMediaProvider).value ?? CodexMedia.fallback;
    final q = _search.trim().toLowerCase();
    bool has(String s) => s.toLowerCase().contains(q);
    final list = [
      for (final f in favs)
        if (q.isEmpty ||
            has(f.entry.title) ||
            has(f.entry.tags) ||
            f.entry.characters.any((c) => has(c.prompt)))
          f,
    ];
    if (list.isEmpty) {
      return _empty(
        Icons.menu_book_outlined,
        favs.isEmpty ? '还没有收藏' : '没有匹配的词条',
      );
    }
    // 收藏里存的是词条快照,图 URL 还得靠 meta;索引里找不到就给个占位,
    // 图可能出不来,但那一条不会凭空消失(同收藏夹)
    CodexMeta metaOf(String id) =>
        index.where((m) => m.id == id).firstOrNull ??
        CodexMeta(id: id, type: CodexType.unknown, title: id);
    const aspect = 0.78;
    return LayoutBuilder(
      builder: (context, box) {
        final cellW = (box.maxWidth - _pad * 2 - _gap) / 2;
        return GridView.builder(
          padding: _gridPadding(context),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: _gap,
            crossAxisSpacing: _gap,
            childAspectRatio: aspect,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final f = list[i];
            final meta = metaOf(f.codexId);
            final selected = _picks.containsKey(_codexKey(f));
            return Stack(
              key: ValueKey(f.key),
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onLongPress: () => showCodexDetailSheet(
                      context,
                      meta,
                      media,
                      entries: [f.entry],
                      index: 0,
                    ),
                    child: CodexCard(
                      codex: meta,
                      entry: f.entry,
                      media: media,
                      fixedAspect: aspect,
                      decodeWidth: cellW,
                      onTap: () => _toggleCodex(f),
                    ),
                  ),
                ),
                // 选中描边与选择圈同标签库卡片;圈放右上,左上是 NEW 角标
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      duration: Motion.fast,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected ? scheme.primary : Colors.transparent,
                          width: 1.8,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 7,
                  right: 7,
                  child: IgnorePointer(child: _check(selected)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _check(bool selected) {
    final scheme = context.scheme;
    return AnimatedContainer(
      duration: Motion.fast,
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? scheme.primary : Colors.black.withValues(alpha: .3),
        border: selected ? null : Border.all(color: Colors.white70, width: 1.5),
      ),
      child: selected
          ? Icon(Icons.check, size: 16, color: scheme.onPrimary)
          : null,
    );
  }

  EdgeInsets _gridPadding(BuildContext context) => EdgeInsets.fromLTRB(
    _pad,
    4,
    _pad,
    16 + MediaQuery.paddingOf(context).bottom,
  );

  Widget _empty(IconData icon, String text) {
    final scheme = context.scheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: scheme.outlineVariant),
          const SizedBox(height: 10),
          Text(
            text,
            style: context.texts.bodyMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 分类分段:照「我的 / 公共库」那条(底色、滑块、字色都同 [ScopeSegTabs]),
/// 几段等宽,整段任意位置可点。
class _CatSegTabs extends StatelessWidget {
  const _CatSegTabs({
    required this.labels,
    required this.counts,
    required this.index,
    required this.onTap,
  });

  final List<String> labels;

  /// 每段已勾的个数,0 不显示。
  final List<int> counts;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return SizedBox(
      height: 42,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            final segW = c.maxWidth / labels.length;
            return Stack(
              children: [
                AnimatedPositioned(
                  duration: Motion.medium,
                  curve: Motion.emphasized,
                  top: 3,
                  bottom: 3,
                  left: 3 + index * segW,
                  width: segW - 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(9),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .06),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
                // 铺满整条:不 fill 的话这排只有字那么高、贴在顶上,点分段下半截
                // 也切不过去
                Positioned.fill(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < labels.length; i++)
                        Expanded(
                          child: Semantics(
                            button: true,
                            selected: i == index,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => onTap(i),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  AnimatedDefaultTextStyle(
                                    duration: Motion.fast,
                                    style: context.texts.labelLarge!.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: i == index
                                          ? scheme.primary
                                          : scheme.onSurfaceVariant,
                                    ),
                                    child: Text(labels[i]),
                                  ),
                                  if (counts[i] > 0) ...[
                                    const SizedBox(width: 4),
                                    Text(
                                      '${counts[i]}',
                                      style: mono(
                                        context,
                                        size: 11,
                                        weight: FontWeight.w700,
                                      ).copyWith(color: scheme.primary),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
