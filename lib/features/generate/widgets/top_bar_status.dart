import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 顶栏右侧的裸状态入口：点数与百分比共用单行点击区域。
///
/// [value] 为空 = 还没拿到读数：数值位换成一枚刷新图标，[loading] 时转圈。
class TopBarStatus extends StatelessWidget {
  const TopBarStatus({
    super.key,
    required this.tooltip,
    required this.value,
    required this.detail,
    required this.icon,
    required this.onTap,
    this.loading = false,
    this.valueColor,
    this.detailColor,
  });

  final String tooltip;
  final String? value;
  final String? detail;
  final IconData icon;
  final VoidCallback onTap;
  final bool loading;
  final Color? valueColor;
  final Color? detailColor;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label:
          '$tooltip，${value ?? (loading ? '加载中' : '未获取')}'
          '${detail == null ? '' : '，$detail'}',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: valueColor ?? context.scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              if (value case final text?)
                Flexible(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(
                      context,
                      size: 15,
                      weight: FontWeight.w700,
                    ).copyWith(color: valueColor ?? context.scheme.onSurface),
                  ),
                )
              else
                _Pending(
                  spinning: loading,
                  color: valueColor ?? context.scheme.onSurfaceVariant,
                ),
              if (detail case final text?) ...[
                Container(
                  width: 1,
                  height: 18,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  color: context.scheme.outlineVariant,
                ),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(context, size: 15, weight: FontWeight.w700)
                        .copyWith(
                          color: detailColor ?? context.scheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// 读数还没到时占数值位的刷新图标（与点数弹层的刷新按钮同一枚）。
/// 拉取中持续转圈；停下时转完手上这一圈再停，不歪在半截。
class _Pending extends StatefulWidget {
  const _Pending({required this.spinning, required this.color});

  final bool spinning;
  final Color color;

  @override
  State<_Pending> createState() => _PendingState();
}

class _PendingState extends State<_Pending>
    with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _turn.repeat();
  }

  @override
  void didUpdateWidget(_Pending old) {
    super.didUpdateWidget(old);
    if (widget.spinning == old.spinning) return;
    if (widget.spinning) {
      _turn.repeat();
    } else {
      _turn.forward();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _turn,
    child: Icon(Icons.refresh, size: 18, color: widget.color),
  );
}
