#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>

#include "win32_window.h"
#include "clipboard_channel.h"
#include "image_drop_target.h"
#include "image_clipboard.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  ImageDropTarget* image_drop_target_ = nullptr;
  HWND image_drop_window_ = nullptr;

  // 「把图写进剪贴板 / 从剪贴板读图」的通道(Flutter 自带的 Clipboard 只有文本)。
  // 复制出去那半截只有它有,见 clipboard_channel.h。
  std::unique_ptr<ClipboardChannel> clipboard_channel_;

  // 原生拦 Ctrl+V:按键在窗口过程里就被吃掉,读到的图经 plana/image_drop 的
  // `paste` 事件推给 Dart。这么做才拦得住 `WM_CHAR` 里那个 0x16 —— 光靠 Flutter
  // 层的快捷键,系统还会再补一次字符消息打进输入框。见 image_clipboard.h。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      paste_channel_;
  std::unique_ptr<ImageClipboard> image_clipboard_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
