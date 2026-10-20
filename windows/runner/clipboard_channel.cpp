#include "clipboard_channel.h"
#include "image_clipboard.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <cstring>
#include <vector>

namespace {

// PNG 那个自定义剪贴板格式(浏览器、截图工具、Office 都会放这一份)。
UINT PngClipboardFormat() {
  static const UINT format = RegisterClipboardFormat(L"PNG");
  return format;
}

// 别的程序正在写剪贴板时,OpenClipboard 会直接失败。等一小会儿再试几次:
// 按一次 Ctrl+V 不该因为后台刚有个程序复制完东西就什么都不发生。
bool OpenClipboardWithRetry(HWND owner) {
  for (int attempt = 0; attempt < 10; ++attempt) {
    if (OpenClipboard(owner)) return true;
    Sleep(5);
  }
  return false;
}

// 交给剪贴板一份内存。SetClipboardData 成功之后这块内存归系统管,不能再动;
// 失败则还在自己手里,得自己释放。
HGLOBAL CopyToGlobal(const std::vector<uint8_t>& bytes) {
  HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (!handle) return nullptr;
  void* data = GlobalLock(handle);
  if (!data) {
    GlobalFree(handle);
    return nullptr;
  }
  memcpy(data, bytes.data(), bytes.size());
  GlobalUnlock(handle);
  return handle;
}

// Both the explicit image button and the keyboard hook use the same reader.
flutter::EncodableMap ReadClipboard(HWND owner) {
  ClipboardImage image = ReadClipboardImage(owner);
  flutter::EncodableMap payload;
  if (!image.text.empty()) {
    payload[flutter::EncodableValue("text")] = flutter::EncodableValue(image.text);
  }
  if (!image.bytes.empty()) {
    payload[flutter::EncodableValue("image")] = flutter::EncodableValue(image.bytes);
    payload[flutter::EncodableValue("format")] =
        flutter::EncodableValue(image.bitmap ? "bmp" : "png");
  }
  if (!image.paths.empty()) {
    flutter::EncodableList paths;
    for (const auto& path : image.paths) paths.emplace_back(path);
    payload[flutter::EncodableValue("paths")] = flutter::EncodableValue(paths);
  }
  if (image.from_file) {
    payload[flutter::EncodableValue("fromFile")] = flutter::EncodableValue(true);
  }
  if (!image.error.empty()) {
    payload[flutter::EncodableValue("error")] = flutter::EncodableValue(image.error);
  }
  return payload;
}

std::vector<uint8_t> BytesOf(const flutter::EncodableMap& args,
                             const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return {};
  const auto* bytes = std::get_if<std::vector<uint8_t>>(&it->second);
  return bytes ? *bytes : std::vector<uint8_t>();
}

bool WriteClipboard(HWND owner, const flutter::EncodableValue* arguments) {
  const auto* args = std::get_if<flutter::EncodableMap>(arguments);
  if (!args) return false;
  const std::vector<uint8_t> image = BytesOf(*args, "image");
  const std::vector<uint8_t> dib = BytesOf(*args, "dib");
  if (image.empty() && dib.empty()) return false;

  if (!OpenClipboardWithRetry(owner)) return false;
  EmptyClipboard();
  bool written = false;
  if (!dib.empty()) {
    // CF_DIB 是给老程序(画图、Word)的:它们不认 PNG 那个自定义格式。
    if (HGLOBAL handle = CopyToGlobal(dib)) {
      if (SetClipboardData(CF_DIB, handle)) {
        written = true;
      } else {
        GlobalFree(handle);
      }
    }
  }
  const UINT png_format = PngClipboardFormat();
  if (!image.empty() && png_format != 0) {
    if (HGLOBAL handle = CopyToGlobal(image)) {
      if (SetClipboardData(png_format, handle)) {
        written = true;
      } else {
        GlobalFree(handle);
      }
    }
  }
  CloseClipboard();
  return written;
}

}  // namespace

ClipboardChannel::ClipboardChannel(HWND owner, flutter::BinaryMessenger* messenger)
    : owner_(owner),
      channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "plana/clipboard",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

ClipboardChannel::~ClipboardChannel() {
  channel_->SetMethodCallHandler(nullptr);
}

void ClipboardChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "read") {
    result->Success(flutter::EncodableValue(ReadClipboard(owner_)));
    return;
  }
  if (call.method_name() == "write") {
    result->Success(
        flutter::EncodableValue(WriteClipboard(owner_, call.arguments())));
    return;
  }
  result->NotImplemented();
}
