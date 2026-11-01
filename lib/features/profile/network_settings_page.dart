import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/nai_proxy.dart';
import '../../core/net/network_proxy.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/settings_scaffold.dart';
import '../generate/widgets/common.dart' show sharedAxisRoute;

class NetworkSettingsPage extends ConsumerStatefulWidget {
  const NetworkSettingsPage({super.key});

  @override
  ConsumerState<NetworkSettingsPage> createState() =>
      _NetworkSettingsPageState();
}

class _NetworkSettingsPageState extends ConsumerState<NetworkSettingsPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _address;
  late bool _enabled;
  late bool _bypassLocal;
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
    _enabled = saved.enabled;
    _bypassLocal = saved.bypassLocal;
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  NetworkProxySettings get _draft => NetworkProxySettings(
    enabled: _enabled,
    address: _address.text,
    bypassLocal: _bypassLocal,
  );

  void _changed() {
    _probeGeneration++;
    _testMessage = null;
    _saveMessage = null;
  }

  Future<void> _save() async {
    // Always allow disabling even if the address field currently contains a typo.
    final valid = _form.currentState!.validate();
    if (_enabled && !valid) return;
    final next = valid
        ? _draft
        : NetworkProxySettings(
            enabled: false,
            address: ref.read(networkProxyProvider).address,
            bypassLocal: _bypassLocal,
          );
    setState(() {
      _saving = true;
      _saveMessage = null;
    });
    try {
      await ref.read(networkProxyProvider.notifier).save(next);
      if (!mounted) return;
      setState(() {
        _address.text = ref.read(networkProxyProvider).address;
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
          _enabled == previous.enabled &&
          _address.text == previous.address &&
          _bypassLocal == previous.bypassLocal) {
        setState(() {
          _enabled = next.enabled;
          _address.text = next.address;
          _bypassLocal = next.bypassLocal;
          _changed();
        });
      }
    });
    final saved = ref.watch(networkProxyProvider);
    final relay = ref.watch(naiProxyProvider);
    final dirty =
        saved.enabled != _enabled ||
        saved.address != _address.text ||
        saved.bypassLocal != _bypassLocal;
    final small = context.texts.bodySmall!.copyWith(
      color: context.scheme.onSurfaceVariant,
    );
    return SettingsScaffold(
      appBar: AppBar(title: const Text('网络与代理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          const SettingsPageHeader(),
          _NetworkCard(
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Clash 本机代理', style: context.texts.titleMedium),
                  const SizedBox(height: 6),
                  Text('让 Plana 通过你电脑上的 Clash 连接网络。请先启动 Clash。', style: small),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('使用本机 HTTP 代理'),
                    value: _enabled,
                    onChanged: _saving
                        ? null
                        : (v) => setState(() {
                            _enabled = v;
                            _changed();
                          }),
                  ),
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
                    onChanged: (_) => setState(_changed),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '7890 仅为常见示例，请以 Clash 显示的 HTTP / Mixed 端口为准。不要填订阅链接、控制端口或 SOCKS 端口。',
                    style: small,
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
                        onPressed: _saving ? null : _save,
                        icon: const Icon(Icons.check, size: 18),
                        label: Text(_saving ? '保存中…' : '保存并应用'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _saving || _testing ? null : _test,
                        icon: const Icon(Icons.network_check, size: 18),
                        label: Text(_testing ? '测试中…' : '测试代理'),
                      ),
                      if (dirty) Text('有未应用的修改', style: small),
                    ],
                  ),
                  const SizedBox(height: 10),
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
                  [
                    'Plana',
                    if (saved.enabled) 'Clash / 本机代理',
                    if (relay) 'Cloudflare 云端转发',
                    'NovelAI',
                  ].join(' → '),
                ),
                const SizedBox(height: 8),
                Text(
                  saved.enabled ? '本机代理：${saved.address}' : '本机代理已关闭，沿用原有网络环境。',
                  style: small,
                ),
                const SizedBox(height: 8),
                Text(
                  '本机代理适用于 Plana 的联网请求，包括 NovelAI、Bot 后端、AI 助手和下载；不会修改接口地址、账号或 Windows 系统代理。已有的系统 TUN 仍由外部软件控制。',
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

class NetworkProxyEntry extends ConsumerWidget {
  const NetworkProxyEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(networkProxyProvider);
    return Material(
      color: context.scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.settings_ethernet),
        title: const Text('Clash 本机代理'),
        subtitle: Text(
          settings.enabled
              ? '已开启 · ${settings.address}'
              : '未开启 · 配置本机 HTTP / Mixed 端口',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(
          context,
        ).push(sharedAxisRoute(const NetworkSettingsPage())),
      ),
    );
  }
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
