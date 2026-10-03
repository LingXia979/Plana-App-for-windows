import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show SliverConstraints, SliverGridGeometry, SliverGridLayout;
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, LogicalKeyboardKey, PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/store/app_stores.dart';
import '../../../core/store/ui_prefs.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/document_save.dart';
import '../../generate/widgets/common.dart'
    show ExpandBody, hintSnack, sharedAxisRoute;
import '../../import/import_panel.dart';
import '../../generate/generation_controller.dart';
import '../../desktop/desktop_library_state.dart';
import '../gallery_date_filter.dart';
import '../albums/album_state.dart';
import '../albums/album_ui.dart';
import '../albums/album_organize_sheet.dart';
import '../albums/gallery_transfer_dialog.dart';
import 'gallery_date_sheet.dart';
import 'gallery_output_folder_button.dart';
import 'gallery_export_dialog.dart';
import 'gallery_drag_selection.dart';
import 'gallery_image_tile.dart';
import '../gallery_groups.dart';
import '../gallery_search.dart';
import '../gallery_state.dart';
import '../models.dart';
import '../phone_gallery_save.dart';
import '../save_pipeline.dart';
import '../save_settings.dart';
import '../share_pipeline.dart';
import 'album_name_sheet.dart';
import 'result_thumb.dart';
import 'zip_pack_sheet.dart';
import '../../../core/util/haptics.dart';

typedef GalleryLibraryChooser =
    void Function(BuildContext context, WidgetRef ref);

/// 「›」展开:全部作品网格弹层。默认按时间分段;可切成**按角色 / 按画风堆叠**
/// —— 一个角色(或一个画风)收成一张封面卡,点开才展开该堆的网格
/// (归属见 gallery_groups,全程离线)。
/// 可按模型/时间筛选、按提示词标签搜索(数据源 gallery_search 检索索引,
/// 筛选条件全 AND 组合)。
/// 点选一张即回填画布并关闭;手机长按弹出该张的导入 / 保存 / 删除菜单。
/// 桌面快速浏览与图库详情支持鼠标按下后小位移进入多选，触摸仍长按 200ms;
/// 进入多选后可继续拖动勾选，右键打开图片菜单;
/// 段头可整段全选,底部批量保存相册 / 分享 /
/// 打包 ZIP / 批量删除。导出所选后，可按确认的选项清理整个当前图库。
Future<void> showGalleryGrid(
  BuildContext context, {
  bool desktop = false,
  GalleryLibraryChooser? onChooseAlbum,
}) {
  if (desktop) {
    final contentKey = GlobalKey<GalleryGridContentState>();
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Focus(
        // The close button is outside the grid's own focus subtree. Keep the
        // same Escape behavior when keyboard navigation lands on that button.
        onKeyEvent: (node, event) =>
            contentKey.currentState?._onDesktopKey(node, event) ??
            KeyEventResult.ignored,
        child: Dialog(
          insetPadding: const EdgeInsets.all(32),
          child: SizedBox(
            key: const ValueKey('desktop-quick-gallery'),
            width: 1160,
            height: 820,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 10, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '快速浏览与批量导出',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭快速浏览',
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: GalleryGridContent(
                    key: contentKey,
                    desktop: true,
                    embedded: true,
                    onChooseAlbum: onChooseAlbum,
                    onClose: () => Navigator.pop(dialogContext),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const GalleryGridContent(),
  );
}

/// 首次打开快速浏览时说明当前平台的长按与右键操作。
const _kGridHintKey = 'hint_grid_longpress';

/// 弹层的会话内记忆:关掉再打开,回到上次停的地方 —— 还在那一堆里、还是那个
/// 位置。只活在内存里(同 ScrollMemory),冷启动从顶部开始。
///
/// 网格(分段列表、堆内)按**离底**落位:最新的图排在最前,两次打开之间出的新图
/// 全插在顶上,离顶的像素会跟着漂;离底那一截全是更旧的图,不受影响。两种情况按
/// 离顶:本来就停在顶上的(在看最新的,新出的图就该露出来),以及封面墙(堆按堆内
/// 最新一张排,新图会把它那一堆提到最前,整面墙重排,离底也对不上号)。
class _GridMemory {
  const _GridMemory({
    required this.groupBy,
    required this.openKey,
    required this.offset,
    required this.fromBottom,
    required this.pinTop,
    required this.wallOffset,
  });

  final GalleryGroupBy groupBy;
  final String? openKey;
  final double offset;
  final double fromBottom;

  /// 按离顶落位(见上)。
  final bool pinTop;

  /// 停在某一堆里时封面墙滚到的位置,退回墙上时还原。
  final double wallOffset;
}

final _gridMemories = <String, _GridMemory>{};

/// The full library page uses the same filters and batch operations as quick
/// browse, while keeping its own library scope and opening image details.
class GalleryGridBrowser {
  const GalleryGridBrowser({
    required this.albumId,
    required this.title,
    required this.onBack,
    required this.onOpenImage,
  });

  final String? albumId;
  final String title;
  final VoidCallback onBack;
  final void Function(List<ResultImage> images, int index) onOpenImage;
}

class GalleryGridContent extends ConsumerStatefulWidget {
  const GalleryGridContent({
    super.key,
    this.embedded = false,
    this.desktop = false,
    this.onClose,
    this.onChooseAlbum,
    this.libraryLabel,
    this.browser,
  });

  final bool embedded;
  final bool desktop;
  final VoidCallback? onClose;
  final GalleryLibraryChooser? onChooseAlbum;
  final String? libraryLabel;
  final GalleryGridBrowser? browser;

  @override
  ConsumerState<GalleryGridContent> createState() => GalleryGridContentState();
}

class GalleryGridContentState extends ConsumerState<GalleryGridContent>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  void _close() {
    if (widget.embedded) {
      widget.onClose?.call();
    } else {
      Navigator.of(context).pop();
    }
  }

  bool _selecting = false;
  final Set<String> _picked = {};
  bool _saving = false;
  bool _sharing = false;
  bool _zipping = false;
  bool _organizing = false;
  String? get _scope => widget.browser != null
      ? widget.browser!.albumId
      : ref.read(galleryBrowseAlbumProvider);
  late String _scopeKey = _scope ?? '';
  String get _memoryKey =>
      '${widget.browser == null ? 'quick' : 'page'}:$_scopeKey';
  // 保存 / 分享 / 打包共用这对计数(三件事不会同时跑,canAct 互斥)
  int _saveDone = 0;
  int _saveTotal = 0;

  // ---- 检索/筛选(弹层内临时态,关弹层即重置) ----
  final _searchCtrl = TextEditingController();
  // 焦点显式管理:搜索框在 ExpandBody 里是**常驻构建**的(只是高度收成 0),
  // 用 autofocus 会在弹层一打开就抢焦点弹键盘 —— 用户还没想搜。
  final _searchFocus = FocusNode();
  final _keyboardFocus = FocusNode(debugLabel: 'Gallery selection');
  final _groupAnchor = GlobalKey();
  final _modelAnchor = GlobalKey();
  final _dateAnchor = GlobalKey();
  Timer? _searchDebounce;
  bool _searchOpen = false;
  String _query = '';
  String? _modelFilter; // null=全部;''=未知(无参数快照的老图)
  bool _favoritesOnly = false;
  // 保存日历日期；相对日期跨日与恢复前台时重新计算。
  late GalleryDateFilter _dateFilter = widget.browser == null
      ? ref.read(uiPrefsProvider).dateFilter
      : const GalleryDateFilter.all();
  late final Timer _dateTick;

  // 分组维度,同样记住上次的。存的是枚举名,不是下标 —— 将来插一档不会把
  // 老用户的选择挪到别的维度去。
  late GalleryGroupBy _groupBy = GalleryGroupBy.values.firstWhere(
    (e) => e.name == ref.read(uiPrefsProvider).galleryGroupBy,
    orElse: () => GalleryGroupBy.day,
  );

  // ---- 双指捏合改列数 ----
  //
  // 走 Listener 而不是 GestureDetector(onScale*):后者会把**单指**拖动也拉进
  // 手势竞技场,和列表自己的竖向滚动抢,滚动就废了。Listener 只旁听原始指针事件、
  // 完全不参与竞技场;列表则在捏合期间换上 [_FrozenScrollPhysics] —— 不滚,
  // 但仍占着手势,免得弹层的下拉关闭捡漏。
  //
  // **手势只负责触发,不负责驱动**:指间距过阈值就换一档,过渡由 [_morph] 自己
  // 跑完。曾经做过全程跟手的版本(进度实时跟指间距走),那样手指的微抖会一分不差
  // 地变成网格几何,整片图跟着颤;死区、增益、低通三道一起上也压不干净 ——
  // 换一档本来就是个离散决定,拿连续量去驱动它是自找的麻烦。
  //
  // 过渡本身仍是 [_ZoomGridDelegate] 的几何插值:每一格从旧位置连续走到新位置,
  // 而不是整片画面缩放再交叉淡化。
  late int _cols = ref.read(uiPrefsProvider).galleryColumns;

  /// 触发一档所需的指间距倍率。取对数看两个方向基本对称(±0.22)。
  static const _kZoomIn = 1.25; // 撑开到 1.25 倍 → 少一列
  static const _kZoomOut = .8; // 收拢到 0.8 倍 → 多一列

  final _pointers = <int, Offset>{};
  double? _span0; // 基准指间距;每换一档就重取,于是可以一路捏下去
  final _bodyKey = GlobalKey();

  /// 过渡中的目标列数;null = 没在过渡。
  int? _toCols;

  /// 当前列数 → 目标列数的进度 0..1,网格几何按它插值。只由 [_morph] 驱动。
  double _t = 0;

  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: Motion.medium,
  );

  final ScrollController _ctrl = ScrollController();

  // 锚定:把「触发那一刻焦点落在内容里的相对位置」钉住,否则列数一变内容总高
  // 跟着变,画面会整体上下漂。
  double _anchorOff = 0, _anchorContent = 0, _focalY = 0;

  // ---- 进出堆的过场 ----
  //
  // 走 Material 的 fade-through:先把旧内容淡出,**在中间换掉**,再淡入并从 94%
  // 长回原样。两头不重叠正是这个范式的用意 —— 封面墙与堆内网格没有任何共同元素,
  // 强行交叉淡化只会糊成一团。
  //
  // 也因此只需要一棵树、一份 ScrollPosition:同一时刻只有一边在画。用
  // AnimatedSwitcher 就得同时留两棵 CustomScrollView,而它们共用 [_ctrl] 会直接
  // 断言失败(一个 controller 挂两个 position)。
  late final AnimationController _open = AnimationController(
    vsync: this,
    duration: Motion.medium,
  );

  /// 淡出占整段的比例;之后是淡入。
  static const _kFadeOut = .3;

  String? _pendingOpen;
  bool _openApplied = true;

  /// 封面墙的滚动位置。进堆时记下,回来时还原 —— 逛到一半点进去,回来还在原处。
  double _wallOffset = 0;

  /// 堆叠视图里**已经点开**的那一堆(键);null = 正看封面墙。
  ///
  /// 换分组维度时清掉(那一堆在新维度下不存在)。**筛选变化不清** —— 堆是从
  /// 筛选后的集合算出来的,所以在堆里搜索是在这一堆内收窄;收窄到空时这一堆
  /// 自己就没了,build 里那句 firstOrNull 取不到,自动退回封面墙。
  String? _openKey;

  /// 顶栏尾部那几颗文字按钮(多选 / 全选 / 完成)的样式。
  ///
  /// M3 的 TextButton 默认 `minimumSize: Size(64, 40)`,而「多选」两个字才二十
  /// 来像素宽 —— 撑到 64 之后,多出来的宽度平摊到两侧成了额外内边距,文字被推得
  /// 离右缘比左边标题离左缘远出十来像素,一眼就是右边没贴边。这里把最小宽度放开、
  /// 内边距写死成 12,配合容器的 4,文字落点与左边的 16 对齐。
  ///
  /// 高度仍留 40,且 tapTargetSize 保持默认(padded)—— 触摸区照样撑到 48,
  /// 只是不再把视觉往里推。
  static final _headerBtn = TextButton.styleFrom(
    minimumSize: const Size(0, 40),
    padding: const EdgeInsets.symmetric(horizontal: 12),
  );

  // ---- 多选操作栏的几何 ----
  static const _actH = 46.0;
  static const _actSubH = 38.0;
  static const _actGap = 10.0;

  /// 次行三颗按钮:M3 默认给带图标的按钮留 16/24 的内边距,三颗平分一行就只
  /// 剩下十来个像素放字。收到 10 —— 高度本来也矮一档,窄一点不违和。
  static final _subActBtn = OutlinedButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 10),
  );

  /// 次行按钮的文字:窄屏上宁可缩一号也别溢出(「自定义相册」四五个字最吃紧,
  /// 进度态的「准备 8/12」也长)。
  static Widget _fitLabel(String text) =>
      FittedBox(fit: BoxFit.scaleDown, child: Text(text));

  Widget _batchActions(bool canAct) => LayoutBuilder(
    builder: (context, size) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final columns = widget.desktop && size.maxWidth >= 700 && scale <= 1.2
          ? 5
          : size.maxWidth < 340 || scale > 1.2
          ? 2
          : 3;
      final width = (size.maxWidth - _actGap * (columns - 1)) / columns;
      final primary = FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
      );
      final buttons = <Widget>[
        FilledButton.tonalIcon(
          key: const ValueKey('gallery-batch-export'),
          style: primary,
          onPressed: canAct ? _downloadPicked : null,
          icon: const Icon(Icons.download, size: 19),
          label: _fitLabel(
            _saving
                ? '保存中 $_saveDone/$_saveTotal'
                : '${widget.desktop ? '导出图片' : '保存'} (${_picked.length})',
          ),
        ),
        FilledButton.tonalIcon(
          key: const ValueKey('gallery-batch-move'),
          style: primary,
          onPressed: canAct
              ? widget.desktop
                    ? () => _transferPicked(copy: false)
                    : _organizePicked
              : null,
          icon: const Icon(Icons.drive_file_move_outline, size: 18),
          label: _fitLabel('移动 (${_picked.length})'),
        ),
        if (widget.desktop)
          FilledButton.tonalIcon(
            key: const ValueKey('gallery-batch-copy'),
            style: primary,
            onPressed: canAct ? () => _transferPicked(copy: true) : null,
            icon: const Icon(Icons.copy_outlined, size: 18),
            label: _fitLabel('复制 (${_picked.length})'),
          ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            backgroundColor: context.scheme.errorContainer,
            foregroundColor: context.scheme.onErrorContainer,
          ),
          onPressed: canAct ? _deletePicked : null,
          icon: const Icon(Icons.delete_outline, size: 19),
          label: _fitLabel('删除 (${_picked.length})'),
        ),
        if (!widget.desktop)
          OutlinedButton.icon(
            style: _subActBtn,
            onPressed: canAct ? _sharePicked : null,
            icon: _sharing
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share, size: 17),
            label: _fitLabel(_sharing ? '准备 $_saveDone/$_saveTotal' : '分享'),
          ),
        if (!widget.embedded && !widget.desktop)
          OutlinedButton.icon(
            style: _subActBtn,
            onPressed: canAct ? _downloadToAlbum : null,
            icon: const Icon(Icons.photo_album_outlined, size: 17),
            label: _fitLabel('手机相册'),
          ),
        OutlinedButton.icon(
          style: _subActBtn,
          onPressed: canAct ? _zipPicked : null,
          icon: _zipping
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.folder_zip_outlined, size: 17),
          label: _fitLabel(_zipping ? '打包中' : '打包 ZIP'),
        ),
      ];
      return Wrap(
        spacing: _actGap,
        runSpacing: _actGap,
        children: [
          for (var i = 0; i < buttons.length; i++)
            SizedBox(
              width: width,
              height: math.max(
                widget.desktop || columns == 2 || i < 3 ? _actH : _actSubH,
                20 * scale + 20,
              ),
              child: buttons[i],
            ),
        ],
      );
    },
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && _dateFilter.active) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dateTick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _dateFilter.active) setState(() {});
    });
    _morph.addStatusListener(_onMorphDone);
    _morph.addListener(_onMorphTick);
    _open.addListener(_onOpenTick);
    _ctrl.addListener(_remember);
    // 换过分组维度的记忆不认:那一堆、那个位置在这个维度下都不存在
    final memory = _gridMemories[_memoryKey];
    if (memory != null && memory.groupBy == _groupBy) {
      _openKey = memory.openKey;
      _wallOffset = memory.wallOffset;
      WidgetsBinding.instance.addPostFrameCallback((_) => _restore(memory));
    }
    if (widget.browser != null) return;
    final prefs = ref.read(prefsStoreProvider);
    if (prefs.get(_kGridHintKey) != null) return;
    prefs.write(key: _kGridHintKey, value: '1');
    // 弹层刚推进来那一帧 overlay 还没稳,推到帧后再弹
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        hintSnack(
          context,
          widget.desktop
              ? '长按 0.2 秒进入多选；右键图片可预览、复用参数、保存或删除'
              : '长按一张图可放大预览,并导入 / 保存 / 删除',
          icon: widget.embedded
              ? Icons.mouse_outlined
              : Icons.touch_app_outlined,
        );
      }
    });
  }

  /// 过渡每一帧:推进插值进度并回正滚动位置。
  void _onMorphTick() {
    setState(() => _t = Motion.emphasized.transform(_morph.value));
    _reanchorAfterLayout();
  }

  void _onMorphDone(AnimationStatus st) {
    if (st != AnimationStatus.completed) return;
    _endMorph();
    _persistCols();
  }

  /// 进出堆:淡出跑到一半时把内容换掉,后半段淡入。
  void _onOpenTick() {
    if (!_openApplied && _open.value >= _kFadeOut) {
      _openApplied = true;
      _applyOpen();
    }
    setState(() {});
  }

  /// 点开某一堆 / 回封面墙。内容不当场换,交给 [_onOpenTick] 在过场中点换。
  void _setOpen(String? key) {
    if (key == _openKey) return;
    _pendingOpen = key;
    _openApplied = false;
    _open.forward(from: 0);
  }

  void _applyOpen() {
    final key = _pendingOpen;
    // 从封面墙进堆:记下墙滚到哪了,回来时还原
    if (_openKey == null && _ctrl.hasClients) _wallOffset = _ctrl.offset;
    final want = key == null ? _wallOffset : 0.0;
    setState(() => _openKey = key);
    // 新内容的高度要等布局跑完才知道,位置只能帧后再落。这一刻画面正淡着,看不见。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_ctrl.hasClients) return;
      _ctrl.jumpTo(want.clamp(0.0, _ctrl.position.maxScrollExtent));
    });
  }

  /// 落定:目标列数坐实成当前列数。中途被新的一档打断时也走这里。
  void _endMorph() {
    final to = _toCols;
    if (to == null) return;
    setState(() {
      _cols = to;
      _toCols = null;
      _t = 0;
    });
  }

  // ---- 滚动记忆(见 [_GridMemory])与回顶 ----

  /// 贴顶的容差:停在这以内算「在看最新的」。
  static const _kTopSlop = 24.0;

  /// build 里最近一次是否真在显示点开的那一堆(记着的那一堆可能已经不在了)。
  bool _inStack = false;

  /// 记下眼下停的位置。
  ///
  /// 有搜索词或模型筛选时不记:那是筛过的列表,而这两样关弹层就清,下次打开对着的
  /// 是没筛的列表,拿筛过的位置去落只会错位 —— 停在筛之前记的那一次上。进出堆的
  /// 过场中也不记:新内容的位置要到帧后才落。
  void _remember() {
    if (_query.isNotEmpty || _modelFilter != null || _open.isAnimating) return;
    if (!_ctrl.hasClients || _ctrl.positions.length != 1) return;
    final p = _ctrl.position;
    if (!p.hasContentDimensions) return;
    // 认 build 里真在显示的,不认 _openKey:那一堆被筛没了时键还留着,画面却是墙
    _gridMemories[_memoryKey] = _GridMemory(
      groupBy: _groupBy,
      openKey: _inStack ? _openKey : null,
      offset: p.pixels,
      fromBottom: p.maxScrollExtent - p.pixels,
      pinTop: (_groupBy.stacked && !_inStack) || p.pixels < _kTopSlop,
      wallOffset: _inStack ? _wallOffset : p.pixels,
    );
  }

  /// 按记忆落位。内容总高要等首帧布局才知道,只能帧后跑;弹层这时还在往上滑,
  /// 跳这一下看不见。
  void _restore(_GridMemory m) {
    if (!mounted || !_ctrl.hasClients || _ctrl.positions.length != 1) return;
    final p = _ctrl.position;
    if (!p.hasContentDimensions) return;
    final double want;
    if (m.openKey != null && !_inStack) {
      // 记着的那一堆已经没了(图删了 / 换了时间筛选):回墙上原来的位置
      _openKey = null;
      want = m.wallOffset;
    } else {
      want = m.pinTop ? m.offset : p.maxScrollExtent - m.fromBottom;
    }
    final to = want.clamp(p.minScrollExtent, p.maxScrollExtent);
    if ((to - p.pixels).abs() > 1) _ctrl.jumpTo(to);
  }

  /// 回顶。离得远时先跳到离顶一屏半的地方再滑:一路滑过几十屏会把沿途每一行
  /// 缩略图都建出来、读一遍盘,滑的那一两秒全是卡的。
  void _scrollToTop() {
    if (!_ctrl.hasClients || _ctrl.positions.length != 1) return;
    final p = _ctrl.position;
    final near = p.viewportDimension * 1.5;
    if (p.pixels > near) _ctrl.jumpTo(near);
    _ctrl.animateTo(0, duration: Motion.slow, curve: Motion.emphasized);
  }

  /// 顶栏的回顶按钮:滚过一屏才出现,回到一屏以内收起。只跟着滚动重建它自己。
  Widget _topButton(ColorScheme scheme, {required bool hasList}) =>
      ListenableBuilder(
        listenable: _ctrl,
        builder: (context, _) {
          final far =
              hasList &&
              _ctrl.hasClients &&
              _ctrl.positions.length == 1 &&
              _ctrl.position.hasViewportDimension &&
              _ctrl.offset > _ctrl.position.viewportDimension;
          return AnimatedSwitcher(
            duration: Motion.fast,
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SizeTransition(
                sizeFactor: a,
                axis: Axis.horizontal,
                child: child,
              ),
            ),
            child: far
                ? IconButton(
                    key: const ValueKey(true),
                    onPressed: _scrollToTop,
                    visualDensity: VisualDensity.compact,
                    tooltip: '回到顶部',
                    icon: Icon(
                      Icons.vertical_align_top,
                      size: 21,
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey(false)),
          );
        },
      );

  @override
  void deactivate() {
    // 关弹层前最后记一次:开着期间出了新图、删了图,内容高变了却没滚过,
    // 滚动监听是收不到的
    _remember();
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dateTick.cancel();
    _morph.dispose();
    _open.dispose();
    _ctrl.dispose();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _keyboardFocus.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchCtrl.clear();
        _query = '';
      }
    });
    // 只有明确点开搜索才弹键盘
    _searchOpen ? _searchFocus.requestFocus() : _searchFocus.unfocus();
  }

  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = v);
    });
  }

  // ---- 筛选谓词(模型 × 时间 × 搜索,全 AND) ----

  bool _passModel(ResultImage r, Map<String, GallerySearchMeta> byId) {
    final want = _modelFilter;
    if (want == null) return true;
    return (byId[r.id]?.model ?? '') == want;
  }

  bool _passQuery(
    ResultImage r,
    Map<String, GallerySearchMeta> byId,
    List<String> terms,
  ) {
    if (terms.isEmpty) return true;
    final meta = byId[r.id];
    if (widget.desktop || widget.browser != null) {
      return searchMatch(
        normalizeSearchText(
          '${r.id} ${r.seed} ${meta?.text ?? r.input?.prompt ?? ''}',
        ),
        terms,
      );
    }
    return meta != null && searchMatch(meta.text, terms);
  }

  /// 单选弹层(模型/分组共用):选项 = (文案, 值, 计数);值用单元素 record
  /// 包一层再 pop,可空的 T(全部=null)才与「取消」区分得开。
  Future<void> _pickFilter<T>({
    required String title,
    required List<(String, T, int?)> options,
    required T current,
    required ValueChanged<T> onPick,
    required GlobalKey anchor,
  }) async {
    final scheme = context.scheme;
    // 弹层关闭后焦点会回落到搜索框(它一直在树里),不先收就会顺带弹出键盘
    _searchFocus.unfocus();
    if (widget.desktop) {
      final picked = await showMenu<(T,)>(
        context: context,
        position: _filterPosition(anchor),
        semanticLabel: title,
        constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
        items: [
          for (final (label, value, count) in options)
            PopupMenuItem(
              value: (value,),
              child: Row(
                children: [
                  Expanded(child: Text(label)),
                  const SizedBox(width: 12),
                  if (value == current)
                    Icon(Icons.check, size: 18, color: scheme.primary)
                  else if (count != null)
                    Text('$count', style: context.texts.bodySmall),
                ],
              ),
            ),
        ],
      );
      if (picked != null && mounted) onPick(picked.$1);
      return;
    }
    final picked = await _showFilter<(T,)>(
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Row(
                  children: [
                    Text(
                      title,
                      style: context.texts.titleMedium!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              for (final (label, value, count) in options)
                ListTile(
                  dense: true,
                  onTap: () => Navigator.pop(ctx, (value,)),
                  title: Text(label, style: context.texts.bodyMedium),
                  trailing: value == current
                      ? Icon(Icons.check, size: 18, color: scheme.primary)
                      : (count == null
                            ? null
                            : Text(
                                '$count',
                                style: mono(
                                  context,
                                  size: 12,
                                  color: scheme.outline,
                                ),
                              )),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) onPick(picked.$1);
  }

  RelativeRect _filterPosition(GlobalKey anchor) {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final button = anchor.currentContext!.findRenderObject() as RenderBox;
    final origin = button.localToGlobal(Offset.zero, ancestor: overlay);
    return RelativeRect.fromRect(
      Rect.fromLTWH(
        origin.dx,
        origin.dy + button.size.height + 4,
        button.size.width,
        0,
      ),
      Offset.zero & overlay.size,
    );
  }

  Future<T?> _showFilter<T>({required WidgetBuilder builder}) {
    final constraints = BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .85,
    );
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      constraints: constraints,
      builder: builder,
    );
  }

  void _pickModelFilter(
    List<ResultImage> results,
    Map<String, GallerySearchMeta> byId,
  ) {
    // 模型清单按整库统计(不按筛选后,免得选中一个后其余选项全消失)
    final counts = <String, int>{};
    for (final r in results) {
      counts.update(byId[r.id]?.model ?? '', (v) => v + 1, ifAbsent: () => 1);
    }
    final models = [
      for (final k in counts.keys)
        if (k.isNotEmpty) k,
    ]..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    _pickFilter<String?>(
      title: '按模型筛选',
      anchor: _modelAnchor,
      current: _modelFilter,
      options: [
        ('全部', null, null),
        for (final m in models) (m, m, counts[m]),
        if ((counts[''] ?? 0) > 0) ('未知', '', counts['']),
      ],
      onPick: (v) => setState(() => _modelFilter = v),
    );
  }

  Future<void> _pickTimeFilter() async {
    _searchFocus.unfocus();
    final filter = await showGalleryDateFilter(
      context,
      _dateFilter,
      desktop: widget.desktop,
      menuPosition: widget.desktop ? _filterPosition(_dateAnchor) : null,
    );
    if (filter == null || !mounted) return;
    ref
        .read(uiPrefsProvider.notifier)
        .patch(
          (p) => p.copyWith(
            galleryDateFilter: filter,
            galleryGroupBy: GalleryGroupBy.day.name,
          ),
        );
    // 日期入口同时负责回到按天排列；取消日历时不改变原筛选或分组。
    setState(() {
      _dateFilter = filter;
      _groupBy = GalleryGroupBy.day;
      _openKey = null;
    });
  }

  void _clearFilters() {
    _searchDebounce?.cancel();
    _searchCtrl.clear();
    ref
        .read(uiPrefsProvider.notifier)
        .patch(
          (p) => p.copyWith(galleryDateFilter: const GalleryDateFilter.all()),
        );
    setState(() {
      _query = '';
      _modelFilter = null;
      _favoritesOnly = false;
      _dateFilter = const GalleryDateFilter.all();
    });
  }

  Future<void> _organizePicked() async {
    if (_organizing) return;
    setState(() => _organizing = true);
    final notifier = ref.read(albumsProvider.notifier);
    try {
      final change = await showAlbumOrganize(
        context,
        Set.of(_picked),
        sourceAlbum: _scope,
      );
      if (change == null || !mounted) return;
      _picked.clear();
      // 历史本身是 modal route，Scaffold 的 SnackBar 会被它挡住。
      // 复用根 Overlay 提示，让撤销在历史保持打开时仍能点击。
      hintSnack(
        context,
        '已整理 ${change.count} 张',
        icon: Icons.photo_library_outlined,
        actionLabel: change.count == 0 ? null : '撤销',
        onAction: change.count == 0
            ? null
            : () async {
                try {
                  await notifier.undo(change);
                } catch (e) {
                  if (mounted) albumError(context, e);
                }
              },
      );
    } finally {
      if (mounted) setState(() => _organizing = false);
    }
  }

  Future<void> _transferPicked({required bool copy, Set<String>? only}) async {
    if (_organizing) return;
    setState(() => _organizing = true);
    try {
      final change = await showGalleryTransfer(
        context,
        Set.of(only ?? _picked),
        copy: copy,
        sourceAlbum: _scope,
      );
      if (change != null && mounted && only == null) _picked.clear();
    } finally {
      if (mounted) setState(() => _organizing = false);
    }
  }

  void _pickGroupBy() {
    // 不带计数:算另外两个维度的归属要把它们的 provider 都拉起来,而用户只是
    // 想换个分组。归不了的有多少,封面墙上那堆「未归类」自己会说。
    _pickFilter<GalleryGroupBy>(
      title: '分组方式',
      anchor: _groupAnchor,
      current: _groupBy,
      options: [
        ('不分组', GalleryGroupBy.day, null),
        for (final v in [GalleryGroupBy.character, GalleryGroupBy.style])
          (v.label, v, null),
      ],
      onPick: (v) {
        ref
            .read(uiPrefsProvider.notifier)
            .patch((p) => p.copyWith(galleryGroupBy: v.name));
        setState(() {
          _groupBy = v;
          _openKey = null; // 换了维度,原来点开的那一堆不存在了
        });
      },
    );
  }

  Widget _chip(
    ColorScheme scheme, {
    Key? key,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    final fg = active ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Material(
      key: key,
      color: active ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 7, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: context.texts.bodySmall!.copyWith(
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.arrow_drop_down, size: 18, color: fg),
            ],
          ),
        ),
      ),
    );
  }

  Widget _desktopFilters(
    List<ResultImage> results,
    GallerySearchState search,
    DateTime now,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
    child: LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: math.min(440, constraints.maxWidth),
            child: TextField(
              key: ValueKey(
                widget.browser == null
                    ? 'quick-gallery-search'
                    : 'desktop-gallery-search',
              ),
              controller: _searchCtrl,
              focusNode: _searchFocus,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: '搜索提示词、种子或图片编号…',
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除搜索',
                        onPressed: () {
                          _searchCtrl.clear();
                          _onSearchChanged('');
                        },
                        icon: const Icon(Icons.close, size: 18),
                      ),
              ),
            ),
          ),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                key: _dateAnchor,
                child: OutlinedButton.icon(
                  key: const ValueKey('desktop-gallery-date'),
                  onPressed: _pickTimeFilter,
                  icon: const Icon(Icons.calendar_month_outlined, size: 18),
                  label: Text(
                    _dateFilter.active ? _dateFilter.label(now) : '全部时间',
                  ),
                ),
              ),
              const GalleryOutputFolderButton(),
            ],
          ),
          if (widget.browser == null)
            _chip(
              context.scheme,
              key: const ValueKey('quick-gallery-library'),
              label: '切换图库',
              active: _scope != null,
              onTap: _chooseAlbum,
            ),
          _chip(
            context.scheme,
            key: _groupAnchor,
            label: _groupBy.stacked ? _groupBy.label : '分组',
            active: _groupBy.stacked,
            onTap: _pickGroupBy,
          ),
          _chip(
            context.scheme,
            key: _modelAnchor,
            label: _modelFilter == null
                ? '模型'
                : (_modelFilter!.isEmpty ? '未知' : _modelFilter!),
            active: _modelFilter != null,
            onTap: () => _pickModelFilter(results, search.byId),
          ),
          FilterChip(
            key: const ValueKey('gallery-favorites-filter'),
            avatar: Icon(
              _favoritesOnly ? Icons.star : Icons.star_border,
              size: 18,
              color: _favoritesOnly ? Colors.amber.shade800 : null,
            ),
            label: const Text('收藏'),
            selected: _favoritesOnly,
            showCheckmark: false,
            onSelected: (value) {
              _dragSelectionKey.currentState?.cancel();
              setState(() => _favoritesOnly = value);
            },
          ),
          if (search.building)
            Text(
              '索引 ${search.done}/${search.total}',
              style: context.texts.bodySmall,
            ),
        ],
      ),
    ),
  );

  void _chooseAlbum() {
    final choose = widget.onChooseAlbum;
    if (choose != null) {
      choose(context, ref);
    } else {
      showAlbumLibrary(context);
    }
  }

  /// 一段图的网格 sliver。分段列表与点开的单堆共用 —— 两边的交互(点选回填、
  /// 长按菜单、拖选的 MetaData 反查)必须逐条一致,写两遍迟早走岔。
  ///
  /// 缩略图本体还各带 5(描边 2.5 + 让位 2.5)的内缩,所以图与图之间实际留白 =
  /// 这里的 spacing + 10。收到 6 之后是 16,省下的宽度全给图。
  Widget _gridSliver(
    List<ResultImage> items,
    String? selectedId,
    List<ResultImage> viewing,
  ) => SliverPadding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
    sliver: SliverLayoutBuilder(
      builder: (_, constraints) => SliverGrid(
        gridDelegate: _zoomDelegate(
          (cols) => SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          width: constraints.crossAxisExtent,
        ),
        delegate: SliverChildBuilderDelegate((_, i) {
          final r = items[i];
          // Shared range selection resolves each tile through this ID.
          return MetaData(
            metaData: r.id,
            child: GalleryImageTile(
              key: ValueKey(
                '${widget.browser == null ? 'quick-gallery-image' : 'desktop-image'}-${r.id}',
              ),
              fit: widget.desktop ? BoxFit.contain : BoxFit.cover,
              result: r,
              selected: !_selecting && r.id == selectedId,
              picked: _selecting && _picked.contains(r.id),
              selecting: _selecting,
              mouseDragSelect: widget.desktop || widget.browser != null,
              onFavorite: widget.desktop
                  ? () =>
                        ref.read(galleryProvider.notifier).toggleFavorite(r.id)
                  : null,
              onTap: () {
                if (_selecting) {
                  _toggle(r.id);
                } else if (widget.browser != null) {
                  widget.browser!.onOpenImage(
                    viewing,
                    viewing.indexWhere((image) => image.id == r.id),
                  );
                } else {
                  if (widget.desktop) {
                    ref.read(generationProvider.notifier).select(null);
                    ref.read(galleryResultPreviewProvider.notifier).clear();
                  }
                  ref.read(galleryProvider.notifier).select(r.id);
                  _close();
                }
              },
              longPressDuration: widget.desktop || widget.browser != null
                  ? gallerySelectionHold
                  : const Duration(milliseconds: 500),
              onLongPress: _pinching
                  ? null
                  : widget.desktop || widget.browser != null
                  ? (_) {
                      if (_pinching) return;
                      setState(() => _selecting = true);
                      if (!(_dragSelectionKey.currentState?.beginHold(r.id) ??
                          false)) {
                        _enterSelect(r.id);
                      }
                    }
                  : _selecting
                  ? null
                  : (from) => _thumbMenu(r.id, from),
              // Right click keeps the existing per-image menu and never
              // enters selection. Touch holds and primary mouse drags select.
              onSecondaryTap: _selecting || _pinching
                  ? null
                  : (from) => _thumbMenu(r.id, from),
            ),
          );
        }, childCount: items.length),
      ),
    ),
  );

  /// 堆的封面墙:一堆一张卡。点一下进那一堆;多选态下点一下整堆全勾/全取消
  /// —— 封面墙这一层的「一个单位」就是一整堆,按单张勾在这里没有落点。
  Widget _stackSliver(ColorScheme scheme, List<GalleryGroup> groups) {
    // 封面是方的,底下还得放名字与张数两行 —— 那两行是**固定高**,不该跟着格宽缩,
    // 所以主轴高按「格宽 + 文字高」现算,而不是钉一个 childAspectRatio。
    // (钉比例的话,列数一多文字就被压没;跟着字号缩放走同理。)
    //
    // 宽度取 SliverConstraints.crossAxisExtent,不取屏宽 —— 弹层宽度未必等于屏宽
    // (主题给 bottomSheet 设了 constraints、或大屏上就会不等)。
    const pad = 12.0 * 2, gap = 6.0;
    final textH = 44 * MediaQuery.textScalerOf(context).scale(1);
    return SliverLayoutBuilder(
      builder: (_, cons) => SliverPadding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        sliver: SliverGrid(
          gridDelegate: _zoomDelegate((cols) {
            final cellW =
                (cons.crossAxisExtent - pad - gap * (cols - 1)) / cols;
            return SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 12,
              crossAxisSpacing: gap,
              mainAxisExtent: cellW + textH,
            );
          }, width: cons.crossAxisExtent - pad),
          delegate: SliverChildBuilderDelegate((_, i) {
            final g = groups[i];
            final ids = [for (final r in g.items) r.id];
            final allOn = ids.every(_picked.contains);
            return _GroupCard(
              key: ValueKey('group-card-${g.key}'),
              group: g,
              selecting: _selecting,
              picked: _selecting && allOn,
              onTap: () => setState(() {
                if (_selecting) {
                  allOn ? _picked.removeAll(ids) : _picked.addAll(ids);
                } else {
                  _setOpen(g.key);
                }
              }),
              onLongPress: widget.desktop && !_pinching
                  ? () => setState(() {
                      _selecting = true;
                      _picked.addAll(ids);
                    })
                  : null,
            );
          }, childCount: groups.length),
        ),
      ),
    );
  }

  /// 分段段头:组名 + 张数;多选态尾部整段全选/取消。
  ///
  /// 「全选」**叠**在段头上,不排进那一行:按钮再紧凑也有 32 高(默认点按区还要
  /// 撑到 40),排进去会把每个段头撑高一截 —— 一进多选,视口上方那些段头一齐
  /// 变高,整片网格就被往下推一段。叠上去之后段头在两种状态下一样高,点按区
  /// 照样竖着占满段头。
  Widget _groupHeader(ColorScheme scheme, GalleryGroup g) {
    final ids = [for (final r in g.items) r.id];
    final allOn = ids.every(_picked.contains);
    return Stack(
      children: [
        Padding(
          // 跟着网格一起往里收 4:段头文字要和其下第一张图的左边缘对齐
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 6),
          child: Row(
            children: [
              Text(
                g.label,
                style: context.texts.titleSmall!.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                '${g.items.length} 张',
                style: context.texts.bodySmall!.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (_selecting)
          Positioned(
            right: 8,
            // 段头上留白 8、下留白 6:按钮顶端让出多的那 2,中线才和组名那行对齐
            top: 2,
            bottom: 0,
            child: TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _saving || _zipping
                  ? null
                  : () => setState(
                      () =>
                          allOn ? _picked.removeAll(ids) : _picked.addAll(ids),
                    ),
              child: Text(allOn ? '取消' : '全选'),
            ),
          ),
      ],
    );
  }

  void _enterSelect([String? pick]) {
    setState(() {
      _selecting = true;
      if (pick != null) _picked.add(pick);
    });
  }

  void _exitSelect() {
    _dragSelectionKey.currentState?.cancel();
    setState(() {
      _selecting = false;
      _picked.clear();
    });
  }

  KeyEventResult _onDesktopKey(FocusNode node, KeyEvent event) {
    if (!widget.desktop ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      if (_selecting) {
        _exitSelect();
      } else {
        _dragSelectionKey.currentState?.cancel();
      }
    }
    // Escape exits selection only. Ordinary browsing keeps its page/dialog,
    // while dialogs above this route retain their own Escape handling.
    return KeyEventResult.handled;
  }

  void _toggle(String id) {
    setState(() => _picked.contains(id) ? _picked.remove(id) : _picked.add(id));
  }

  final _dragSelectionKey = GlobalKey<GalleryDragSelectionState>();

  /// Visible image order across date sections or within the opened group.
  List<String> _order = const [];

  double get _span {
    final p = _pointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  Offset get _mid {
    final p = _pointers.values.toList();
    return (p[0] + p[1]) / 2;
  }

  /// 双指按住中。此时列表换 [_FrozenScrollPhysics]:不滚,但仍参与手势竞技场。
  bool get _pinching => _pointers.length >= 2;

  void _persistCols() {
    if (_cols == ref.read(uiPrefsProvider).galleryColumns) return;
    ref
        .read(uiPrefsProvider.notifier)
        .patch((p) => p.copyWith(galleryColumns: _cols));
  }

  /// 记下锚点:触发那一刻焦点落在**内容**里的相对位置。
  void _takeAnchor() {
    final box = _bodyKey.currentContext?.findRenderObject() as RenderBox?;
    _focalY = box == null || _pointers.length < 2
        ? 0
        : box.globalToLocal(_mid).dy;
    if (!_ctrl.hasClients) {
      _anchorOff = _anchorContent = 0;
      return;
    }
    final pos = _ctrl.position;
    _anchorOff = pos.pixels;
    _anchorContent = pos.maxScrollExtent + pos.viewportDimension;
  }

  /// 按锚点回正滚动位置。**必须在布局之后跑**(见下)。
  ///
  /// 列数一变内容总高就变,而 ScrollPosition 只认像素 —— 不回正的话,焦点上方
  /// 的内容长高/缩矮多少,画面就整体漂多少。这里保持**焦点在内容里的比例**不变。
  ///
  /// 内容总高取实测(`maxScrollExtent + viewportDimension`),不按列数推算:
  /// 三种视图(分段列表带段头、封面墙、单堆)的高度构成各不一样,推不准。
  ///
  /// ⚠ 放在指针事件 / 动画 tick 里算是**错的**,而且是会抖的那种错:那时拿到的
  /// 总高还是上一帧的(布局还没跟着新进度跑),按它算出的像素又会成为下一帧布局
  /// 的输入 —— 一来一回构成反馈环,整片网格每帧上下弹。放在帧后就没有环:总高与
  /// 当前进度对得上,跳完只改像素不改总高,下一次算出来就等于当前值,一帧收敛。
  void _reanchor() {
    if (_anchorContent <= 0 || !_ctrl.hasClients) return;
    final pos = _ctrl.position;
    final content = pos.maxScrollExtent + pos.viewportDimension;
    if (content <= 0) return;
    final want = ((_anchorOff + _focalY) * content / _anchorContent - _focalY)
        .clamp(0.0, pos.maxScrollExtent);
    if ((want - pos.pixels).abs() > 1.5) _ctrl.jumpTo(want);
  }

  bool _reanchorQueued = false;

  void _reanchorAfterLayout() {
    if (_reanchorQueued) return;
    _reanchorQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reanchorQueued = false;
      if (mounted) _reanchor();
    });
  }

  /// 起一次换档过渡。上一档还没跑完就先把它落定,再从新的一级起步 ——
  /// 一路捏下去时不会两段过渡叠在一起。
  void _startMorph(int to) {
    if (_morph.isAnimating) _endMorph();
    _takeAnchor();
    setState(() {
      _toCols = to;
      _t = 0;
    });
    Haptics.selection();
    _morph.forward(from: 0);
  }

  void _pinchDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length != 2) return;
    _span0 = _span;
    _dragSelectionKey.currentState?.cancel(); // 拖选可能已经起手了,清掉半截状态
    setState(() {}); // 进入捏合:冻结滚动、停拖选与长按
  }

  void _pinchMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    final s0 = _span0;
    if (_pointers.length != 2 || s0 == null || s0 < 1) return;

    final r = _span / s0;
    if (r < _kZoomIn && r > _kZoomOut) return; // 没到阈值,什么都不做
    // 重取基准:再捏同样的幅度就是下一档。到头时也要重取,否则会一直卡在
    // 阈值以外,手指一抖就反复触发。
    _span0 = _span;

    // 撑开 = 图变大 = 列变少
    final want = (r >= 1 ? _cols - 1 : _cols + 1).clamp(
      kGalleryMinColumns,
      kGalleryMaxColumns,
    );
    if (want == _cols) return; // 到头了
    _startMorph(want);
  }

  void _pinchUp(PointerEvent e) {
    final was = _pinching;
    _pointers.remove(e.pointer);
    if (!was) return;
    if (_pinching) {
      _span0 = _span; // 三指落回两指:重新取基准,免得拿旧间距算出一次误触发
      return;
    }
    _span0 = null;
    setState(() {}); // 退出捏合:放开滚动
    if (!_morph.isAnimating) _persistCols();
  }

  /// 进出堆的过场层。不在过场中就原样递出去 —— 常态下的滚动路径上一层都不加。
  Widget _openLayer(Widget child) {
    if (!_open.isAnimating) return child;
    final v = _open.value;
    final fading = v < _kFadeOut;
    final t = fading ? 1 - v / _kFadeOut : (v - _kFadeOut) / (1 - _kFadeOut);
    return IgnorePointer(
      child: Opacity(
        opacity: (fading ? t : Curves.easeIn.transform(t)).clamp(0.0, 1.0),
        // 淡出的那一半不缩放:旧内容要走干净,再动一下只是噪音
        child: fading
            ? child
            : Transform.scale(
                scale: .94 + .06 * Motion.emphasized.transform(t),
                child: child,
              ),
      ),
    );
  }

  /// 网格几何的插值代理:没在两级之间就用当前列数的普通代理,不绕路。
  SliverGridDelegate _zoomDelegate(
    SliverGridDelegate Function(int cols) of, {
    double? width,
  }) {
    final to = _toCols;
    if (widget.desktop) {
      return of(
        ((width ?? math.min(1160, MediaQuery.sizeOf(context).width - 64) - 24) /
                190)
            .floor()
            .clamp(2, widget.browser == null ? 8 : 12),
      );
    }
    if (widget.embedded) {
      return of(
        ((MediaQuery.sizeOf(context).width - 24) / 210).floor().clamp(3, 12),
      );
    }
    if (to == null || _t <= 0) return of(_cols);
    return _ZoomGridDelegate(of, _cols, to, _t);
  }

  Widget _pinchLayer({required Widget child}) => Listener(
    // 几何取这一层:缩放锚点要按它的局部坐标算
    key: _bodyKey,
    onPointerDown: _pinchDown,
    onPointerMove: _pinchMove,
    onPointerUp: _pinchUp,
    onPointerCancel: _pinchUp,
    child: child,
  );

  /// 给网格套上拖选手势。非多选态传 null 处理器 —— 手势识别器不参与竞技场,
  /// 横滑照常落到下层(将来要加横滑手势也不会被这层截胡)。
  ///
  /// 捏合期间同样传 null:Listener 不进竞技场,双指横向张开在多选态下会被
  /// 拖选当成一次划选,一捏就勾中一排。
  Widget _dragSelectLayer({required Widget child}) {
    return GalleryDragSelection(
      key: _dragSelectionKey,
      enabled: _selecting && !_pinching,
      handleEscape: !widget.desktop,
      scrollController: _ctrl,
      order: _order,
      selected: _picked,
      onChanged: (selected) => setState(() {
        _picked
          ..clear()
          ..addAll(selected);
      }),
      child: child,
    );
  }

  void _toggleAll(List<ResultImage> results) {
    setState(() {
      if (_picked.length == results.length) {
        _picked.clear();
      } else {
        _picked
          ..clear()
          ..addAll([for (final r in results) r.id]);
      }
    });
  }

  /// 批量保存:按生成时间从旧到新，逐张处理并等待写入后再存下一张;逐张计数,
  /// 中途关闭弹层即中止(已存的保留)。
  /// [album] 非空 = 存进该手机相册(按需创建 `Pictures/<album>/`)。
  /// [only] 非空 = 只存这些(长按菜单的单张保存借道同一条管线,
  /// 权限申请、保存设置、失败计数一条都不用重写)。
  Future<void> _downloadPicked({String? album, Set<String>? only}) async {
    final want = only ?? _picked;
    final items = oldestFirstForSave([
      for (final r in ref.read(galleryProvider).results)
        if (want.contains(r.id)) r,
    ]);
    if (items.isEmpty) return;
    if (widget.desktop) {
      await _exportDesktop(items);
      return;
    }
    // 写自建相册**以外**的相册要额外权限位,按目标申请
    final toAlbum = album != null;
    final ok =
        await Gal.hasAccess(toAlbum: toAlbum) ||
        await Gal.requestAccess(toAlbum: toAlbum);
    if (!mounted) return;
    if (!ok) {
      hintSnack(context, '未获相册权限', icon: Icons.error_outline);
      return;
    }
    final settings = await ref.read(saveSettingsProvider.future);
    if (!mounted) return;
    final store = ref.read(appStoresProvider).gallery;
    setState(() {
      _saving = true;
      _saveDone = 0;
      _saveTotal = items.length;
    });
    var saved = 0, failed = 0;
    for (final r in items) {
      if (!mounted) return; // 弹层已关:中止剩余
      try {
        final bytes = r.bytes ?? await store.readImage(r.id);
        if (bytes == null) {
          failed++;
        } else {
          final out = await processForSave(bytes, settings);
          await saveProcessedImageToPhone(
            out,
            image: r,
            format: settings.format,
            album: album,
          );
          saved++;
        }
      } catch (_) {
        failed++;
      }
      if (mounted) setState(() => _saveDone = saved + failed);
    }
    // 存成过才记进"最近用过"(全失败的名字记下来只会碍事)
    if (album != null && saved > 0) {
      await ref
          .read(saveSettingsProvider.notifier)
          .patch((s) => s.withAlbumUsed(album));
    }
    if (!mounted) return;
    setState(() => _saving = false);
    final where = album == null ? '相册' : '「$album」';
    hintSnack(
      context,
      failed == 0 ? '已保存 $saved 张到$where' : '保存 $saved 张到$where,失败 $failed 张',
      icon: failed == 0 ? Icons.check_circle_outline : Icons.error_outline,
    );
  }

  Future<void> _exportDesktop(List<ResultImage> items) async {
    if (_saving) return;
    final albumId = _scope;
    final albums = ref.read(albumsProvider);
    final albumName =
        albums.album(albumId)?.name ??
        (isDailyAlbum(albumId) ? albumId!.substring(4) : albums.name(albumId));
    setState(() {
      _saving = true;
      _saveDone = 0;
      _saveTotal = items.length;
    });
    try {
      final report = await showGalleryExportDialog(
        context,
        selected: items,
        albumId: albumId,
        albumName: albumName,
      );
      if (mounted &&
          report != null &&
          !ref.read(albumsProvider).exists(albumId)) {
        widget.browser?.onBack();
      }
    } catch (error) {
      if (mounted) hintSnack(context, '导出失败：$error', icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 保存到自定义相册:先问名字,再走同一条保存管线。
  Future<void> _downloadToAlbum() async {
    final settings = await ref.read(saveSettingsProvider.future);
    if (!mounted) return;
    final name = await showAlbumNameSheet(
      context,
      recent: settings.recentAlbums,
      count: _picked.length,
    );
    if (name == null || !mounted) return;
    await _downloadPicked(album: name);
  }

  /// 打包 ZIP:弹层里定包名、按需设密码,就地打包(进度条也在那张弹层里),
  /// 打完交给系统保存对话框让用户挑落点([saveFileAs],包再大也不整份进内存)。
  ///
  /// **不进相册** —— zip 不是图片,Gal 收不了;而且「一次拿走几十张」这件事
  /// 本来就更像存进文件管理器 / 网盘,而不是散进相机胶卷里。
  Future<void> _zipPicked() async {
    final items = [
      for (final r in ref.read(galleryProvider).results)
        if (_picked.contains(r.id)) r,
    ];
    if (items.isEmpty) return;
    final settings = await ref.read(saveSettingsProvider.future);
    if (!mounted) return;
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    setState(() => _zipping = true);
    try {
      final packed = await showZipPackSheet(
        context,
        desktop: widget.desktop,
        items: items,
        store: ref.read(appStoresProvider).gallery,
        settings: settings,
        defaultName:
            'plana-${now.year}${two(now.month)}${two(now.day)}'
            '-${two(now.hour)}${two(now.minute)}',
      );
      if (packed == null || !mounted) return; // 取消:不报也不留
      final zip = packed.file;
      if (zip == null) {
        hintSnack(context, '打包失败', icon: Icons.error_outline);
        return;
      }
      // 只交路径,由原生侧边读边写(见 saveFileAs)—— 包再大也不整份进内存。
      // 存完、取消、失败,缓存里这份都没用了。
      final String? path;
      try {
        path = await saveFileAs(
          zip,
          fileName: packed.fileName,
          mime: 'application/zip',
        );
      } finally {
        try {
          await zip.delete();
        } catch (_) {}
      }
      if (path == null || !mounted) return; // 取消:不报也不留
      hintSnack(
        context,
        packed.failed == 0
            ? '已打包 ${packed.packed} 张'
            : '已打包 ${packed.packed} 张,失败 ${packed.failed} 张',
        icon: packed.failed == 0
            ? Icons.check_circle_outline
            : Icons.error_outline,
      );
    } on PlatformException catch (e) {
      // 原生侧写盘失败(盘满等):message 是原因,整串 PlatformException(...) 没法看
      if (mounted) {
        hintSnack(
          context,
          '保存失败:${e.message ?? e.code}',
          icon: Icons.error_outline,
        );
      }
    } catch (e) {
      if (mounted) hintSnack(context, '保存失败:$e', icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _zipping = false);
    }
  }

  /// 长按缩略图:压暗背景,把按住的那张从原位放大浮起,菜单紧贴在它下面。
  ///
  /// 之前是 showMenu 锚在手指坐标上 —— 图本身一点变化都没有,菜单跟哪张图
  /// 有关全靠猜。指向感只能由**图自己动**来给,锚点给不了。
  Future<void> _thumbMenu(String id, Rect from) async {
    final r = _resultOf(id);
    if (r == null) return;
    Haptics.medium();
    // 先把原图读出来**并解码**,再开抬起层。只读不解码不够:Image.memory
    // 拿到字节还要一两帧才落笔,那一两帧照样露出底下垫着的缩略图 ——
    // 看着就是「先糊一下再变清」。
    final warm = await _warmFull(r).timeout(
      const Duration(milliseconds: 300),
      onTimeout: () => null, // 读得慢就先抬起来,手势不能被读盘卡住
    );
    if (!mounted) return;
    final nav = Navigator.of(context);
    // 缩略图报的是屏幕坐标,路由画在 overlay 里 —— 有嵌套导航时两者不重合
    final box = nav.overlay?.context.findRenderObject() as RenderBox?;
    final at = box == null ? from : box.globalToLocal(from.topLeft) & from.size;
    final picked = await nav.push(
      _ThumbMenuRoute(from: at, result: r, warm: warm, desktop: widget.desktop),
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case 'import':
        await _importOne(id);
      case 'save':
        await _downloadPicked(only: {id});
      case 'share':
        await _sharePicked(only: {id});
      case 'move':
        await _transferPicked(copy: false, only: {id});
      case 'copy':
        await _transferPicked(copy: true, only: {id});
      case 'delete':
        await _deleteOne(id);
    }
  }

  /// 读原图并预解码。解码结果进 ImageCache,抬起层再画就是同步的。
  /// 用 MemoryImage(不带 cacheWidth)是为了**和画布同一个缓存键** ——
  /// 同一张图两边共用一次解码,而不是各解一张。
  Future<Uint8List?> _warmFull(ResultImage r) async {
    try {
      final bytes =
          r.bytes ?? await ref.read(appStoresProvider).gallery.readImage(r.id);
      if (bytes == null || !mounted) return null;
      await precacheImage(MemoryImage(bytes), context);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  ResultImage? _resultOf(String id) =>
      ref.read(galleryProvider).results.where((e) => e.id == id).firstOrNull;

  /// 导入:这张送进导入面板(解析内嵌元数据 / 用作参考),与画布侧栏同一个面板。
  ///
  /// 先关网格弹层再推面板 —— 面板是整页的,压在弹层上会留一层退不掉的夹心:
  /// 从面板返回时人会以为回到了画布,实际还在弹层里。
  Future<void> _importOne(String id) async {
    final origin = ref.read(albumsProvider.notifier).origin(id);
    final r = ref
        .read(galleryProvider)
        .results
        .where((e) => e.id == id)
        .firstOrNull;
    if (r == null) return;
    final bytes =
        r.bytes ?? await ref.read(appStoresProvider).gallery.readImage(id);
    if (!mounted) return;
    if (bytes == null) {
      hintSnack(context, '图片尚未就绪', icon: Icons.hourglass_empty);
      return;
    }
    final nav = Navigator.of(context);
    _close();
    unawaited(
      nav.push(
        sharedAxisRoute(
          ImportImagePanel(
            origin: origin,
            bytes: bytes,
            fileName: 'plana_${r.seed}.png',
            displayName: 'plana_${r.seed}',
          ),
        ),
      ),
    );
  }

  /// 分享:按保存设置处理后落进缓存,交给系统分享面板(管线见
  /// [prepareShareFiles],胶片条的上滑分享也走那条)。
  /// [only] 指定就只分享这几张(长按菜单那条单张的路),否则分享多选选中的。
  Future<void> _sharePicked({Set<String>? only}) async {
    final want = only ?? _picked;
    final items = [
      for (final r in ref.read(galleryProvider).results)
        if (want.contains(r.id)) r,
    ];
    if (items.isEmpty) return;
    final settings = await ref.read(saveSettingsProvider.future);
    if (!mounted) return;
    setState(() {
      _sharing = true;
      _saveDone = 0;
      _saveTotal = items.length;
    });
    final prep = await prepareShareFiles(
      items,
      store: ref.read(appStoresProvider).gallery,
      settings: settings,
      onEach: (done) {
        if (!mounted) return false; // 弹层已关:中止剩余
        setState(() => _saveDone = done);
        return true;
      },
    );
    if (!mounted) return;
    setState(() => _sharing = false);
    if (prep.files.isEmpty) {
      hintSnack(context, '没有可分享的图片', icon: Icons.error_outline);
      return;
    }
    await SharePlus.instance.share(ShareParams(files: prep.files));
    if (prep.failed > 0 && mounted) {
      hintSnack(context, '${prep.failed} 张读不出来,已跳过', icon: Icons.error_outline);
    }
  }

  /// 单张删除(长按菜单里那项)。**不再二次确认** —— 长按抬起、看清是哪张、
  /// 再点删除,本身已是三步;弹窗只是给这条路再加一次点击。
  /// 批量删除那条仍然确认:一次十几张,误触代价不在一个量级。
  Future<void> _deleteOne(String id) async {
    final deleted = await ref.read(galleryProvider.notifier).deleteResults([
      id,
    ]);
    if (!mounted) return;
    if (!widget.embedded && ref.read(galleryProvider).results.isEmpty) {
      _close(); // 删空了,弹层没得看
      return;
    }
    hintSnack(
      context,
      deleted.contains(id) ? '已删除' : '未能删除，请稍后重试',
      icon: Icons.delete_outline,
    );
  }

  Future<void> _deletePicked() async {
    final ids = _picked.toList();
    if (ids.isEmpty) return;
    final scheme = context.scheme;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('删除 ${ids.length} 张作品?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final deleted = await ref.read(galleryProvider.notifier).deleteResults(ids);
    if (!mounted) return;
    _exitSelect();
    if (!widget.embedded && ref.read(galleryProvider).results.isEmpty) {
      _close(); // 删空了,弹层没得看
    }
    hintSnack(
      context,
      '已删除 ${deleted.length} 张${deleted.length < ids.length ? '，其余图片已保留' : ''}',
      icon: Icons.delete_outline,
    );
  }

  @override
  Widget build(BuildContext context) {
    final browser = widget.browser;
    final state = browser == null
        ? ref.watch(galleryViewProvider)
        : ref.watch(galleryProvider);
    final scope = browser != null
        ? browser.albumId
        : ref.watch(galleryBrowseAlbumProvider);
    final albums = ref.watch(albumsProvider);
    final now = DateTime.now();
    if (_scopeKey != (scope ?? '')) {
      _scopeKey = scope ?? '';
      _query = '';
      _searchCtrl.clear();
      _searchDebounce?.cancel();
      _modelFilter = null;
      _picked.clear();
      _selecting = false;
      _openKey = null;
      _wallOffset = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _ctrl.hasClients) _ctrl.jumpTo(0);
      });
    }
    final results = browser == null || scope == null
        ? state.results
        : state.results.where((r) => albums.contains(scope, r.id)).toList();
    final search = ref.watch(gallerySearchProvider);

    // 筛选管线(先廉价的时间,再查表)
    final terms = searchTerms(_query);
    final filtered = <ResultImage>[
      for (final r in results)
        if ((!_favoritesOnly || r.favorite) &&
            _dateFilter.matches(r.createdAt, now) &&
            _passModel(r, search.byId) &&
            _passQuery(r, search.byId, terms))
          r,
    ];
    final filtering =
        _query.isNotEmpty ||
        _modelFilter != null ||
        _dateFilter.active ||
        _favoritesOnly;

    // 归属表只拉当前这个维度的 —— 另一个维度的 provider 不 watch 就不开算。
    // 还在算(冷启第一次点开)时先当空表:全落「未归类」,算完自然刷成正确的堆,
    // 不拿一个转圈把整页挡住。
    final tags = switch (_groupBy) {
      GalleryGroupBy.character => ref.watch(galleryCharTagsProvider),
      GalleryGroupBy.style => ref.watch(galleryStyleTagsProvider),
      GalleryGroupBy.day => const AsyncValue<Map<String, List<GroupTag>>>.data(
        {},
      ),
    };
    // 只有从没算出过结果时才提示。增量重算(每出一张新图)也会 isLoading 一帧,
    // 那一下闪字纯属噪音 —— 旧结果还在,画面根本没变。
    final grouping = tags.isLoading && !tags.hasValue;
    final groups = _groupBy.stacked
        ? groupByTags(filtered, tags.value ?? const {})
        : groupByDay(filtered, DateTime.now());

    // 点开的那一堆:筛选变了/图删了可能已经不在,不在就自动退回封面墙
    final open = _openKey == null
        ? null
        : groups.where((g) => g.key == _openKey).firstOrNull;
    // Selection follows both the active filters and the opened group. The
    // Select all action must not include images hidden in other groups.
    final selectable = open?.items ?? filtered;
    final visible = {for (final r in selectable) r.id};
    _picked.removeWhere((id) => !visible.contains(id));
    final viewing = open?.items ?? [for (final group in groups) ...group.items];
    _inStack = open != null;
    _order = [
      if (open != null)
        for (final r in open.items) r.id
      else if (!_groupBy.stacked)
        for (final g in groups)
          for (final r in g.items) r.id,
    ];

    final scheme = context.scheme;
    final h = MediaQuery.of(context).size.height * 0.82;
    final canAct =
        _picked.isNotEmpty &&
        !_saving &&
        !_sharing &&
        !_zipping &&
        !_organizing;

    final content = PopScope(
      // 多选态下系统返回/侧滑先退多选,不关弹层 —— 勾了十几张再手滑退出,
      // 重新勾一遍的代价比多按一次返回大得多。点开了某一堆时同理,返回先收回
      // 封面墙。两者都没有才照常放行,好让预测式返回该怎么演就怎么演。
      canPop: !_selecting && open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _exitSelect();
        } else if (open != null) {
          _setOpen(null);
        }
      },
      child: SizedBox(
        height: widget.embedded ? null : h,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 8),
              child: SizedBox(
                height: 36,
                child: _selecting
                    ? Row(
                        children: [
                          Text(
                            '已选 ${_picked.length} 张',
                            style: context.texts.titleMedium!.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          _topButton(scheme, hasList: filtered.isNotEmpty),
                          TextButton(
                            style: _headerBtn,
                            onPressed: _saving || _zipping
                                ? null
                                : () => _toggleAll(selectable),
                            child: Text(
                              _picked.length == selectable.length &&
                                      selectable.isNotEmpty
                                  ? '全不选'
                                  : '全选',
                            ),
                          ),
                          TextButton(
                            style: _headerBtn,
                            onPressed: _saving || _zipping ? null : _exitSelect,
                            child: const Text('完成'),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          if (open != null || browser != null)
                            IconButton(
                              key: browser == null
                                  ? null
                                  : const ValueKey('desktop-gallery-up'),
                              // 与系统返回同一条路:过场 + 还原封面墙的位置
                              onPressed: open == null
                                  ? browser!.onBack
                                  : () => _setOpen(null),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              tooltip: open == null ? '返回图库列表' : '回到全部',
                              icon: const Icon(Icons.arrow_back, size: 21),
                            ),
                          if (open != null || browser != null)
                            const SizedBox(width: 8),
                          // 标题 + 张数打包进 Expanded 一起吃掉全部余量。
                          //
                          // 不能写成「Flexible(标题) … Spacer()」:两者都是 flex:1,
                          // 余量按份额对半分,而标题是 loose 的、用不满自己那份,
                          // 没用掉的又不会转给 Spacer —— 于是余量的一半滞留在行尾,
                          // 把尾部按钮往左顶。左边内容越少顶得越狠,所以「全部作品」
                          // 顶得最明显、进了堆或进了多选反而看着贴边。
                          Expanded(
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    open?.label ??
                                        browser?.title ??
                                        widget.libraryLabel ??
                                        (widget.desktop
                                            ? desktopLibraryLabel(
                                                ref.watch(
                                                  desktopLibraryProvider,
                                                ),
                                                albums,
                                              )
                                            : albums.name(scope)),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.texts.titleMedium!.copyWith(
                                      fontWeight: FontWeight.w700,
                                      fontSize: browser == null ? null : 22,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  // 各堆张数之和会大于总数(一张多角色的图进多堆),
                                  // 所以封面墙上报的仍是**去重后**的总数。
                                  open != null
                                      ? '${open.items.length} 张'
                                      : filtering
                                      ? '${filtered.length}/${results.length} 张'
                                      : '${results.length} 张',
                                  style: context.texts.bodySmall!.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _topButton(scheme, hasList: filtered.isNotEmpty),
                          if (browser == null && !widget.desktop)
                            IconButton(
                              onPressed: _toggleSearch,
                              visualDensity: VisualDensity.compact,
                              tooltip: '搜索提示词标签',
                              icon: Icon(
                                Icons.search,
                                size: 21,
                                color: _searchOpen
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          if (browser == null && !widget.desktop)
                            TextButton(
                              style: _headerBtn,
                              onPressed: () => _enterSelect(),
                              child: const Text('多选'),
                            ),
                        ],
                      ),
              ),
            ),
            // 搜索框(点放大镜展开;关闭即清词)
            if (browser == null && !widget.desktop)
              ExpandBody(
                expanded: _searchOpen,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    onChanged: _onSearchChanged,
                    textInputAction: TextInputAction.search,
                    style: context.texts.bodyMedium,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索提示词标签…',
                      prefixIcon: const Icon(Icons.search, size: 19),
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 17),
                              onPressed: () {
                                _searchCtrl.clear();
                                _onSearchChanged('');
                              },
                            ),
                      filled: true,
                      fillColor: scheme.surfaceContainerHigh,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
            // 分组 + 筛选 chips + 检索索引回填进度
            if (widget.desktop || browser != null)
              _desktopFilters(results, search, now)
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _chip(
                        scheme,
                        label: widget.embedded ? '切换图库' : '图库',
                        active: scope != null,
                        onTap: _chooseAlbum,
                      ),
                      const SizedBox(width: 8),
                      _chip(
                        scheme,
                        key: _groupAnchor,
                        label: _groupBy.stacked ? _groupBy.label : '分组',
                        active: _groupBy != GalleryGroupBy.day,
                        onTap: _pickGroupBy,
                      ),
                      const SizedBox(width: 8),
                      _chip(
                        scheme,
                        key: _modelAnchor,
                        label: _modelFilter == null
                            ? '模型'
                            : (_modelFilter!.isEmpty ? '未知' : _modelFilter!),
                        active: _modelFilter != null,
                        onTap: () => _pickModelFilter(results, search.byId),
                      ),
                      const SizedBox(width: 8),
                      _chip(
                        scheme,
                        key: _dateAnchor,
                        label: _dateFilter.label(now),
                        active: _dateFilter.active,
                        onTap: _pickTimeFilter,
                      ),
                      if (search.building || grouping) ...[
                        const SizedBox(width: 12),
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.8),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          search.building
                              ? '索引 ${search.done}/${search.total}'
                              : '分组中',
                          style: context.texts.bodySmall!.copyWith(
                            color: scheme.outline,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            Expanded(
              child: _pinchLayer(
                child: _dragSelectLayer(
                  child: filtered.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                filtering
                                    ? Icons.search_off
                                    : Icons.image_outlined,
                                size: 40,
                                color: scheme.outline,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                filtering ? '没有符合条件的作品' : '图库是空的',
                                style: context.texts.bodyMedium!.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              if (filtering)
                                TextButton(
                                  onPressed: _clearFilters,
                                  child: const Text('清除筛选'),
                                ),
                            ],
                          ),
                        )
                      : _openLayer(
                          CustomScrollView(
                            controller: _ctrl,
                            // 双指按住、以及换档过渡跑完之前都不滚 ——
                            // 见 [_FrozenScrollPhysics]
                            physics: _pinching || _morph.isAnimating
                                ? const _FrozenScrollPhysics()
                                : null,
                            slivers: [
                              // 三种身姿:点开的单堆 / 堆的封面墙 / 分段列表
                              if (open != null)
                                _gridSliver(
                                  open.items,
                                  state.selectedId,
                                  viewing,
                                )
                              else if (_groupBy.stacked)
                                _stackSliver(scheme, groups)
                              else
                                for (final g in groups) ...[
                                  SliverToBoxAdapter(
                                    child: _groupHeader(scheme, g),
                                  ),
                                  _gridSliver(
                                    g.items,
                                    state.selectedId,
                                    viewing,
                                  ),
                                ],
                              const SliverToBoxAdapter(
                                child: SizedBox(height: 10),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
            // 多选操作栏:进出多选随高度动画滑入滑出
            AnimatedSize(
              duration: Motion.medium,
              curve: Motion.emphasized,
              child: !_selecting
                  ? const SizedBox(width: double.infinity)
                  : SafeArea(
                      top: false,
                      child: Padding(
                        // 上下同距,横竖间隙同取 _actGap —— 原来横 12 竖 8、
                        // 上 4 下 12,三颗挤在一小块里,不等的间隙一眼看得出别扭
                        padding: const EdgeInsets.fromLTRB(
                          16,
                          _actGap,
                          16,
                          _actGap,
                        ),
                        child: _batchActions(canAct),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
    if (!widget.desktop) return content;
    return Focus(
      focusNode: _keyboardFocus,
      autofocus: true,
      skipTraversal: true,
      onKeyEvent: _onDesktopKey,
      child: Listener(
        onPointerDown: (_) {
          if (!_keyboardFocus.hasFocus &&
              ModalRoute.of(context)?.isCurrent != false) {
            _keyboardFocus.requestFocus();
          }
        },
        child: content,
      ),
    );
  }
}

/// 两套网格几何之间的线性插值代理。
///
/// 这是「图片真的在挪窝」的全部实现:每一格的位置与尺寸,都从 [colsA] 列下的值
/// 连续走到 [colsB] 列下的值。整张画面缩放做不到这件事 —— 那样所有格子只是被
/// 一起放大,相对关系纹丝不动,而换列数恰恰是**相对关系**在变(第 4 张从第一行
/// 末尾挪到第二行开头)。
class _ZoomGridDelegate extends SliverGridDelegate {
  const _ZoomGridDelegate(this.of, this.colsA, this.colsB, this.t);

  /// 按列数造一份普通代理。两种网格(方格缩略图 / 带两行字的封面卡)各自的
  /// 尺寸算法不同,所以由调用方传进来。
  final SliverGridDelegate Function(int cols) of;
  final int colsA, colsB;
  final double t;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) => _LerpGridLayout(
    of(colsA).getLayout(constraints),
    of(colsB).getLayout(constraints),
    t,
  );

  @override
  bool shouldRelayout(covariant _ZoomGridDelegate old) =>
      old.t != t || old.colsA != colsA || old.colsB != colsB;
}

class _LerpGridLayout extends SliverGridLayout {
  const _LerpGridLayout(this.a, this.b, this.t);

  final SliverGridLayout a, b;
  final double t;

  double _l(double x, double y) => x + (y - x) * t;

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    final ga = a.getGeometryForChildIndex(index);
    final gb = b.getGeometryForChildIndex(index);
    return SliverGridGeometry(
      scrollOffset: _l(ga.scrollOffset, gb.scrollOffset),
      crossAxisOffset: _l(ga.crossAxisOffset, gb.crossAxisOffset),
      mainAxisExtent: _l(ga.mainAxisExtent, gb.mainAxisExtent),
      crossAxisExtent: _l(ga.crossAxisExtent, gb.crossAxisExtent),
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) => _l(
    a.computeMaxScrollOffset(childCount),
    b.computeMaxScrollOffset(childCount),
  );

  // 可见区间取两套布局的**并集**:插值后的位置一定夹在两者之间,取并集才不会
  // 把边缘上那一两格漏建(漏了就是滚动到边界时凭空出现一块空白)。
  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) => math.min(
    a.getMinChildIndexForScrollOffset(scrollOffset),
    b.getMinChildIndexForScrollOffset(scrollOffset),
  );

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) => math.max(
    a.getMaxChildIndexForScrollOffset(scrollOffset),
    b.getMaxChildIndexForScrollOffset(scrollOffset),
  );
}

/// 捏合期间给列表用的滚动物理:**照常参与手势竞技场,但不产生位移**。
///
/// 为什么不用 `NeverScrollableScrollPhysics`:它的 `shouldAcceptUserOffset`
/// 返回 false,Scrollable 会把自己的拖动识别器撤掉 —— 竞技场里少了它,弹层
/// 自己的「下拉关闭」就赢了,于是捏一下整个浮窗被拽下去。捏合时既要列表别动,
/// 又要它继续占着这个手势不放,两件事得分开:accept 照给,位移给 0。
///
/// 顺带,不给弹道模拟 —— 否则松手那一下还会甩出一段惯性。
class _FrozenScrollPhysics extends ScrollPhysics {
  const _FrozenScrollPhysics({super.parent});

  @override
  _FrozenScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _FrozenScrollPhysics(parent: buildParent(ancestor));

  /// 恒真:内容不足一屏时也要占住手势,否则短列表捏一下就把弹层拖走了。
  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => true;

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) => 0;

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => null;
}

/// 堆的封面卡:封面图 + 身后两片露边的「还有更多」+ 名字 + 张数。
///
/// 叠影只在堆里不止一张时画 —— 一张的堆画了叠影是在说谎,而用户点进去就会发现。
///
/// 叠影用**堆里后面几张的真缩略图**,盖一层与底同色的薄纱压暗、往后推。纯色片
/// 也能表达「还有更多」,但露出的那两条边是死的;换成真图之后每一堆的边缘颜色
/// 都不一样,一眼能看出堆与堆的差别。缩略图本来就是懒读 + 有缓存的(见
/// [galleryThumbProvider]),多读两张不构成负担。
///
/// 张数不够时后面那片退回用第 2 张 —— 只露 6px 的一条边,重复看不出来,而让
/// 几何随张数变会使卡片大小参差不齐,那个更难看。
class _GroupCard extends StatelessWidget {
  const _GroupCard({
    super.key,
    required this.group,
    required this.selecting,
    required this.picked,
    required this.onTap,
    this.onLongPress,
  });

  final GalleryGroup group;
  final bool selecting;

  /// 多选态:这一堆是否**整堆**都已勾选。
  final bool picked;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 每片叠影露出多少。两片,所以封面比整格窄 2 倍这个数。
  /// 6 是「看得出是张照片」和「别把封面挤小」之间的折中。
  static const _peek = 6.0;

  /// 堆里第 [i] 张;不够就 null。
  ResultImage? _at(int i) => i < group.items.length ? group.items[i] : null;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final cover = group.items.first;
    final piled = group.items.length > 1;
    final content = GalleryTileGestures(
      onTap: onTap,
      onLongPress: onLongPress,
      onMouseDragStart: onLongPress,
      onSecondaryTap: null,
      duration: gallerySelectionHold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Expanded 而不是 AspectRatio:格高由 childAspectRatio 定死,名字那两行
          // 在大字号下会变高,让图去吸收才不会溢出(溢出在 debug 下是黄条)。
          Expanded(
            child: LayoutBuilder(
              builder: (_, c) {
                final side = math.min(c.maxWidth, c.maxHeight);
                final w = side - (piled ? _peek * 2 : 0);
                return SizedBox(
                  width: side,
                  height: side,
                  child: Stack(
                    children: [
                      if (piled) ...[
                        _plate(scheme, _peek * 2, w, .62, _at(2) ?? _at(1)),
                        _plate(scheme, _peek, w, .38, _at(1)),
                      ],
                      Positioned(
                        left: 0,
                        top: 0,
                        child: AnimatedContainer(
                          duration: Motion.fast,
                          curve: Motion.standard,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(13),
                            border: Border.all(
                              color: picked
                                  ? scheme.primary
                                  : Colors.transparent,
                              width: 2.5,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(1.5),
                            child: ResultThumb(
                              result: cover,
                              width: w - 8,
                              height: w - 8,
                              radius: 10,
                            ),
                          ),
                        ),
                      ),
                      if (selecting)
                        Positioned(
                          left: 5,
                          top: 5,
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: picked
                                  ? scheme.primary
                                  : Colors.black.withValues(alpha: .35),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: .9),
                                width: 1.5,
                              ),
                            ),
                            child: picked
                                ? Icon(
                                    Icons.check,
                                    size: 14,
                                    color: scheme.onPrimary,
                                  )
                                : null,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          Text(
            group.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodyMedium!.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '${group.items.length} 张',
            maxLines: 1,
            style: context.texts.bodySmall!.copyWith(color: scheme.outline),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      selected: selecting && picked,
      checked: selecting ? picked : null,
      onTap: onTap,
      onLongPress: onLongPress,
      child: content,
    );
  }

  /// 一片叠影。[inset] 是相对封面左上角的偏移,越靠后越淡。
  /// 一片叠影。[inset] 是相对封面左上角的偏移,[veil] 是压在图上的薄纱浓度 ——
  /// 越靠后越浓。薄纱取 [ColorScheme.surface]:浅色主题下是提亮、深色下是压暗,
  /// 两边都读作「退到后面去了」,用黑色纱的话浅色主题里会变成一道脏影。
  Widget _plate(
    ColorScheme scheme,
    double inset,
    double side,
    double veil,
    ResultImage? img,
  ) => Positioned(
    left: inset,
    top: inset,
    child: SizedBox(
      width: side,
      height: side,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (img != null)
            ResultThumb(result: img, width: side, height: side, radius: 10),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              // 没图(读不到 / 堆里就一张)时这层就是原来的纯色片
              color: img == null
                  ? scheme.surfaceContainerHighest.withValues(alpha: 1 - veil)
                  : scheme.surface.withValues(alpha: veil),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .55),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

// ---- 长按:按住抬起 + 贴着图的菜单 ----

/// 缩略图长按后的「抬起」层。
///
/// 用 PopupRoute 而不是自己搭 Overlay:遮罩、返回键、点空白关闭、进出动画
/// 全是路由自带的,手搭一遍只会漏掉其中一两样。
class _ThumbMenuRoute extends PopupRoute<String> {
  _ThumbMenuRoute({
    required this.from,
    required this.result,
    required this.warm,
    required this.desktop,
  });

  /// 缩略图在 overlay 坐标系里的原始矩形 —— 放大从这里长出来,
  /// 「浮起的是这一张」全指望它。
  final Rect from;
  final ResultImage result;
  final bool desktop;

  /// 开层前已读好并解码过的原图;null = 没赶上(读得慢/读失败),
  /// 层里自己去 watch,补上之前先用缩略图垫着。
  final Uint8List? warm;

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: .55);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '关闭菜单';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 230);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> anim,
    Animation<double> _,
  ) => _LiftedThumb(
    from: from,
    result: result,
    warm: warm,
    anim: anim,
    desktop: desktop,
  );
}

class _LiftedThumb extends ConsumerWidget {
  const _LiftedThumb({
    required this.from,
    required this.result,
    required this.warm,
    required this.anim,
    required this.desktop,
  });

  final Rect from;
  final ResultImage result;
  final Uint8List? warm;
  final Animation<double> anim;
  final bool desktop;

  static const _margin = 16.0;
  static const _gap = 12.0;
  static const _menuW = 200.0;
  static const _itemH = 46.0;
  static const _dividerH = 9.0;
  double get _menuH => _itemH * (desktop ? 5 : 4) + _dividerH + 16;

  /// 抬起的图占「可用框」(去掉边距与菜单之后那块)的面积比例。
  static const _fill = .42;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final top0 = media.padding.top + _margin;
    final bot0 = size.height - media.padding.bottom - _margin;

    // 抬起后按图的**真实长宽比**摊开 —— 网格里是方裁的,这一下顺带把裁掉的
    // 部分还回来。
    //
    // 预算给的是**面积**,不是宽度。原先一律取屏宽六成,横图等于被砍了两刀:
    // 宽度先削到六成,高度再按长宽比除一次,最后只有同尺寸竖图的四成大 ——
    // 而它下面那截纵向空间明明空着。改成「什么比例都占可用框的 [_fill]」,
    // 竖图与原先基本同尺寸,横图翻倍,方图也不再偏小。
    //
    // 不铺满是刻意的:铺满就成了看图页,没有「一张卡浮在网格上」的意思,
    // 而这个「浮在网格上」正是指向感的来源。
    final aspect = (result.aspect.isFinite && result.aspect > 0)
        ? result.aspect
        : 1.0; // 老索引里 0 宽/0 高的条目,别把 NaN 送进布局
    final maxW = size.width - _margin * 2;
    final maxH = math.max(80.0, bot0 - top0 - _menuH - _gap);
    var pw = math.sqrt(maxW * maxH * _fill * aspect);
    var ph = pw / aspect;
    if (ph > maxH) {
      ph = maxH;
      pw = ph * aspect;
    }
    if (pw > maxW) {
      pw = maxW;
      ph = pw / aspect;
    }

    // 尽量停在原位附近:抬起来的是「刚按的那一张」,不是从屏幕中央蹦出来的
    // 另一张。装不下(菜单要顶到屏幕外)才整体上移。
    final groupH = ph + _gap + _menuH;
    final left = (from.center.dx - pw / 2)
        .clamp(_margin, math.max(_margin, size.width - pw - _margin))
        .toDouble();
    final top = (from.center.dy - ph / 2)
        .clamp(top0, math.max(top0, bot0 - groupH))
        .toDouble();
    final menuLeft = left
        .clamp(_margin, math.max(_margin, size.width - _menuW - _margin))
        .toDouble();
    final to = Rect.fromLTWH(left, top, pw, ph);

    // 抬起来本就是为了看清 —— 拿缩略图放大只是把糊的放得更糊,所以用原图。
    // 常态下 warm 已经读好解好(见 _warmFull),第一帧就是清的;只有没赶上
    // 时才落到这个 watch 上,那条路再淡入。
    final full = warm ?? ref.watch(galleryImageProvider(result.id)).value;

    return AnimatedBuilder(
      animation: anim,
      builder: (context, _) {
        final t = Motion.emphasized.transform(
          anim.value.clamp(0.0, 1.0).toDouble(),
        );
        final rect = Rect.lerp(from, to, t)!;
        return Stack(
          children: [
            Positioned.fromRect(
              rect: rect,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 原图读盘期间先垫着已经在内存里的缩略图 ——
                    // 长按到抬起之间不该有一格空白。
                    //
                    // 原图到位后必须**让它消失**,不能一直垫着:不透明图看不出
                    // 区别(全被盖住),半透明图会从透明区把这张拉伸的缩略图透
                    // 出来,看着就是背景多了一张模糊的放大图。用淡出而不是
                    // 直接撤掉 —— 与上面那层的淡入同步,慢路径才不会闪一下空白。
                    AnimatedOpacity(
                      opacity: full == null ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: ResultThumb(
                        result: result,
                        width: rect.width,
                        height: rect.height,
                        radius: 14,
                      ),
                    ),
                    // 慢路径(warm 没赶上)才会走到这个切换:淡入而不是
                    // 直接盖上去,免得眼睁睁看着一张糊的跳成清的
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: full == null
                          ? const SizedBox.shrink(key: ValueKey('wait'))
                          : Image.memory(
                              full,
                              key: const ValueKey('full'),
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: menuLeft,
              top: to.bottom + _gap,
              width: _menuW,
              // 从图的下沿卷出来,不是凭空淡入 —— 强调它属于上面那张
              child: Opacity(
                opacity: t,
                child: ClipRect(
                  child: Align(
                    alignment: Alignment.topCenter,
                    heightFactor: math.max(t, .01),
                    child: _menu(context),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _menu(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          _item(context, Icons.input, '导入', 'import'),
          _item(context, Icons.download, '保存', 'save'),
          if (desktop) ...[
            _item(context, Icons.drive_file_move_outline, '移动', 'move'),
            _item(context, Icons.copy_outlined, '复制', 'copy'),
          ] else
            _item(context, Icons.ios_share, '分享', 'share'),
          // 删除排最后并单独隔一条线:菜单就在手指底下,不可撤销的那项
          // 排第一位等于放到最容易误落的地方
          Divider(
            height: _dividerH,
            thickness: 1,
            indent: 14,
            endIndent: 14,
            color: scheme.outlineVariant,
          ),
          _item(context, Icons.delete_outline, '删除', 'delete', danger: true),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _item(
    BuildContext context,
    IconData icon,
    String label,
    String value, {
    bool danger = false,
  }) {
    final scheme = context.scheme;
    return InkWell(
      onTap: () => Navigator.of(context).pop(value),
      child: SizedBox(
        height: _itemH,
        child: Row(
          children: [
            const SizedBox(width: 14),
            Icon(
              icon,
              size: 20,
              color: danger ? scheme.error : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: context.texts.bodyLarge!.copyWith(
                color: danger ? scheme.error : scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
