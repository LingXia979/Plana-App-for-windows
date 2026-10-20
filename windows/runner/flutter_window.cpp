#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "runtime_diagnostics.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  RecordRuntimeEvent("window-create");
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    RecordRuntimeEvent("engine-create-failed");
    return false;
  }
  RecordRuntimeEvent("engine-ready");
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  clipboard_channel_ = std::make_unique<ClipboardChannel>(
      GetHandle(), flutter_controller_->engine()->messenger());
  // 原生拦 Ctrl+V 之后,图经 plana/image_drop 的 `paste` 推给 Dart ——
  // 落点仍由 Dart 侧按光标/焦点裁(见 lib/core/ui/image_drop.dart)。
  paste_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "plana/image_drop",
          &flutter::StandardMethodCodec::GetInstance());
  image_clipboard_ = std::make_unique<ImageClipboard>(
      flutter_controller_->view()->GetNativeWindow(),
      [this](ClipboardImage image) {
        flutter::EncodableMap args;
        args[flutter::EncodableValue("x")] =
            flutter::EncodableValue(static_cast<double>(image.position.x));
        args[flutter::EncodableValue("y")] =
            flutter::EncodableValue(static_cast<double>(image.position.y));
        args[flutter::EncodableValue("bytes")] =
            flutter::EncodableValue(std::move(image.bytes));
        args[flutter::EncodableValue("bitmap")] =
            flutter::EncodableValue(image.bitmap);
        args[flutter::EncodableValue("error")] =
            flutter::EncodableValue(image.error);
        args[flutter::EncodableValue("text")] =
            flutter::EncodableValue(image.text);
        args[flutter::EncodableValue("fromFile")] =
            flutter::EncodableValue(image.from_file);
        flutter::EncodableList paths;
        for (auto& path : image.paths) paths.emplace_back(std::move(path));
        args[flutter::EncodableValue("paths")] =
            flutter::EncodableValue(std::move(paths));
        paste_channel_->InvokeMethod(
            "paste",
            std::make_unique<flutter::EncodableValue>(std::move(args)));
      });
  image_drop_window_ = flutter_controller_->view()->GetNativeWindow();
  image_drop_target_ = new ImageDropTarget(
      image_drop_window_, flutter_controller_->engine()->messenger());
  if (FAILED(RegisterDragDrop(image_drop_window_, image_drop_target_))) {
    image_drop_target_->Release();
    image_drop_target_ = nullptr;
    image_drop_window_ = nullptr;
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    RecordRuntimeEvent("first-frame");
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RecordRuntimeEvent("window-destroy");
  image_clipboard_.reset();
  paste_channel_.reset();
  clipboard_channel_.reset();
  if (image_drop_target_) {
    RevokeDragDrop(image_drop_window_);
    image_drop_target_->Release();
    image_drop_target_ = nullptr;
    image_drop_window_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_CLOSE) RecordRuntimeEvent("window-close-request");
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      // Windows may send this during CreateWindow or after engine teardown.
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
