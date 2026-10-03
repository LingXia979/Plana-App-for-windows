import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Desktop shell only. Selection and import behavior remain in ImportImagePanel.
class DesktopImportLayout extends StatelessWidget {
  const DesktopImportLayout({
    super.key,
    required this.bytes,
    required this.fileName,
    required this.title,
    required this.source,
    required this.summary,
    required this.details,
    required this.referenceActions,
    required this.onClose,
    this.onMetadata,
    this.confirm,
  });

  final Uint8List bytes;
  final String fileName, title, source, summary;
  final Widget details, referenceActions;
  final Widget? confirm;
  final VoidCallback onClose;
  final VoidCallback? onMetadata;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: scheme.surfaceContainerLow,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 1240,
                    maxHeight: 820,
                  ),
                  child: Material(
                    key: const ValueKey('desktop-import-window'),
                    color: scheme.surface,
                    elevation: 2,
                    borderRadius: BorderRadius.circular(18),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(22, 12, 12, 12),
                          child: Row(
                            children: [
                              Icon(
                                Icons.input,
                                color: scheme.primary,
                                size: 22,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  title,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ),
                              IconButton(
                                key: const ValueKey('desktop-import-close'),
                                tooltip: '关闭导入',
                                onPressed: onClose,
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, bounds) {
                              if (bounds.maxWidth < 840 ||
                                  bounds.maxHeight < 360) {
                                return Column(
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Row(
                                        children: [
                                          SizedBox(
                                            width: 76,
                                            height: 94,
                                            child: _image(),
                                          ),
                                          const SizedBox(width: 14),
                                          Expanded(child: _info(context)),
                                        ],
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: referenceActions,
                                    ),
                                    Expanded(child: details),
                                  ],
                                );
                              }
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(
                                    width: (bounds.maxWidth * .30).clamp(
                                      260,
                                      350,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(18),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Expanded(child: _image()),
                                          const SizedBox(height: 14),
                                          _info(context),
                                          const SizedBox(height: 12),
                                          referenceActions,
                                        ],
                                      ),
                                    ),
                                  ),
                                  const VerticalDivider(width: 1),
                                  Expanded(child: details),
                                ],
                              );
                            },
                          ),
                        ),
                        const Divider(height: 1),
                        Padding(
                          key: const ValueKey('desktop-import-footer'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: onClose,
                                child: const Text('取消'),
                              ),
                              if (confirm != null) ...[
                                const SizedBox(width: 12),
                                confirm!,
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _image() => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: ColoredBox(
      color: const Color(0x0D708090),
      child: SizedBox.expand(
        child: Image.memory(
          bytes,
          key: const ValueKey('desktop-import-preview'),
          fit: BoxFit.contain,
          cacheWidth: 768,
          errorBuilder: (_, _, _) =>
              const Center(child: Icon(Icons.broken_image_outlined)),
        ),
      ),
    ),
  );

  Widget _info(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        source,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 4),
      Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
      Text(summary, style: Theme.of(context).textTheme.bodySmall),
      if (onMetadata != null)
        TextButton.icon(
          key: const ValueKey('desktop-import-metadata'),
          onPressed: onMetadata,
          icon: const Icon(Icons.data_object, size: 16),
          label: const Text('完整元数据'),
        ),
    ],
  );
}
