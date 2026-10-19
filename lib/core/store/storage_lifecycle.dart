import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';

import '../util/runtime_diagnostics.dart';
import 'app_stores.dart';

/// Commit editor drafts before flushing, and let desktop exit only after the
/// storage queues finish. Background transitions still start an immediate save.
AppLifecycleListener createStorageLifecycleListener(
  AppStores stores, {
  VoidCallback? beforeFlush,
}) => AppLifecycleListener(
  onStateChange: (state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      beforeFlush?.call();
      stores.flushNow();
    }
  },
  onExitRequested: () async {
    RuntimeDiagnostics.current?.event('exit-requested');
    beforeFlush?.call();
    await stores.flushForExit();
    RuntimeDiagnostics.current?.event('exit-storage-flushed');
    return AppExitResponse.exit;
  },
);
