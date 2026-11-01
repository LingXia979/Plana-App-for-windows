import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/nai_proxy.dart';
import '../../core/net/nai_endpoint.dart';
import '../../core/net/network_proxy.dart';
import '../../core/net/proxy_import.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/image_drop.dart';
import '../../core/ui/settings_scaffold.dart';
import '../../core/util/image_pick.dart';

class NetworkSettingsPage extends ConsumerStatefulWidget {
  const NetworkSettingsPage({super.key});

  @override
  ConsumerState<NetworkSettingsPage> createState() =>
      _NetworkSettingsPageState();
}

class _NetworkSettingsPageState extends ConsumerState<NetworkSettingsPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _address;
  late bool _bypassLocal;
  late ProxySoftware _software;
  bool _expanded = false;
  bool _toggling = false;
  String? _toggleError;
  bool _importing = false;
  int _importGeneration = 0;
  String? _importMessage;
  bool _saving = false;
  bool _testing = false;
  String? _saveMessage;
  String? _testMessage;
  int _probeGeneration = 0;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(networkProxyProvider);
    _address = TextEditingController(text: saved.address);
    _bypassLocal = saved.bypassLocal;
    _software = saved.software;
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  NetworkProxySettings get _draft => NetworkProxySettings(
    enabled: ref.read(networkProxyProvider).enabled,
    address: _address.text,
    bypassLocal: _bypassLocal,
    software: _software,
  );

  void _changed() {
    _importGeneration++;
    _importMessage = null;
    _probeGeneration++;
    _testMessage = null;
    _saveMessage = null;
  }

  Future<void> _setEnabled(bool enabled) async {
    if (_toggling || _saving) return;
    setState(() {
      _toggling = true;
      _toggleError = null;
    });
    try {
      await ref.read(networkProxyProvider.notifier).setEnabled(enabled);
    } catch (_) {
      if (mounted) {
        setState(() {
          _toggleError = '开关已在本次运行生效，但保存失败，重启可能丢失。请检查磁盘后重试。';
        });
      }
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final next = _draft;
    setState(() {
      _saving = true;
      _saveMessage = null;
    });
    try {
      await ref
          .read(networkProxyProvider.notifier)
          .saveConfiguration(
            address: next.address,
            bypassLocal: next.bypassLocal,
            software: next.software,
          );
      ref.invalidate(detectedProxySoftwareProvider(next.address));
      if (!mounted) return;
      setState(() {
        _address.text = ref.read(networkProxyProvider).address;
        _toggleError = null;
        _saveMessage = '已保存并应用。新请求使用当前设置，进行中的任务和连接不会被重启。';
      });
      _form.currentState!.validate();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saveMessage = '已在本次运行生效，但保存失败，重启可能丢失。请检查磁盘后重新保存。';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<List<ProxyAddressCandidate>> _recognize(Uint8List bytes) async =>
      parseProxyAddresses(await ref.read(proxyImageRecognizerProvider)(bytes));

  Future<void> _import(
    Future<List<ProxyAddressCandidate>?> Function() read,
  ) async {
    if (_importing || _saving) return;
    final generation = ++_importGeneration;
    setState(() {
      _expanded = true;
      _importing = true;
      _importMessage = null;
    });
    try {
      final candidates = await read();
      if (!mounted || generation != _importGeneration || candidates == null) {
        return;
      }
      if (candidates.isEmpty) {
        throw const FormatException(
          '未找到 HTTP / Mixed 代理地址。请截取端口设置区域，或复制完整地址后粘贴。',
        );
      }
      final selected = candidates.length == 1
          ? candidates.single
          : await showDialog<ProxyAddressCandidate>(
              context: context,
              builder: (context) => SimpleDialog(
                title: const Text('选择识别到的代理地址'),
                children: [
                  for (final candidate in candidates)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, candidate),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(candidate.address),
                            Text(
                              candidate.source,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ],
              ),
            );
      if (!mounted || generation != _importGeneration || selected == null) {
        return;
      }
      setState(() {
        _address.text = selected.address;
        _software = ProxySoftware.auto;
        _changed();
        _importMessage = '已填入 ${selected.address}，确认后点「保存并应用」。';
      });
      _form.currentState?.validate();
    } on FormatException catch (e) {
      if (mounted && generation == _importGeneration) {
        setState(() => _importMessage = e.message);
      }
    } catch (_) {
      if (mounted && generation == _importGeneration) {
        setState(() => _importMessage = '读取失败，请重新复制截图或代理地址后重试');
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _paste() => _import(() async {
    final content = await ref.read(proxyClipboardReaderProvider)();
    if (content.hasImage) return _recognize(await proxyClipboardImage(content));
    if (content.hasText) return parseProxyAddresses(content.text!);
    throw const FormatException('剪贴板中没有截图或文字地址，请先复制代理设置截图或地址');
  });

  Future<void> _pickScreenshot() => _import(() async {
    final picked = await pickImageFile(context);
    return picked == null ? null : _recognize(picked.bytes);
  });

  Future<void> _test() async {
    if (!_form.currentState!.validate()) return;
    final generation = ++_probeGeneration;
    final draft = _draft;
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    String result;
    try {
      result = await ref.read(networkProxyProbeProvider)(draft);
    } catch (_) {
      result = '测试未完成，请检查代理地址后重试。';
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      if (generation == _probeGeneration) _testMessage = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Desktop settings retain nested pages. Follow changes from another entry
    // only while this form is untouched; never replace an unsaved draft.
    ref.listen(networkProxyProvider, (previous, next) {
      if (!_saving &&
          previous != null &&
          (previous.address != next.address ||
              previous.bypassLocal != next.bypassLocal ||
              previous.software != next.software) &&
          _address.text == previous.address &&
          _bypassLocal == previous.bypassLocal &&
          _software == previous.software) {
        setState(() {
          _address.text = next.address;
          _bypassLocal = next.bypassLocal;
          _software = next.software;
          _changed();
        });
      }
    });
    final saved = ref.watch(networkProxyProvider);
    final relay = ref.watch(naiProxyProvider);
    final detected = saved.enabled && saved.software == ProxySoftware.auto
        ? ref.watch(detectedProxySoftwareProvider(saved.address)).value ??
              ProxySoftware.auto
        : saved.software;
    final environmentProxy =
        !saved.enabled &&
        HttpClient.findProxyFromEnvironment(
              Uri.parse(relay ? kNaiProxyBase : kNaiOfficialBase),
            ) !=
            'DIRECT';
    final dirty =
        saved.address != _address.text ||
        saved.bypassLocal != _bypassLocal ||
        saved.software != _software;
    final small = context.texts.bodySmall!.copyWith(
      color: context.scheme.onSurfaceVariant,
    );
    return SettingsScaffold(
      appBar: AppBar(title: const Text('网络与代理')),
      body: ImageDropRegion(
        label: '识别代理设置截图',
        acceptInternal: false,
        pasteDefault: true,
        // Keep claiming repeated pastes during OCR, so they cannot fall through
        // to the workspace's generic artwork importer.
        onDrop: (images, _) async {
          unawaited(_import(() => _recognize(images.single.bytes)));
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
          children: [
            const SettingsPageHeader(),
            _NetworkCard(
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('本机代理', style: context.texts.titleMedium),
                        ),
                        IconButton(
                          key: const ValueKey('network-proxy-expand'),
                          tooltip: _expanded ? '收起详细设置' : '展开详细设置',
                          onPressed: () =>
                              setState(() => _expanded = !_expanded),
                          icon: Icon(
                            _expanded ? Icons.expand_less : Icons.expand_more,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('通过 Clash 或其他代理软件连接网络。请先启动代理软件。', style: small),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('使用本机 HTTP 代理'),
                      subtitle: const Text('开关立即生效，使用已保存的地址'),
                      value: saved.enabled,
                      onChanged: _saving || _toggling ? null : _setEnabled,
                    ),
                    if (_toggleError != null) ...[
                      Text(_toggleError!, style: small),
                      TextButton(
                        onPressed: _saving || _toggling
                            ? null
                            : () => _setEnabled(
                                ref.read(networkProxyProvider).enabled,
                              ),
                        child: const Text('重试保存开关'),
                      ),
                    ],
                    TextFormField(
                      key: const ValueKey('network-proxy-address'),
                      controller: _address,
                      enabled: !_saving,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'HTTP / Mixed 代理地址',
                        hintText: kDefaultNetworkProxyAddress,
                        border: OutlineInputBorder(),
                        errorMaxLines: 3,
                      ),
                      validator: (value) {
                        try {
                          NetworkProxySettings.normalizeAddress(value ?? '');
                          return null;
                        } on FormatException catch (e) {
                          return e.message;
                        }
                      },
                      onChanged: (_) => setState(() {
                        _expanded = true;
                        _changed();
                      }),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '7890 仅为示例，请以代理软件的 HTTP / Mixed 端口为准。不要填订阅链接、控制端口或 SOCKS 端口。',
                      style: small,
                    ),
                    if (!_expanded && dirty)
                      TextButton(
                        onPressed: () => setState(() => _expanded = true),
                        child: const Text('有未应用的修改，展开后保存'),
                      ),
                    if (_expanded) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _saving || _importing ? null : _paste,
                            icon: const Icon(Icons.content_paste, size: 18),
                            label: Text(_importing ? '识别中…' : '粘贴识别'),
                          ),
                          TextButton.icon(
                            onPressed: _saving || _importing
                                ? null
                                : _pickScreenshot,
                            icon: const Icon(Icons.image_search, size: 18),
                            label: const Text('选择截图'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '复制截图或文字地址后点「粘贴识别」。也可直接在本页粘贴或拖入截图；图片仅在本机识别。',
                        style: small,
                      ),
                      if (_importMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(_importMessage!),
                        ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<ProxySoftware>(
                        key: ValueKey('proxy-software-${_software.name}'),
                        initialValue: _software,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '软件名称（用于路线显示）',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: ProxySoftware.auto,
                            child: Text('自动识别'),
                          ),
                          DropdownMenuItem(
                            value: ProxySoftware.clash,
                            child: Text('Clash'),
                          ),
                          DropdownMenuItem(
                            value: ProxySoftware.other,
                            child: Text('代理软件'),
                          ),
                        ],
                        onChanged: _saving
                            ? null
                            : (value) => setState(() {
                                _software = value!;
                                _changed();
                              }),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('本机与局域网直连'),
                        subtitle: const Text('跳过 localhost、.local 名称和私有 IP 地址'),
                        value: _bypassLocal,
                        onChanged: _saving
                            ? null
                            : (v) => setState(() {
                                _bypassLocal = v!;
                                _changed();
                              }),
                      ),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.icon(
                            onPressed: _saving || _importing || _toggling
                                ? null
                                : _save,
                            icon: const Icon(Icons.check, size: 18),
                            label: Text(_saving ? '保存中…' : '保存并应用'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _saving || _testing || _importing
                                ? null
                                : _test,
                            icon: const Icon(Icons.network_check, size: 18),
                            label: Text(_testing ? '测试中…' : '测试代理'),
                          ),
                          if (dirty) Text('有未应用的修改', style: small),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text('「保存并应用」仅保存地址、软件名称和局域网直连设置，不改变开关。', style: small),
                      const SizedBox(height: 6),
                      Text(
                        '测试只用所填代理访问 NovelAI，不携带令牌、不生成图片，也不会自动启用或保存设置。',
                        style: small,
                      ),
                      if (_saveMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(_saveMessage!),
                        ),
                      if (_testMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(_testMessage!),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const NaiRelayCard(),
            const SizedBox(height: 12),
            _NetworkCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前已应用的路线', style: context.texts.titleSmall),
                  const SizedBox(height: 8),
                  Text(
                    appliedProxyRoute(
                      saved,
                      relay: relay,
                      detected: detected,
                      environmentProxy: environmentProxy,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    saved.enabled
                        ? '本机代理：${saved.address}'
                        : relay
                        ? '通过 Cloudflare 云端转发访问 NovelAI。'
                        : environmentProxy
                        ? '正在使用运行环境提供的代理。'
                        : '未启用应用内代理或云端转发。',
                    style: small,
                  ),
                  if (saved.enabled)
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          saved.software != ProxySoftware.auto
                              ? '软件名称：手动指定'
                              : detected == ProxySoftware.auto
                              ? '暂不能确定软件名称，显示为「代理软件」'
                              : '已识别为${proxySoftwareLabel(detected)}',
                          style: small,
                        ),
                        if (saved.software == ProxySoftware.auto)
                          TextButton(
                            onPressed: () => ref.invalidate(
                              detectedProxySoftwareProvider(saved.address),
                            ),
                            child: const Text('重新识别'),
                          ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  Text(
                    '本机代理适用于 Plana 的联网请求，包括 NovelAI、Bot 后端、AI 助手和下载。此处按应用设置显示路线；系统 TUN 等外部接管不在识别范围。',
                    style: small,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '上方路线仅指官方 NovelAI 接口。第三方接口和 Bot 后端不受云端转发开关影响；两项都开启时，会先经过本机代理，再经过云端转发。',
                    style: small,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NaiRelayCard extends ConsumerWidget {
  const NaiRelayCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _NetworkCard(
    child: SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(kNaiProxyTitle, style: context.texts.titleSmall),
      subtitle: const Text(kNaiProxyHint),
      value: ref.watch(naiProxyProvider),
      onChanged: (value) => ref.read(naiProxyProvider.notifier).set(value),
    ),
  );
}

class _NetworkCard extends StatelessWidget {
  const _NetworkCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: context.scheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(16),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}
