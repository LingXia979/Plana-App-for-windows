#ifndef RUNNER_CLIPBOARD_CHANNEL_H_
#define RUNNER_CLIPBOARD_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// 剪贴板图片读写。Flutter 自带的 Clipboard 只有文本,图片这半截得自己走 Win32。
//
// Dart 侧的门面在 lib/core/platform/clipboard_image.dart —— 方法名(`read` /
// `write`)和回包字段(image / format / name / fromFile / text)两边要对得上。
class ClipboardChannel {
 public:
  // |owner| 是窗口句柄:剪贴板要有个属主,别的程序才知道这块剪贴板是谁占的
  // (WM_DESTROYCLIPBOARD 通知也才发得出去)。传空也能用,但不该这么用。
  ClipboardChannel(HWND owner, flutter::BinaryMessenger* messenger);
  ~ClipboardChannel();

  ClipboardChannel(const ClipboardChannel&) = delete;
  ClipboardChannel& operator=(const ClipboardChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HWND owner_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_CLIPBOARD_CHANNEL_H_
