import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/net/remote_image.dart';
import '../../core/platform/desktop.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/image_drop.dart';
import '../../core/util/image_pick.dart';
import '../gallery/gallery_state.dart';
import '../generate/generate_state.dart';
import '../generate/widgets/common.dart'
    show ExpandBody, confirmDialog, hintSnack, sharedAxisRoute;
import 'artist_models.dart';
import 'public_tags.dart';
import 'tag_library.dart';
import 'tag_models.dart';
import 'tag_preview_gen.dart';

// One editor per window, including calls from the embedded inspiration pane.
// Rapid/repeated invocations must not leave stacked modal barriers behind.
final _openTagEditors = Expando<Future<void>>('tag-editors');

Future<void> showTagEditor(
  BuildContext context, {
  required TagCategory cat,
  TagEntry? edit,
}) {
  final desktop = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(desktopModeProvider);
  if (!desktop) {
    return Navigator.of(
      context,
    ).push<void>(sharedAxisRoute(TagEditorPage(cat: cat, edit: edit)));
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  final existing = _openTagEditors[navigator];
  if (existing != null) return existing;
  final opened = showDialog<void>(
    context: context,
    useRootNavigator: true,
    requestFocus: true,
    barrierDismissible: false,
    builder: (_) => Dialog(
      key: const ValueKey('tag-editor-dialog'),
      constraints: const BoxConstraints(maxWidth: 920, maxHeight: 680),
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 920,
        height: 680,
        child: TagEditorPage(cat: cat, edit: edit, floating: true),
      ),
    ),
  );
  final result = opened.whenComplete(() => _openTagEditors[navigator] = null);
  _openTagEditors[navigator] = result;
  return result;
}

/// 折叠式条目编辑器(创建/编辑统一,4 分类字段差异由配置驱动;
/// UI 框架对齐设计稿 handoff 的手风琴方案,配色走 app 主题):
/// 头部(返回/图标块/标题/已发布 chip/创建态进度环)→ 校验横幅 →
/// 手风琴字段卡(名称+编号+别名 / 提示词+导入+粘贴+token / 预览图 / 标签)
/// → 编辑态管理动作行 → 底部按钮矩阵。
/// 必填未齐时主按钮视觉禁用但可点(点了亮校验并展开缺失卡);
/// 收藏副本(favorited)内容只读、仅标签可改。
class TagEditorPage extends ConsumerStatefulWidget {
  const TagEditorPage({
    super.key,
    required this.cat,
    this.edit,
    this.floating = false,
  });

  final TagCategory cat;
  final TagEntry? edit;
  final bool floating;

  @override
  ConsumerState<TagEditorPage> createState() => _TagEditorPageState();
}

/// 预览槽:既有引用(http URL / 本机路径)或本轮新图字节。
class _Slot {
  String? ref;
  Uint8List? bytes;

  bool get filled => bytes != null || (ref?.isNotEmpty ?? false);

  void clear() {
    ref = null;
    bytes = null;
  }
}

class _TagEditorPageState extends ConsumerState<TagEditorPage> {
  late final TagCategoryDef _def = tagCategoryDef(widget.cat);
  late final TagEntry? _edit = widget.edit;
  late final bool _isEdit = _edit != null;
  late final bool _locked = _edit?.origin == TagOrigin.favorited;
  late final String _entryId = _edit?.id ?? TagLibrary.newId(widget.cat);

  late final _name = TextEditingController(text: _edit?.name ?? '');
  late final _positive = TextEditingController(text: _edit?.positive ?? '');
  late final _negative = TextEditingController(text: _edit?.negative ?? '');
  late final List<String> _aliases = [...?_edit?.aliases];
  late final Set<String> _tags = {...?_edit?.tags};

  /// 适用模型(仅画风)。空 = 通用 —— 这是默认档,不是"没填完"。
  late final Set<String> _models = {...?_edit?.models};

  late final int _slotCount = !_hasPreview
      ? 0
      : widget.cat == TagCategory.artist
      ? 4
      : 1;
  late final List<_Slot> _slots = List.generate(_slotCount, (i) {
    final s = _Slot();
    final prev = _edit?.previews ?? const [];
    if (i < prev.length) s.ref = prev[i];
    return s;
  });

  String? _open = 'name';
  int _cover = 0; // 画师四格的封面槽(保存时排到首位,发布传封面图)
  bool _showNegative = false;
  bool _showAliases = false;
  bool _validationVisible = false;
  bool _busy = false;

  int? _genIndex;
  (int, int)? _genProgress;

  bool get _hasPreview => widget.cat != TagCategory.other;
  bool get _canGenerate =>
      widget.cat == TagCategory.character || widget.cat == TagCategory.artist;
  bool get _generating => _genIndex != null;

  bool get _nameOk => _name.text.trim().isNotEmpty;
  bool get _positiveOk => _positive.text.trim().isNotEmpty;
  bool get _canSave => _locked || (_nameOk && _positiveOk);

  @override
  void initState() {
    super.initState();
    _showNegative = (_edit?.negative.trim().isNotEmpty ?? false);
    _showAliases = _aliases.isNotEmpty;
    // 必填联动进度环/校验态
    _name.addListener(() => setState(() {}));
    _positive.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _positive.dispose();
    _negative.dispose();
    super.dispose();
  }

  int _tokens(String s) =>
      s.split(RegExp(r'[，,]')).where((e) => e.trim().isNotEmpty).length;

  // ---- 构建与保存 ----

  /// 落盘内存字节 → 路径,拼出最终 previews(封面槽排首位,空槽跳过)。
  /// 存为副本(forId ≠ 本条目)时,本机文件引用也复制一份——
  /// 否则与原条目共用文件,原条目删除会连带毁掉副本预览。
  Future<List<String>> _buildPreviews(String forId) async {
    final order = [
      if (_cover < _slots.length) _cover,
      for (var i = 0; i < _slots.length; i++)
        if (i != _cover) i,
    ];
    final out = <String>[];
    for (final i in order) {
      final s = _slots[i];
      var bytes = s.bytes;
      final r = s.ref;
      if (bytes == null &&
          forId != _entryId &&
          r != null &&
          r.isNotEmpty &&
          !r.startsWith('http')) {
        try {
          bytes = await File(r).readAsBytes();
        } catch (_) {}
      }
      if (bytes != null) {
        out.add(await TagLibrary.savePreviewBytes(forId, i, bytes));
      } else if (r?.isNotEmpty ?? false) {
        out.add(r!);
      }
    }
    return out;
  }

  Future<TagEntry> _buildEntry({
    String? id,
    String? name,
    TagOrigin? origin,
    String? publicId,
  }) async {
    final eid = id ?? _entryId;
    return TagEntry(
      id: eid,
      category: widget.cat,
      name: name ?? _name.text.trim(),
      positive: _positive.text.trim(),
      negative: _negative.text.trim(),
      aliases: _def.key == TagCategory.character ? [..._aliases] : const [],
      tags: _tags.toList()..sort(),
      models: normalizeArtistModels(_models.toList()),
      origin: origin ?? _edit?.origin ?? TagOrigin.local,
      publicId:
          publicId ?? (origin == TagOrigin.local ? null : _edit?.publicId),
      previews: await _buildPreviews(eid),
      createdAt: _edit?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
      createdBy: _edit?.createdBy,
    );
  }

  /// 点主按钮但必填未齐:亮出校验并展开第一个缺失卡。
  bool _guardValidation() {
    if (_canSave) return false;
    setState(() {
      _validationVisible = true;
      _open = !_nameOk ? 'name' : 'prompt';
    });
    return true;
  }

  Future<void> _run(Future<void> Function() op) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await op();
    } on BackendException catch (e) {
      if (mounted) hintSnack(context, e.message, icon: Icons.error_outline);
    } catch (e) {
      if (mounted) hintSnack(context, '$e', icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveLocal() async {
    if (_guardValidation()) return;
    await _run(() async {
      await ref.read(tagLibraryProvider.notifier).upsert(await _buildEntry());
      if (!mounted) return;
      Navigator.pop(context);
      hintSnack(context, '已保存', icon: Icons.check_circle_outline);
    });
  }

  /// favorited:内容锁定,仅保存标签改动。
  Future<void> _saveTagsOnly() async {
    await _run(() async {
      await ref
          .read(tagLibraryProvider.notifier)
          .upsert(
            _edit!.copyWith(
              tags: _tags.toList()..sort(),
              models: normalizeArtistModels(_models.toList()),
            ),
          );
      if (!mounted) return;
      Navigator.pop(context);
      hintSnack(context, '已保存', icon: Icons.check_circle_outline);
    });
  }

  Future<String?> _coverPreviewBase64() async {
    if (_slots.isEmpty) return null;
    final s = _slots[_cover < _slots.length ? _cover : 0];
    if (s.bytes != null) return base64Encode(s.bytes!);
    final r = s.ref;
    if (r != null && r.isNotEmpty && !r.startsWith('http')) {
      try {
        return base64Encode(await File(r).readAsBytes());
      } catch (_) {}
    }
    return null;
  }

  /// 发布前提醒。**按类目分文案**,对齐 web `PublishGuidelinesDialog` ——
  /// 原先是一份「内容为本人创作/提示词不含违规/发布后所有用户可见」的通用话术,
  /// 三条都对,但没一条告诉用户**这一类**具体该怎么整理,读完还是不知道该改什么。
  ///
  /// 措辞跟着 app 自己的类目名走:web 那边叫「画师串」,app 一路叫「画风」,
  /// 提醒里跟着叫画风,免得弹窗自造一个用户在别处没见过的词。
  Future<bool> _publishGuidelines() {
    final isChar = widget.cat == TagCategory.character;
    final bullets = isChar
        ? const [
            '必须是原创角色(OC),请勿上传二创 / 同人角色',
            '仅保留与角色外貌相关的提示词(服装 / 发型 / 瞳色等),'
                '请去除场景 / 背景 / 动作等无关内容',
            '尽量避免明显 R18 / 裸露描写,保持适度',
          ]
        : const [
            '请先自行测试过画风效果,确认品质后再发布',
            '未经原作者授权请勿搬运他人发布的画风',
            '剔除与画风无关的 tag(角色 / 动作 / 构图等),仅描述画风',
          ];
    final name = _name.text.trim();
    return confirmDialog(
      context,
      title: isChar ? '发布到公共角色库' : '发布到公共画风库',
      message: [
        '发布前请阅读以下规范\n',
        for (final b in bullets) '· $b',
        if (name.isNotEmpty) '\n即将发布:$name',
      ].join('\n'),
      confirmLabel: '我已确认,发布',
      danger: false, // 发布不毁数据,别用红底吓人
    );
  }

  /// 创建态「保存并发布」:发布成功后本地落 created 副本(对齐 web)。
  Future<void> _publish() async {
    if (_guardValidation()) return;
    final session = ref.read(botSessionProvider).value;
    if (session == null) {
      hintSnack(context, '发布需要 Bot 授权', icon: Icons.cloud_off_outlined);
      return;
    }
    if (!_slots.any((s) => s.filled)) {
      hintSnack(context, '发布需要一张预览图', icon: Icons.image_not_supported_outlined);
      setState(() => _open = 'preview');
      return;
    }
    if (!await _publishGuidelines()) return;
    await _run(() async {
      final client = ref.read(backendClientProvider);
      final preview = await _coverPreviewBase64();
      final String publicId;
      var finalName = _name.text.trim();
      if (widget.cat == TagCategory.character) {
        publicId = await client.createPublicOc(
          sessionId: session.sessionId,
          zhName: finalName,
          aliases: _aliases,
          tagGroup: _positive.text.trim(),
          negativePrompt: _negative.text.trim(),
          previewBase64: preview,
          createdBy: session.botUserId,
        );
      } else {
        final r = await client.createPublicArtist(
          sessionId: session.sessionId,
          name: finalName,
          artistString: _positive.text.trim(),
          previewBase64: preview,
          addedBy: session.botUserId,
          models: normalizeArtistModels(_models.toList()),
        );
        publicId = r.id;
        finalName = r.name;
      }
      await ref
          .read(tagLibraryProvider.notifier)
          .upsert(
            await _buildEntry(
              name: finalName,
              origin: TagOrigin.created,
              publicId: publicId,
            ),
          );
      ref.invalidate(publicTagsProvider(widget.cat));
      if (!mounted) return;
      Navigator.pop(context);
      hintSnack(context, '已发布到公共库', icon: Icons.public);
    });
  }

  /// 编辑 created「保存并同步」:同步服务端 + 更新本地副本。
  Future<void> _syncPublic() async {
    if (_guardValidation()) return;
    final session = ref.read(botSessionProvider).value;
    if (session == null) {
      hintSnack(context, '同步需要 Bot 授权', icon: Icons.cloud_off_outlined);
      return;
    }
    await _run(() async {
      final client = ref.read(backendClientProvider);
      // 预览:本轮换了新图(内存字节)才重传
      final coverSlot = _slots.isNotEmpty
          ? _slots[_cover < _slots.length ? _cover : 0]
          : null;
      final preview = coverSlot?.bytes != null
          ? base64Encode(coverSlot!.bytes!)
          : null;
      if (widget.cat == TagCategory.character) {
        await client.updatePublicOc(
          sessionId: session.sessionId,
          enName: _edit!.publicId!,
          zhName: _name.text.trim(),
          aliases: _aliases,
          tagGroup: _positive.text.trim(),
          negativePrompt: _negative.text.trim(),
          previewBase64: preview,
        );
      } else {
        await client.updatePublicArtist(
          sessionId: session.sessionId,
          id: _edit!.publicId!,
          artistString: _positive.text.trim(),
          previewBase64: preview,
          // 空列表照发:用户取消掉全部标注 = 改回通用,和「本次不改」不是一回事
          models: normalizeArtistModels(_models.toList()),
        );
      }
      await ref.read(tagLibraryProvider.notifier).upsert(await _buildEntry());
      ref.invalidate(publicTagsProvider(widget.cat));
      if (!mounted) return;
      Navigator.pop(context);
      hintSnack(context, '已保存并同步', icon: Icons.cloud_done_outlined);
    });
  }

  /// 存为脱钩本地副本(编辑 created 次按钮 / favorited 管理行)。
  Future<void> _saveAsCopy() async {
    if (_guardValidation()) return;
    await _run(() async {
      final lib = ref.read(tagLibraryProvider.notifier);
      final entry = await _buildEntry(
        id: TagLibrary.newId(widget.cat),
        name: lib.uniqueName(widget.cat, _name.text.trim()),
        origin: TagOrigin.local, // origin=local ⇒ publicId 自动为空,脱钩
      );
      await lib.upsert(entry);
      if (!mounted) return;
      Navigator.pop(context);
      hintSnack(context, '已存为本地副本', icon: Icons.file_copy_outlined);
    });
  }

  Future<void> _unpublish() async {
    final edit = _edit!;
    final ok = await confirmDialog(
      context,
      title: '撤回公共发布',
      message: '将从公共库撤回「${edit.name}」,本地保留一份可继续编辑的副本。',
      confirmLabel: '撤回',
    );
    if (!ok || !mounted) return;
    final session = ref.read(botSessionProvider).value;
    if (session == null) {
      hintSnack(context, '需要 Bot 授权', icon: Icons.cloud_off_outlined);
      return;
    }
    await _run(() async {
      final client = ref.read(backendClientProvider);
      if (widget.cat == TagCategory.character) {
        await client.deletePublicOc(session.sessionId, edit.publicId!);
      } else {
        await client.deletePublicArtist(session.sessionId, edit.publicId!);
      }
      await ref
          .read(tagLibraryProvider.notifier)
          .upsert(
            edit.copyWith(
              origin: TagOrigin.local,
              publicId: TagEntry.clearPublicId,
            ),
          );
      ref.invalidate(publicTagsProvider(widget.cat));
      if (!mounted) return;
      Navigator.pop(context);
      hintSnack(context, '已撤回发布,本地保留', icon: Icons.undo);
    });
  }

  /// 转让所有者:说明 + ID 输入 + 红色确认,单弹窗完成。
  Future<void> _transfer() async {
    final edit = _edit!;
    final input = TextEditingController();
    final target = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.manage_accounts_outlined,
              size: 20,
              color: context.scheme.primary,
            ),
            const SizedBox(width: 8),
            const Text('转让所有者'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                text: '把「${edit.name}」的所有权转让给其他用户,转让后你将',
                children: [
                  TextSpan(
                    text: '失去管理权',
                    style: TextStyle(
                      color: context.scheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const TextSpan(text: '(不能再编辑/撤回此条目)。'),
                ],
              ),
              style: context.texts.bodySmall!.copyWith(height: 1.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: input,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                isDense: true,
                labelText: '新主人 ID(QQ 号)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ValueListenableBuilder(
            valueListenable: input,
            builder: (context, v, _) => FilledButton(
              onPressed: v.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, v.text.trim()),
              style: FilledButton.styleFrom(
                backgroundColor: context.scheme.error,
                foregroundColor: context.scheme.onError,
              ),
              child: const Text('确认转让'),
            ),
          ),
        ],
      ),
    );
    input.dispose();
    if (target == null || target.isEmpty || !mounted) return;
    final session = ref.read(botSessionProvider).value;
    if (session == null) {
      hintSnack(context, '需要 Bot 授权', icon: Icons.cloud_off_outlined);
      return;
    }
    await _run(() async {
      final client = ref.read(backendClientProvider);
      if (widget.cat == TagCategory.character) {
        await client.updatePublicOc(
          sessionId: session.sessionId,
          enName: edit.publicId!,
          createdBy: target,
        );
      } else {
        await client.updatePublicArtist(
          sessionId: session.sessionId,
          id: edit.publicId!,
          addedBy: target,
        );
      }
      ref.invalidate(publicTagsProvider(widget.cat));
      if (!mounted) return;
      Navigator.pop(context);
      hintSnack(context, '已转让', icon: Icons.manage_accounts_outlined);
    });
  }

  Future<void> _delete() async {
    final edit = _edit!;
    final isCreated = edit.origin == TagOrigin.created;
    final ok = await confirmDialog(
      context,
      title: '删除「${edit.name}」?',
      message: isCreated ? '将同时删除公共库条目与本地副本,不可恢复。' : '仅删除本地条目,不可恢复。',
      confirmLabel: '删除',
    );
    if (!ok) return;
    await _run(() async {
      if (isCreated) {
        final session = ref.read(botSessionProvider).value;
        if (session == null) throw BackendException('需要 Bot 授权');
        final client = ref.read(backendClientProvider);
        if (widget.cat == TagCategory.character) {
          await client.deletePublicOc(session.sessionId, edit.publicId!);
        } else {
          await client.deletePublicArtist(session.sessionId, edit.publicId!);
        }
        ref.invalidate(publicTagsProvider(widget.cat));
      }
      await ref.read(tagLibraryProvider.notifier).remove(edit.id);
      if (!mounted) return;
      Navigator.pop(context);
      hintSnack(context, '已删除', icon: Icons.delete_outline);
    });
  }

  // ---- 名称 / 提示词工具 ----

  void _suggestCode() {
    final lib = ref.read(tagLibraryProvider).value;
    final pub = ref.read(publicTagsProvider(TagCategory.artist)).value;
    final occupied = <String>{
      ...?lib?.of(TagCategory.artist).map((e) => e.name),
      ...?pub?.map((e) => e.name),
    };
    final code = suggestArtistCode(occupied);
    if (code == null) {
      hintSnack(context, '编号已用尽', icon: Icons.error_outline);
      return;
    }
    setState(() => _name.text = code);
  }

  /// 导入:角色分类优先取启用的角色卡提示词,否则主提示词(对齐 web)。
  (String label, VoidCallback run)? _importSource() {
    final gen = ref.read(generateProvider);
    if (widget.cat == TagCategory.character) {
      final usable = [
        for (final c in gen.characters)
          if (c.enabled && c.positive.trim().isNotEmpty) c,
      ];
      if (usable.isNotEmpty) {
        return (
          '导入角色提示词',
          () => setState(() {
            _positive.text = usable.first.positive.trim();
            final neg = usable.first.negative.trim();
            if (neg.isNotEmpty) {
              _negative.text = neg;
              _showNegative = true;
            }
          }),
        );
      }
    }
    if (gen.prompt.trim().isEmpty) return null;
    return (
      '导入主提示词',
      () => setState(() {
        _positive.text = gen.prompt.trim();
        final neg = gen.negativePrompt.trim();
        // The artist action imports the positive style string only. Restoring
        // its negative editor must not start replacing a separately edited UC.
        if (widget.cat != TagCategory.artist && neg.isNotEmpty) {
          _negative.text = neg;
          _showNegative = true;
        }
      }),
    );
  }

  Future<void> _paste(TextEditingController c) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    setState(() => c.text = text);
  }

  // ---- 预览图操作 ----

  Future<void> _pickImages({int? into}) async {
    if (_slotCount == 1 || into != null) {
      final f = await pickImageFile(context);
      if (f == null || !mounted) return;
      _applyPickedImages([f], into: into ?? 0);
      return;
    }
    final files = await pickImageFiles(context);
    if (files.isEmpty || !mounted) return;
    _applyPickedImages(files);
  }

  void _applyPickedImages(List<PickedImage> files, {int? into}) {
    if (!mounted || files.isEmpty || _locked || _busy || _generating) return;
    if (into != null) {
      setState(() {
        _slots[into]
          ..bytes = files.first.bytes
          ..ref = null;
      });
      return;
    }
    final list = [for (final f in files.take(_slotCount)) f.bytes];
    setState(() {
      var idx = 0;
      for (final b in list) {
        // 先填空槽,满了从头覆盖
        var target = _slots.indexWhere((s) => !s.filled);
        if (target < 0) target = idx % _slotCount;
        _slots[target]
          ..bytes = b
          ..ref = null;
        idx++;
      }
    });
  }

  Future<void> _pickFromHistory({int? into}) async {
    final results = ref.read(galleryProvider).results;
    if (results.isEmpty) {
      hintSnack(context, '图库还没有图片', icon: Icons.photo_library_outlined);
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SizedBox(
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
              child: Row(
                children: [
                  Icon(Icons.history, size: 20, color: context.scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    '从图库选取',
                    style: context.texts.titleMedium!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '共 ${results.length} 张',
                    style: context.texts.labelSmall!.copyWith(
                      color: context.scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemCount: results.length,
                itemBuilder: (context, i) => _HistoryThumb(
                  id: results[i].id,
                  onTap: () => Navigator.pop(context, results[i].id),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final bytes =
        ref
            .read(galleryProvider)
            .results
            .where((r) => r.id == picked)
            .firstOrNull
            ?.bytes ??
        await ref.read(galleryImageProvider(picked).future);
    if (bytes == null) {
      if (mounted) hintSnack(context, '读取图片失败', icon: Icons.error_outline);
      return;
    }
    setState(() {
      var target = into ?? _slots.indexWhere((s) => !s.filled);
      if (target < 0) target = 0;
      _slots[target]
        ..bytes = bytes
        ..ref = null;
    });
  }

  Future<void> _generateInto(List<int> indexes) async {
    if (_positive.text.trim().isEmpty) {
      hintSnack(context, '先填写正向提示词', icon: Icons.error_outline);
      return;
    }
    if (_generating) return;
    for (final i in indexes) {
      setState(() {
        _genIndex = i;
        _genProgress = null;
      });
      try {
        final bytes = await generateTagPreview(
          ref,
          cat: widget.cat,
          positive: _positive.text,
          slot: i,
          onStep: (s, t) {
            if (mounted) setState(() => _genProgress = (s, t));
          },
        );
        if (!mounted) return;
        setState(() {
          _slots[i]
            ..bytes = bytes
            ..ref = null;
        });
      } catch (e) {
        if (mounted) {
          hintSnack(
            context,
            e is BackendException ? e.message : '$e',
            icon: Icons.error_outline,
          );
        }
        break;
      }
    }
    if (mounted) {
      setState(() {
        _genIndex = null;
        _genProgress = null;
      });
    }
  }

  void _slotMenu(int i) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_slotCount > 1 && i != _cover)
              ListTile(
                leading: const Icon(Icons.star_outline),
                title: const Text('设为封面'),
                onTap: () {
                  Navigator.pop(sheet);
                  setState(() => _cover = i);
                },
              ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('替换'),
              onTap: () {
                Navigator.pop(sheet);
                _pickImages(into: i);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从图库选取'),
              onTap: () {
                Navigator.pop(sheet);
                _pickFromHistory(into: i);
              },
            ),
            if (_canGenerate)
              ListTile(
                leading: const Icon(Icons.auto_fix_high_outlined),
                title: const Text('重新生成'),
                onTap: () {
                  Navigator.pop(sheet);
                  _generateInto([i]);
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: context.scheme.error),
              title: Text('移除', style: TextStyle(color: context.scheme.error)),
              onTap: () {
                Navigator.pop(sheet);
                setState(() => _slots[i].clear());
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final desktop = ref.watch(desktopModeProvider);
    if (desktop) {
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (widget.floating && !_busy && !_generating) {
              Navigator.pop(context);
            }
          },
        },
        child: Focus(autofocus: widget.floating, child: _desktopEditor(scheme)),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: desktop ? 12 : 0),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              key: const ValueKey('tag-editor-form'),
              constraints: BoxConstraints(
                maxWidth: desktop ? 880 : double.infinity,
              ),
              child: Column(
                children: [
                  _header(scheme),
                  if (_validationVisible && !_canSave)
                    _validationBanner(scheme),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                      children: [
                        _section(
                          id: 'name',
                          title: '名称',
                          required: true,
                          filled: _nameOk,
                          collapsedValue: _name.text.trim().isEmpty
                              ? null
                              : _name.text.trim(),
                          body: _nameBody(scheme),
                        ),
                        _section(
                          id: 'prompt',
                          title: '提示词',
                          required: true,
                          filled: _positiveOk,
                          collapsedValue: _positive.text.trim().isEmpty
                              ? null
                              : _positive.text.trim(),
                          body: _promptBody(scheme),
                        ),
                        if (_hasPreview)
                          _section(
                            id: 'preview',
                            title: '预览图',
                            filled: _slots.any((s) => s.filled),
                            collapsedValue: _slots.any((s) => s.filled)
                                ? '${_slots.where((s) => s.filled).length} 张'
                                : null,
                            body: _previewBody(scheme),
                          ),
                        // 只有画风有这一档 —— 角色/场景/其他标模型没有意义
                        if (widget.cat == TagCategory.artist)
                          _section(
                            id: 'models',
                            title: '适用模型',
                            filled: _models.isNotEmpty,
                            collapsedValue: _models.isEmpty
                                ? kGenericModelLabel
                                : normalizeArtistModels(
                                    _models.toList(),
                                  ).map(artistModelShort).join(' · '),
                            body: _modelsBody(scheme),
                          ),
                        _section(
                          id: 'tags',
                          title: '标签',
                          filled: _tags.isNotEmpty,
                          collapsedValue: _tags.isEmpty
                              ? null
                              : _tags.map((t) => '#$t').join(' '),
                          body: _tagsBody(scheme),
                        ),
                        if (_isEdit) _managementRow(scheme),
                      ],
                    ),
                  ),
                  _footer(scheme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _desktopEditor(ColorScheme scheme) {
    final fields = <Widget>[
      _desktopField('名称', _nameBody(scheme), invalid: !_nameOk, required: true),
      _desktopField(
        '提示词',
        _promptBody(scheme),
        invalid: !_positiveOk,
        required: true,
      ),
      if (widget.cat == TagCategory.artist)
        _desktopField('适用模型', _modelsBody(scheme)),
      _desktopField('标签', _tagsBody(scheme)),
      if (_isEdit) _managementRow(scheme),
    ];
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              key: const ValueKey('tag-editor-form'),
              constraints: const BoxConstraints(maxWidth: 920),
              child: Column(
                children: [
                  _header(scheme),
                  if (_validationVisible && !_canSave)
                    _validationBanner(scheme),
                  const SizedBox(height: 12),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final split =
                            _hasPreview && constraints.maxWidth >= 720;
                        final preview = _hasPreview
                            ? Padding(
                                key: const ValueKey('tag-editor-preview'),
                                padding: const EdgeInsets.all(12),
                                child: _previewBody(scheme, desktop: true),
                              )
                            : const SizedBox.shrink();
                        final form = Column(
                          key: const ValueKey('tag-editor-details'),
                          children: [
                            Expanded(
                              child: ListView(
                                padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
                                children: [
                                  if (_hasPreview && !split)
                                    SizedBox(height: 460, child: preview),
                                  ...fields,
                                ],
                              ),
                            ),
                            _footer(scheme),
                          ],
                        );
                        if (!split) return form;
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: preview),
                            const SizedBox(width: 20),
                            SizedBox(
                              width: constraints.maxWidth >= 840 ? 440 : 380,
                              child: form,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _desktopField(
    String title,
    Widget body, {
    bool invalid = false,
    bool required = false,
  }) {
    final scheme = context.scheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _validationVisible && invalid
              ? scheme.error
              : scheme.outlineVariant.withValues(alpha: .5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(required ? '$title *' : title, style: context.texts.titleSmall),
          const SizedBox(height: 8),
          body,
        ],
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    final isCreated = _edit?.origin == TagOrigin.created;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 14, 4),
      child: Row(
        children: [
          if (!widget.floating)
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_def.icon, size: 19, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: 10),
          Text(
            _isEdit ? '编辑${_def.label}' : '新建${_def.label}',
            style: context.texts.titleMedium!.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (isCreated) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                '已发布',
                style: context.texts.labelSmall!.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
          if (_locked) ...[
            const SizedBox(width: 8),
            Icon(Icons.lock_outline, size: 15, color: scheme.onSurfaceVariant),
          ],
          if (widget.floating) ...[
            const Spacer(),
            IconButton(
              tooltip: '关闭编辑器',
              icon: const Icon(Icons.close),
              onPressed: _busy || _generating
                  ? null
                  : () => Navigator.pop(context),
            ),
          ],
        ],
      ),
    );
  }

  Widget _validationBanner(ColorScheme scheme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Text(
            '还有必填项未完成,已用红色标出',
            style: context.texts.bodySmall!.copyWith(
              color: scheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }

  /// 手风琴字段卡:同刻最多展开一张;必填缺失且校验可见时红框+「必填」。
  Widget _section({
    required String id,
    required String title,
    bool required = false,
    required bool filled,
    String? collapsedValue,
    required Widget body,
  }) {
    final scheme = context.scheme;
    final expanded = _open == id;
    final errored = _validationVisible && required && !filled;
    return AnimatedContainer(
      duration: Motion.medium,
      curve: Motion.standard,
      margin: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: errored
              ? scheme.error.withValues(alpha: .55)
              : expanded
              ? scheme.primary.withValues(alpha: .45)
              : scheme.outlineVariant,
        ),
      ),
      child: Column(
        children: [
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => setState(() => _open = expanded ? null : id),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                title,
                                style: context.texts.labelLarge!.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (required)
                                Text(
                                  ' *',
                                  style: TextStyle(
                                    color: errored
                                        ? scheme.error
                                        : scheme.tertiary,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                            ],
                          ),
                          // 与正文同一套收放动效,避免两段动画节奏打架;
                          // 撑满宽度,收放动画期间不会被居中。
                          ExpandBody(
                            expanded: !expanded,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: SizedBox(
                                width: double.infinity,
                                child: Text(
                                  collapsedValue ?? (required ? '待填写' : '未设置'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.start,
                                  style: context.texts.bodySmall!.copyWith(
                                    color: errored
                                        ? scheme.error
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (errored)
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text(
                          '必填',
                          style: context.texts.labelSmall!.copyWith(
                            color: scheme.onErrorContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    AnimatedRotation(
                      turns: expanded ? 0.25 : 0,
                      duration: Motion.fast,
                      child: Icon(
                        Icons.chevron_right,
                        size: 20,
                        color: expanded
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ExpandBody(
            expanded: expanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: body,
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _fieldDeco(String hint) => InputDecoration(
    isDense: true,
    hintText: hint,
    filled: true,
    fillColor: context.scheme.surfaceContainerHigh,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
  );

  Widget _tokenPill(int n) {
    final scheme = context.scheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text('$n tokens', style: mono(context, size: 10.5)),
    );
  }

  Widget _miniAction(IconData icon, String label, VoidCallback onTap) {
    final scheme = context.scheme;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: scheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 折叠小节头:chevron 旋转 + 标题 + 状态后缀(可选/已加 N 个)。
  Widget _foldHeader({
    required bool open,
    required String title,
    required String suffix,
    required VoidCallback onTap,
    List<Widget> actions = const [],
  }) {
    final scheme = context.scheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            AnimatedRotation(
              turns: open ? 0 : -0.25,
              duration: Motion.fast,
              child: Icon(
                Icons.expand_more,
                size: 17,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              title,
              style: context.texts.labelMedium!.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              suffix,
              style: context.texts.labelSmall!.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            ...actions,
          ],
        ),
      ),
    );
  }

  Widget _nameBody(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _name,
          readOnly: _locked,
          style: context.texts.bodyLarge!.copyWith(fontWeight: FontWeight.w700),
          decoration: _fieldDeco('给${_def.label}起个名字').copyWith(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            suffixIcon: widget.cat == TagCategory.artist && !_locked
                ? Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: FilledButton.tonalIcon(
                      onPressed: _suggestCode,
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      icon: const Icon(Icons.auto_awesome, size: 13),
                      label: const Text('编号'),
                    ),
                  )
                : null,
            suffixIconConstraints: const BoxConstraints(
              minHeight: 32,
              minWidth: 40,
            ),
          ),
        ),
        if (widget.cat == TagCategory.character) ...[
          const SizedBox(height: 10),
          _foldHeader(
            open: _showAliases,
            title: '别名',
            suffix: _aliases.isEmpty ? '(可选)' : '(已加 ${_aliases.length} 个)',
            onTap: () => setState(() => _showAliases = !_showAliases),
          ),
          ExpandBody(
            expanded: _showAliases,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _ChipPicker(
                selected: _aliases,
                locked: _locked,
                placeholder: '输入别名…',
                onAdd: (t) => setState(() => _aliases.add(t)),
                onRemove: (t) => setState(() => _aliases.remove(t)),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _promptBody(ColorScheme scheme) {
    final import = _locked ? null : _importSource();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '正向',
              style: context.texts.labelMedium!.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
            _tokenPill(_tokens(_positive.text)),
            const Spacer(),
            if (import != null)
              _miniAction(Icons.download_outlined, import.$1, import.$2),
            if (!_locked)
              _miniAction(Icons.content_paste, '粘贴', () => _paste(_positive)),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _positive,
          readOnly: _locked,
          maxLines: widget.floating ? 7 : 8,
          minLines: widget.floating ? 4 : 5,
          style: mono(context, size: 12.5).copyWith(height: 1.6),
          decoration: _fieldDeco(switch (widget.cat) {
            TagCategory.artist => '例如: wlop, rurudo',
            TagCategory.character => '例如: 1girl, cat ears, white hair',
            TagCategory.scene => '例如: cherry blossoms, garden, sunlight',
            _ => '输入提示词…',
          }),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        _foldHeader(
          open: _showNegative,
          title: '负面提示词',
          suffix: _negative.text.trim().isEmpty ? '(可选)' : '',
          onTap: () => setState(() => _showNegative = !_showNegative),
          actions: [
            if (_negative.text.trim().isNotEmpty)
              _tokenPill(_tokens(_negative.text)),
            if (_showNegative && !_locked)
              _miniAction(Icons.content_paste, '粘贴', () => _paste(_negative)),
          ],
        ),
        ExpandBody(
          expanded: _showNegative,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TextField(
              controller: _negative,
              readOnly: _locked,
              maxLines: 4,
              minLines: 3,
              style: mono(context, size: 12.5).copyWith(height: 1.6),
              decoration: _fieldDeco('例如: bad anatomy, worst quality'),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
      ],
    );
  }

  Widget _previewBody(
    ColorScheme scheme, {
    bool desktop = false,
    bool fitted = false,
  }) {
    if (desktop && !fitted && _slotCount == 1) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = math.min(
            constraints.maxWidth,
            math.max(180, constraints.maxHeight - (_locked ? 0 : 92)) *
                _def.previewAspect,
          );
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              child: _previewBody(scheme, desktop: true, fitted: true),
            ),
          );
        },
      );
    }
    final hint = switch (widget.cat) {
      TagCategory.character => '建议竖图 832×1216,用于展示角色全身',
      TagCategory.artist => '横图 1216×832 · 四格画风样例,首张为封面',
      _ => '建议方图 1024×1024,展示场景氛围',
    };
    final single = _slotCount == 1;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (desktop && single)
          AspectRatio(
            key: const ValueKey('tag-editor-portrait'),
            aspectRatio: _def.previewAspect,
            child: _slotView(0, fit: BoxFit.contain),
          )
        else if (desktop)
          Expanded(
            child: single
                ? _slotView(0, fit: BoxFit.contain)
                : GridView.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: _def.previewAspect,
                    children: [
                      for (var i = 0; i < _slotCount; i++)
                        _slotView(i, fit: BoxFit.contain),
                    ],
                  ),
          )
        else if (single)
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: _def.previewAspect < 1 ? 210 : 250,
              ),
              child: AspectRatio(
                aspectRatio: _def.previewAspect,
                child: _slotView(0),
              ),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
            ),
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              childAspectRatio: _def.previewAspect,
              children: [for (var i = 0; i < _slotCount; i++) _slotView(i)],
            ),
          ),
        if (!_locked) ...[
          const SizedBox(height: 12),
          // 三等分固定布局:生成中也不改 flex、不加长文案(进度在槽位上显示),
          // 否则相邻按钮被挤到换行竖排。
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: desktop ? _previewButtonStyle() : null,
                  onPressed: _generating ? null : () => _pickImages(),
                  icon: const Icon(Icons.upload_outlined, size: 16),
                  label: const Text('上传', maxLines: 1, softWrap: false),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  style: desktop ? _previewButtonStyle() : null,
                  onPressed: _generating ? null : () => _pickFromHistory(),
                  icon: const Icon(Icons.history, size: 16),
                  label: const Text('历史', maxLines: 1, softWrap: false),
                ),
              ),
              if (_canGenerate) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    style: desktop ? _previewButtonStyle() : null,
                    onPressed: _generating || _positive.text.trim().isEmpty
                        ? null
                        : () => _generateInto([
                            for (var i = 0; i < _slotCount; i++) i,
                          ]),
                    icon: _generating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_fix_high_outlined, size: 16),
                    label: Text(
                      _generating ? '生成中' : '生成',
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              hint,
              textAlign: TextAlign.center,
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
          ),
        ],
      ],
    );
    return desktop
        ? ImageDropRegion(
            key: const ValueKey('tag-preview-image-drop'),
            label: '导入预览图',
            enabled: !_locked && !_busy && !_generating,
            multiple: !single,
            onDrop: (images, _) async {
              if (images.length > _slotCount) {
                throw FormatException('预览最多接收 $_slotCount 张图片，请减少后重试');
              }
              _applyPickedImages(images);
            },
            child: content,
          )
        : content;
  }

  ButtonStyle _previewButtonStyle() => FilledButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    minimumSize: const Size(0, 36),
    textStyle: context.texts.labelLarge?.copyWith(fontSize: 12),
    visualDensity: VisualDensity.compact,
  );

  Widget _slotView(int i, {BoxFit fit = BoxFit.cover}) {
    final scheme = context.scheme;
    final s = _slots[i];
    final generating = _genIndex == i;
    final isCover = _slotCount > 1 && s.filled && i == _cover;
    Widget content;
    if (s.bytes != null) {
      content = Image.memory(s.bytes!, fit: fit);
    } else if (s.ref?.isNotEmpty ?? false) {
      final r = s.ref!;
      content = r.startsWith('http')
          ? RemoteImage(
              r,
              fit: fit,
              errorBuilder: (_, _, _) => _emptySlotIcon(scheme),
            )
          : Image.file(
              File(r),
              fit: fit,
              errorBuilder: (_, _, _) => _emptySlotIcon(scheme),
            );
    } else {
      content = _emptySlotIcon(scheme);
    }
    final tile = Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(11),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _locked || generating
            ? null
            : () => s.filled ? _slotMenu(i) : _pickImages(into: i),
        child: Stack(
          fit: StackFit.expand,
          children: [
            content,
            if (isCover)
              Positioned(
                top: 5,
                right: 5,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '封面',
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 10,
                    ),
                  ),
                ),
              ),
            if (generating)
              Container(
                color: scheme.scrim.withValues(alpha: .68),
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_genProgress != null && _genProgress!.$2 > 0) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: _genProgress!.$1 / _genProgress!.$2,
                          minHeight: 5,
                          backgroundColor: Colors.white24,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        '${_genProgress!.$1} / ${_genProgress!.$2}',
                        style: mono(context, size: 11, color: Colors.white),
                      ),
                    ] else
                      const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    return ref.watch(desktopModeProvider)
        ? ImageDropRegion(
            key: ValueKey('tag-preview-slot-drop-$i'),
            label: '替换这张预览图',
            enabled: !_locked && !_busy && !_generating,
            onDrop: (images, _) async => _applyPickedImages(images, into: i),
            child: tile,
          )
        : tile;
  }

  Widget _emptySlotIcon(ColorScheme scheme) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.add_photo_alternate_outlined,
          size: 26,
          color: scheme.outline,
        ),
        const SizedBox(height: 3),
        Text(
          '点击上传',
          style: context.texts.labelSmall!.copyWith(
            color: scheme.outline,
            fontSize: 10,
          ),
        ),
      ],
    ),
  );

  /// 适用模型多选。按分档分组列 —— 十二个模型平铺一屏放不下,
  /// 而用户心里本来就是「这串是给 V5 调的」这个粒度。
  Widget _modelsBody(ColorScheme scheme) {
    final groups = <ArtistModelGroup, List<ArtistModelDef>>{};
    for (final m in kArtistModels) {
      (groups[m.group] ??= []).add(m);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _models.isEmpty ? '一个都不选 = 通用,在所有模型下都会出现' : '已选 ${_models.length} 个',
          style: context.texts.labelSmall!.copyWith(color: scheme.outline),
        ),
        const SizedBox(height: 10),
        for (final e in groups.entries) ...[
          Text(
            e.key.filterLabel,
            style: context.texts.labelMedium!.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final m in e.value)
                FilterChip(
                  label: Text(m.short),
                  selected: _models.contains(m.id),
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  shape: const StadiumBorder(),
                  labelStyle: context.texts.labelMedium!.copyWith(
                    fontWeight: FontWeight.w600,
                    color: _models.contains(m.id)
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                  selectedColor: scheme.primary,
                  backgroundColor: scheme.surfaceContainerHigh,
                  side: BorderSide.none,
                  onSelected: (on) => setState(
                    () => on ? _models.add(m.id) : _models.remove(m.id),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        // 目录里没有的 id(模型下线 / 来自更新的客户端)也要能看见并取消,
        // 否则它会一直挂在这条画风上、还没法处理。
        if (_models.any((id) => findArtistModel(id) == null)) ...[
          Text(
            '未知模型(来自其它版本)',
            style: context.texts.labelMedium!.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final id in _models.where((i) => findArtistModel(i) == null))
                InputChip(
                  label: Text(id),
                  visualDensity: VisualDensity.compact,
                  shape: const StadiumBorder(),
                  backgroundColor: scheme.surfaceContainerHigh,
                  side: BorderSide.none,
                  onDeleted: () => setState(() => _models.remove(id)),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _tagsBody(ColorScheme scheme) {
    final known =
        ref.watch(tagLibraryProvider).value?.knownTags(widget.cat) ??
        const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '已选 ${_tags.length}',
              style: context.texts.labelMedium!.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _ChipPicker(
          selected: _tags.toList(),
          pool: [
            for (final t in known)
              if (!_tags.contains(t)) t,
          ],
          chipPrefix: '#',
          placeholder: '新建标签…',
          onAdd: (t) => setState(() => _tags.add(t)),
          onRemove: (t) => setState(() => _tags.remove(t)),
        ),
      ],
    );
  }

  /// 编辑态管理动作行(平铺常驻,不藏菜单)。
  Widget _managementRow(ColorScheme scheme) {
    final origin = _edit!.origin;
    final buttons = <Widget>[
      if (origin == TagOrigin.created) ...[
        OutlinedButton.icon(
          onPressed: _busy ? null : _unpublish,
          icon: const Icon(Icons.undo, size: 16),
          label: const Text('取消发布'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _transfer,
          icon: const Icon(Icons.manage_accounts_outlined, size: 16),
          label: const Text('转让'),
        ),
      ],
      if (origin == TagOrigin.favorited)
        OutlinedButton.icon(
          onPressed: _busy ? null : _saveAsCopy,
          icon: const Icon(Icons.file_copy_outlined, size: 16),
          label: const Text('另存为本地副本'),
        ),
      OutlinedButton.icon(
        onPressed: _busy ? null : _delete,
        style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
        icon: const Icon(Icons.delete_outline, size: 16),
        label: const Text('删除'),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 4),
      child: Wrap(spacing: 10, runSpacing: 8, children: buttons),
    );
  }

  // ---- Footer ----

  ButtonStyle _outStyle() => OutlinedButton.styleFrom(
    minimumSize: Size(0, widget.floating ? 44 : 52),
    side: widget.floating ? BorderSide.none : null,
    backgroundColor: widget.floating ? context.scheme.primaryContainer : null,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  );

  Widget _footer(ColorScheme scheme) {
    final origin = _edit?.origin;
    final List<Widget> children;
    if (!_isEdit) {
      children = _def.hasPublic
          ? [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _saveLocal,
                  style: _outStyle(),
                  child: const Text('保存到本地', maxLines: 1),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _primaryBtn(
                  icon: Icons.public,
                  label: '保存并发布',
                  onPressed: _publish,
                ),
              ),
            ]
          : [
              Expanded(
                child: _primaryBtn(
                  icon: Icons.save_outlined,
                  label: '保存',
                  onPressed: _saveLocal,
                ),
              ),
            ];
    } else if (origin == TagOrigin.created) {
      children = [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _saveAsCopy,
            style: _outStyle(),
            icon: const Icon(Icons.file_copy_outlined, size: 16),
            label: const Text('存为本地副本'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _primaryBtn(
            icon: Icons.cloud_sync_outlined,
            label: '保存并同步',
            onPressed: _syncPublic,
          ),
        ),
      ];
    } else if (_def.hasPublic && origin == TagOrigin.local) {
      // 本地条目也该有发布的路。以前编辑态只有 created 给两个按钮,本地条目
      // 只剩一个「保存修改」—— 想把攒好的本地 OC / 画风发出去,只能照着重新
      // 建一条,原来那条还得手动删。版式与创建态对齐:左保存、右发布。
      //
      // 复用 [_publish] 是安全的:它用 `_buildEntry` 建条目,而 `_entryId` 在
      // 编辑态就是原条目的 id,upsert 是原地把 origin 翻成 created + 补上
      // publicId,不会多出一条。favorited 不给这个按钮 —— 那是别人的东西,
      // 要改要发得先「存为本地副本」。
      children = [
        Expanded(
          child: OutlinedButton(
            onPressed: _busy ? null : _saveLocal,
            style: _outStyle(),
            child: const Text('保存修改', maxLines: 1),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _primaryBtn(
            icon: Icons.public,
            label: '保存并发布',
            onPressed: _publish,
          ),
        ),
      ];
    } else {
      children = [
        Expanded(
          child: _primaryBtn(
            icon: Icons.save_outlined,
            label: _locked ? '保存标签修改' : '保存修改',
            onPressed: _locked ? _saveTagsOnly : _saveLocal,
          ),
        ),
      ];
    }
    return Material(
      key: const ValueKey('tag-editor-save-actions'),
      color: widget.floating ? Colors.transparent : scheme.surfaceContainer,
      child: Padding(
        padding: widget.floating
            ? const EdgeInsets.only(top: 10)
            : const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Row(children: children),
      ),
    );
  }

  /// 主按钮:必填未齐时视觉禁用但可点(点了亮校验并展开缺失卡),忙时真禁用。
  Widget _primaryBtn({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Opacity(
      opacity: _canSave ? 1 : .45,
      child: FilledButton.icon(
        onPressed: _busy ? null : onPressed,
        style: FilledButton.styleFrom(
          minimumSize: Size(0, widget.floating ? 44 : 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        icon: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, size: 17),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
    );
  }
}

/// 三段式 chip 选择器:已选实底 chip(点 × 移除)→ 可选描边 chip(点 + 加入)
/// → 「+ 新建」点击原地变内联输入(提交/失焦空则收起)。别名场景无池。
class _ChipPicker extends StatefulWidget {
  const _ChipPicker({
    required this.selected,
    this.pool = const [],
    this.chipPrefix = '',
    required this.placeholder,
    required this.onAdd,
    required this.onRemove,
    this.locked = false,
  });

  final List<String> selected;
  final List<String> pool;
  final String chipPrefix;
  final String placeholder;
  final ValueChanged<String> onAdd;
  final ValueChanged<String> onRemove;
  final bool locked;

  @override
  State<_ChipPicker> createState() => _ChipPickerState();
}

class _ChipPickerState extends State<_ChipPicker> {
  bool _creating = false;
  final _input = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _input.text.trim().isEmpty && _creating) {
        setState(() => _creating = false);
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final t = _input.text.trim();
    if (t.isNotEmpty && !widget.selected.contains(t)) {
      widget.onAdd(t);
    }
    _input.clear();
    setState(() => _creating = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final t in widget.selected)
            _chip(
              scheme,
              label: '${widget.chipPrefix}$t',
              filled: true,
              trailing: widget.locked ? null : Icons.close,
              onTap: widget.locked ? null : () => widget.onRemove(t),
            ),
          for (final t in widget.pool)
            _chip(
              scheme,
              label: '${widget.chipPrefix}$t',
              leading: Icons.add,
              onTap: widget.locked ? null : () => widget.onAdd(t),
            ),
          if (!widget.locked)
            _creating
                ? Container(
                    height: 34,
                    padding: const EdgeInsets.only(left: 12, right: 4),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(17),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: .6),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 110,
                          child: TextField(
                            controller: _input,
                            focusNode: _focus,
                            autofocus: true,
                            style: context.texts.labelLarge,
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              hintText: widget.placeholder,
                            ),
                            onSubmitted: (_) => _submit(),
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            Icons.add,
                            size: 17,
                            color: scheme.primary,
                          ),
                          onPressed: _submit,
                        ),
                      ],
                    ),
                  )
                : _chip(
                    scheme,
                    label: '新建',
                    leading: Icons.add,
                    dashed: true,
                    onTap: () => setState(() => _creating = true),
                  ),
        ],
      ),
    );
  }

  Widget _chip(
    ColorScheme scheme, {
    required String label,
    bool filled = false,
    bool dashed = false,
    IconData? leading,
    IconData? trailing,
    VoidCallback? onTap,
  }) {
    final fg = filled ? scheme.onPrimary : scheme.onSurfaceVariant;
    return Material(
      color: filled ? scheme.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(17),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: filled
              ? null
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(17),
                  border: Border.all(
                    // Flutter 无原生虚线边框,「新建」以浅色实线近似
                    color: dashed ? scheme.outline : scheme.outlineVariant,
                  ),
                ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                Icon(leading, size: 14, color: fg),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: context.texts.labelLarge!.copyWith(
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 4),
                Icon(trailing, size: 14, color: fg),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 图库缩略图(异步懒读)。
class _HistoryThumb extends ConsumerWidget {
  const _HistoryThumb({required this.id, required this.onTap});

  final String id;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thumb = ref.watch(galleryThumbProvider(id)).value;
    return Material(
      color: context.scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: thumb == null
            ? const SizedBox.expand()
            : Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true),
      ),
    );
  }
}
