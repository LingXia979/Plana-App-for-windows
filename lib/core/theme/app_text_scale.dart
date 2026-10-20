import 'package:flutter/material.dart';

/// Scales text throughout the navigator, including dialogs and overlays.
/// Keeping the same wrapper at 100% preserves routes and drafts during edits.
class AppTextScale extends StatelessWidget {
  const AppTextScale({super.key, required this.factor, required this.child});

  final double factor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: factor == 1
            ? media.textScaler
            : _AppTextScaler(media.textScaler, factor),
      ),
      child: child,
    );
  }
}

/// Preserve the system's scaling curve while applying the app preference.
class _AppTextScaler extends TextScaler {
  const _AppTextScaler(this.system, this.factor);

  final TextScaler system;
  final double factor;

  @override
  double scale(double fontSize) => system.scale(fontSize) * factor;

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is _AppTextScaler &&
      other.system == system &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(system, factor);
}
