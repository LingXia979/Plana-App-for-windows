import 'package:flutter/foundation.dart';

import 'runtime_diagnostics.dart';

/// 诊断日志。**只在 debug/profile 输出,release 静默。**
///
/// 为什么不直接用 `debugPrint`:它名字里有 debug,实际却不是 debug-only ——
/// 默认走 `debugPrintThrottled`,**release 构建照样往 logcat 写**。本 app 的
/// 日志内容虽已逐条核过、不含凭据(见 audit-findings S1A-07),但文件路径、
/// 库名、用户自己命名的 Vibe 名没必要发给每一台设备的 logcat。
///
/// 用法与 debugPrint 一致,直接替换即可。
void logd(String message) {
  if (kReleaseMode) return;
  // 这里必须是 debugPrint 本身 —— 换成 logd 就是无限递归。
  debugPrint(message);
}

/// 生命周期级日志:**release 也输出**。只准用于低频关键节点(生成的提交/
/// 完成/失败/取消、状态机转移),给装机排障留现场;禁止进热路径或带
/// 提示词/路径/凭据等内容 —— 那些走 [logd]。
void logi(String message) {
  RuntimeDiagnostics.current?.event('lifecycle', message);
  debugPrint(message);
}
