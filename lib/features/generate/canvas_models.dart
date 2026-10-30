import 'models.dart';
import '../editor/editor_models.dart'
    show PromptFoldLink, pickEditorText, validPromptFoldLinks;

/// 画布名的长度上限(改名框与「· 副本」后缀共用)。
const kCanvasNameMax = 32;

/// 一张画布 = 画面用到的全部内容:正负提示词(连同编辑器草稿)、角色(连同
/// 定位开关)、提示词预设、Vibe、角色参考、Krea 风格参考、LoRA、图生图底图与
/// 重绘,以及模型、尺寸、种子、采样参数和重绘放大(见 [CanvasSampling])。
///
/// 全局一份的只剩张数、循环档、面板开合和点数。
/// 写这些内容的地方大多是同步的;会跨过切画布的异步流程各自收口:提示词按
/// 画布 id 回写,LoRA 下载在所有画布里找占位条转正,选图加参考图时切走了就作废。
class CanvasPrompts {
  const CanvasPrompts({
    this.prompt = '',
    this.promptRaw = '',
    this.negativePrompt = '',
    this.negativePromptRaw = '',
    this.promptFoldLinks = const [],
    this.sections = const [],
    this.characters = const [],
    this.useCoords = false,
    this.promptPresetId = kDefaultPromptPresetId,
    this.sampling,
    this.vibes = const [],
    this.normalizeVibe = true,
    this.charRefs = const [],
    this.kreaStyleRefs = const [],
    this.kreaStyleRefWeight = 1.0,
    this.loras = const [],
    this.loraMem = const {},
    this.img2img,
    this.inpaint,
  });

  /// 从完整创作状态里取出跟画布走的那几项。
  factory CanvasPrompts.of(GenerateState s) => CanvasPrompts(
    prompt: s.prompt,
    promptRaw: s.promptRaw,
    negativePrompt: s.negativePrompt,
    negativePromptRaw: s.negativePromptRaw,
    promptFoldLinks: s.promptFoldLinks,
    sections: s.sections,
    characters: s.characters,
    useCoords: s.params.useCoords,
    promptPresetId: s.promptPresetId,
    sampling: CanvasSampling.of(s.params),
    vibes: s.vibes,
    normalizeVibe: s.params.normalizeVibe,
    charRefs: s.charRefs,
    kreaStyleRefs: s.kreaStyleRefs,
    kreaStyleRefWeight: s.kreaStyleRefWeight,
    loras: s.loras,
    loraMem: s.loraMem,
    img2img: s.img2img,
    inpaint: s.inpaint,
  );

  final String prompt;
  final String promptRaw;
  final String negativePrompt;
  final String negativePromptRaw;
  final List<PromptFoldLink> promptFoldLinks;

  /// 主提示词分区(见 [GenerateState.sections])。
  final List<PromptSection> sections;
  final List<CharacterPrompt> characters;

  /// 角色定位开关(`params.useCoords`):跟角色站位绑在一起,所以随画布走。
  final bool useCoords;

  /// 这张画布的提示词预设(见 [GenerateState.promptPresetId])。
  final String promptPresetId;

  /// 这张画布的模型和采样参数。null 只出现在它们跟画布走之前的老存档里,
  /// 套用时沿用当前那份;载入时就会补成当时的全局参数。
  final CanvasSampling? sampling;

  final List<VibeItem> vibes;

  /// 多张 Vibe 时强度按比例缩(`params.normalizeVibe`)。
  final bool normalizeVibe;
  final List<CharRefItem> charRefs;
  final List<KreaStyleRefItem> kreaStyleRefs;
  final double kreaStyleRefWeight;

  /// 挂着的 LoRA 与另一个底模收起来的那份(见 [GenerateState.loraMem]),
  /// 对应的是这张画布自己的模型。
  final List<ActiveLora> loras;
  final Map<String, List<ActiveLora>> loraMem;
  final Img2ImgConfig? img2img;
  final InpaintJob? inpaint;

  /// 把这组内容套到完整创作状态上,其余全局设置原样不动。
  GenerateState applyTo(GenerateState s) {
    var params = sampling?.writeInto(s.params) ?? s.params;
    if (params.useCoords != useCoords ||
        params.normalizeVibe != normalizeVibe) {
      params = params.copyWith(
        useCoords: useCoords,
        normalizeVibe: normalizeVibe,
      );
    }
    return s.copyWith(
      prompt: prompt,
      promptRaw: promptRaw,
      negativePrompt: negativePrompt,
      negativePromptRaw: negativePromptRaw,
      promptFoldLinks: promptFoldLinks,
      sections: sections,
      characters: characters,
      params: identical(params, s.params) ? null : params,
      promptPresetId: promptPresetId,
      vibes: vibes,
      charRefs: charRefs,
      kreaStyleRefs: kreaStyleRefs,
      kreaStyleRefWeight: kreaStyleRefWeight,
      loras: loras,
      loraMem: loraMem,
      img2img: img2img,
      inpaint: inpaint,
    );
  }

  /// 列表、表和图片配置按引用比:创作状态改别的字段时它们原样沿用,改它们必换新的。
  bool sameAs(CanvasPrompts o) =>
      prompt == o.prompt &&
      promptRaw == o.promptRaw &&
      negativePrompt == o.negativePrompt &&
      negativePromptRaw == o.negativePromptRaw &&
      identical(promptFoldLinks, o.promptFoldLinks) &&
      identical(sections, o.sections) &&
      identical(characters, o.characters) &&
      useCoords == o.useCoords &&
      promptPresetId == o.promptPresetId &&
      identical(vibes, o.vibes) &&
      normalizeVibe == o.normalizeVibe &&
      identical(charRefs, o.charRefs) &&
      identical(kreaStyleRefs, o.kreaStyleRefs) &&
      kreaStyleRefWeight == o.kreaStyleRefWeight &&
      identical(loras, o.loras) &&
      identical(loraMem, o.loraMem) &&
      identical(img2img, o.img2img) &&
      identical(inpaint, o.inpaint) &&
      switch ((sampling, o.sampling)) {
        (null, null) => true,
        (final a?, final b?) => a.sameAs(b),
        _ => false,
      };

  /// [img2img]、[inpaint] 传 null 是清掉;不传保持不动。
  CanvasPrompts copyWith({
    String? prompt,
    String? promptRaw,
    String? negativePrompt,
    String? negativePromptRaw,
    List<PromptFoldLink>? promptFoldLinks,
    List<PromptSection>? sections,
    List<CharacterPrompt>? characters,
    bool? useCoords,
    String? promptPresetId,
    CanvasSampling? sampling,
    List<VibeItem>? vibes,
    bool? normalizeVibe,
    List<CharRefItem>? charRefs,
    List<KreaStyleRefItem>? kreaStyleRefs,
    double? kreaStyleRefWeight,
    List<ActiveLora>? loras,
    Map<String, List<ActiveLora>>? loraMem,
    Object? img2img = _unset,
    Object? inpaint = _unset,
  }) => CanvasPrompts(
    prompt: prompt ?? this.prompt,
    promptRaw: promptRaw ?? this.promptRaw,
    negativePrompt: negativePrompt ?? this.negativePrompt,
    negativePromptRaw: negativePromptRaw ?? this.negativePromptRaw,
    promptFoldLinks:
        prompt == null &&
            negativePrompt == null &&
            promptRaw == null &&
            negativePromptRaw == null &&
            promptFoldLinks == null
        ? this.promptFoldLinks
        : validPromptFoldLinks(
            pickEditorText(promptRaw ?? this.promptRaw, prompt ?? this.prompt),
            pickEditorText(
              negativePromptRaw ?? this.negativePromptRaw,
              negativePrompt ?? this.negativePrompt,
            ),
            promptFoldLinks ?? this.promptFoldLinks,
          ),
    sections: sections ?? this.sections,
    characters: characters ?? this.characters,
    useCoords: useCoords ?? this.useCoords,
    promptPresetId: promptPresetId ?? this.promptPresetId,
    sampling: sampling ?? this.sampling,
    vibes: vibes ?? this.vibes,
    normalizeVibe: normalizeVibe ?? this.normalizeVibe,
    charRefs: charRefs ?? this.charRefs,
    kreaStyleRefs: kreaStyleRefs ?? this.kreaStyleRefs,
    kreaStyleRefWeight: kreaStyleRefWeight ?? this.kreaStyleRefWeight,
    loras: loras ?? this.loras,
    loraMem: loraMem ?? this.loraMem,
    img2img: img2img == _unset ? this.img2img : img2img as Img2ImgConfig?,
    inpaint: inpaint == _unset ? this.inpaint : inpaint as InpaintJob?,
  );

  /// 换掉采样参数,可以换成 null(读老存档时用)。
  CanvasPrompts withSampling(CanvasSampling? sampling) => CanvasPrompts(
    prompt: prompt,
    promptRaw: promptRaw,
    negativePrompt: negativePrompt,
    negativePromptRaw: negativePromptRaw,
    promptFoldLinks: promptFoldLinks,
    sections: sections,
    characters: characters,
    useCoords: useCoords,
    promptPresetId: promptPresetId,
    sampling: sampling,
    vibes: vibes,
    normalizeVibe: normalizeVibe,
    charRefs: charRefs,
    kreaStyleRefs: kreaStyleRefs,
    kreaStyleRefWeight: kreaStyleRefWeight,
    loras: loras,
    loraMem: loraMem,
    img2img: img2img,
    inpaint: inpaint,
  );

  /// 在挂着的和收起来的每一份 LoRA 列表上做 [change](返回 null = 这份里没有
  /// 要改的);一份都没改到返回 null。
  CanvasPrompts? changeLoras(
    List<ActiveLora>? Function(List<ActiveLora>) change,
  ) {
    final active = change(loras);
    final mem = <String, List<ActiveLora>>{};
    for (final e in loraMem.entries) {
      final stashed = change(e.value);
      if (stashed != null) mem[e.key] = stashed;
    }
    if (active == null && mem.isEmpty) return null;
    return copyWith(
      loras: active,
      loraMem: mem.isEmpty ? null : {...loraMem, ...mem},
    );
  }
}

const _unset = Object();

/// 跟画布走的出图参数:模型、尺寸、种子,高级设置「采样」那一组(NAI / Anima /
/// Krea 各一套)加 CFG Rescale,连同 Anima / Krea 的分档记忆,以及重绘放大。
///
/// 模型和它的采样参数总是一起套回去,所以档位天然对得上。
class CanvasSampling {
  const CanvasSampling({
    required this.model,
    this.naiEffort = NaiEffort.high,
    required this.width,
    required this.height,
    required this.seed,
    required this.steps,
    required this.cfg,
    required this.varietyPlus,
    required this.sampler,
    required this.noiseSchedule,
    required this.cfgRescale,
    required this.animaSteps,
    required this.animaCfg,
    required this.animaSampler,
    required this.animaScheduler,
    required this.kreaSteps,
    required this.kreaCfg,
    required this.kreaSampler,
    required this.kreaScheduler,
    required this.modalMem,
    required this.hires,
  });

  factory CanvasSampling.of(GenParams p) => CanvasSampling(
    model: p.model,
    naiEffort: p.naiEffort,
    width: p.width,
    height: p.height,
    seed: p.seed,
    steps: p.steps,
    cfg: p.cfg,
    varietyPlus: p.varietyPlus,
    sampler: p.sampler,
    noiseSchedule: p.noiseSchedule,
    cfgRescale: p.cfgRescale,
    animaSteps: p.animaSteps,
    animaCfg: p.animaCfg,
    animaSampler: p.animaSampler,
    animaScheduler: p.animaScheduler,
    kreaSteps: p.kreaSteps,
    kreaCfg: p.kreaCfg,
    kreaSampler: p.kreaSampler,
    kreaScheduler: p.kreaScheduler,
    modalMem: p.modalMem,
    hires: p.hires,
  );

  final String model;
  final NaiEffort naiEffort;
  final int width;
  final int height;

  /// 空串 = 每次随机。
  final String seed;
  final int steps;
  final double cfg;
  final bool varietyPlus;
  final String sampler;
  final String noiseSchedule;
  final double cfgRescale;
  final int animaSteps;
  final double animaCfg;
  final String animaSampler;
  final String animaScheduler;
  final int kreaSteps;
  final double kreaCfg;
  final String kreaSampler;
  final String kreaScheduler;
  final Map<String, ModalSampling> modalMem;
  final HiresConfig hires;

  /// 原样写进 [p],连 [model] 一起。
  GenParams writeInto(GenParams p) => p.copyWith(
    model: model,
    naiEffort: naiEffort,
    width: width,
    height: height,
    seed: seed,
    steps: steps,
    cfg: cfg,
    varietyPlus: varietyPlus,
    sampler: sampler,
    noiseSchedule: noiseSchedule,
    cfgRescale: cfgRescale,
    animaSteps: animaSteps,
    animaCfg: animaCfg,
    animaSampler: animaSampler,
    animaScheduler: animaScheduler,
    kreaSteps: kreaSteps,
    kreaCfg: kreaCfg,
    kreaSampler: kreaSampler,
    kreaScheduler: kreaScheduler,
    modalMem: modalMem,
    hires: hires,
  );

  /// 分档记忆、重绘放大按引用比:参数没动时原样沿用,改了必换新的。
  bool sameAs(CanvasSampling o) =>
      model == o.model &&
      naiEffort == o.naiEffort &&
      width == o.width &&
      height == o.height &&
      seed == o.seed &&
      steps == o.steps &&
      cfg == o.cfg &&
      varietyPlus == o.varietyPlus &&
      sampler == o.sampler &&
      noiseSchedule == o.noiseSchedule &&
      cfgRescale == o.cfgRescale &&
      animaSteps == o.animaSteps &&
      animaCfg == o.animaCfg &&
      animaSampler == o.animaSampler &&
      animaScheduler == o.animaScheduler &&
      kreaSteps == o.kreaSteps &&
      kreaCfg == o.kreaCfg &&
      kreaSampler == o.kreaSampler &&
      kreaScheduler == o.kreaScheduler &&
      identical(modalMem, o.modalMem) &&
      identical(hires, o.hires);
}

class CanvasDraft {
  const CanvasDraft({
    required this.id,
    required this.name,
    required this.prompts,
  });

  final String id;
  final String name;
  final CanvasPrompts prompts;

  CanvasDraft copyWith({String? name, CanvasPrompts? prompts}) => CanvasDraft(
    id: id,
    name: name ?? this.name,
    prompts: prompts ?? this.prompts,
  );
}

/// 默认画布的名字,固定不能改。
const kDefaultCanvasName = '默认画布';

/// 画布集合。**最上面那张是默认画布**:固定置顶、拖不动、删不掉、名字固定叫
/// [kDefaultCanvasName],别的画布也排不到它前面 —— 不另存标记,老存档里排第一的
/// 那张载入时改叫默认画布(内容不动)。
class CanvasWorkspace {
  const CanvasWorkspace({
    required this.canvases,
    required this.activeId,
    this.nextId = 2,
  });

  factory CanvasWorkspace.single(CanvasPrompts prompts) => CanvasWorkspace(
    canvases: [
      CanvasDraft(id: 'canvas1', name: kDefaultCanvasName, prompts: prompts),
    ],
    activeId: 'canvas1',
  );

  final List<CanvasDraft> canvases;
  final String activeId;
  final int nextId;

  CanvasDraft get active => find(activeId) ?? canvases.first;

  /// 默认画布(最上面那张)的 id。
  String get defaultId => canvases.first.id;

  CanvasDraft? find(String id) {
    for (final canvas in canvases) {
      if (canvas.id == id) return canvas;
    }
    return null;
  }

  CanvasWorkspace copyWith({
    List<CanvasDraft>? canvases,
    String? activeId,
    int? nextId,
  }) => CanvasWorkspace(
    canvases: canvases ?? this.canvases,
    activeId: activeId ?? this.activeId,
    nextId: nextId ?? this.nextId,
  );
}
