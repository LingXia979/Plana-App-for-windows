import 'models.dart';
import '../editor/editor_models.dart'
    show PromptFoldLink, pickEditorText, validPromptFoldLinks;

/// 画布名的长度上限(改名框与「· 副本」后缀共用)。
const kCanvasNameMax = 32;

/// 一张画布 = 一组提示词 + 出图参数:正负提示词(连同编辑器草稿)、角色(连同
/// 定位开关)、提示词预设,以及模型、尺寸、种子和高级设置里的采样那一组
/// (见 [CanvasSampling])。
///
/// Vibe、角色参考、图生图与重绘、重绘放大、LoRA 都**不跟画布走**,全局一份。
/// LoRA 按底模各记一份,模型换了底模就跟着换(见 [GenerateState.withLoraBaseOf])。
/// 凡是会在途中切画布的异步流程(LoRA 下载、重绘编辑、参考图处理)写的都是
/// 全局那份,不存在写错画布;写模型、尺寸、种子和采样参数的地方全是同步的;
/// 剩下几处异步写提示词的地方各自按画布 id 收口。
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

  /// 把这组内容套到完整创作状态上,其余全局设置原样不动。
  GenerateState applyTo(GenerateState s) {
    // 模型换了 LoRA 底模,就把挂载列表换成那个底模上次挂的(LoRA 仍是全局一份)
    final base = switch (sampling) {
      final sm? => s.withLoraBaseOf(sm.model),
      null => s,
    };
    var params = sampling?.writeInto(base.params) ?? base.params;
    if (params.useCoords != useCoords) {
      params = params.copyWith(useCoords: useCoords);
    }
    return base.copyWith(
      prompt: prompt,
      promptRaw: promptRaw,
      negativePrompt: negativePrompt,
      negativePromptRaw: negativePromptRaw,
      promptFoldLinks: promptFoldLinks,
      sections: sections,
      characters: characters,
      params: identical(params, base.params) ? null : params,
      promptPresetId: promptPresetId,
    );
  }

  /// 角色、分区列表按引用比:创作状态改别的字段时列表原样沿用,改它们必换新列表。
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
      switch ((sampling, o.sampling)) {
        (null, null) => true,
        (final a?, final b?) => a.sameAs(b),
        _ => false,
      };

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
  );
}

/// 跟画布走的出图参数:模型、尺寸、种子,高级设置「采样」那一组(NAI / Anima /
/// Krea 各一套)加 CFG Rescale,连同 Anima / Krea 的分档记忆。
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
  );

  /// 分档记忆按引用比:参数没动时它原样沿用,换档必换新表。
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
      identical(modalMem, o.modalMem);
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
