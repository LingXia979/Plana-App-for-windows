#include "clipboard_channel.h"
#include "image_clipboard.h"
#include "image_transfer.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <cstring>
#include <vector>

namespace {

std::string StringOf(const flutter::EncodableMap& args, const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return {};
  const auto* value = std::get_if<std::string>(&it->second);
  return value ? *value : std::string();
}

std::wstring FilePathOf(const flutter::EncodableMap& args) {
  const auto path = StringOf(args, "filePath");
  if (path.empty() || path.size() > 32768 || path.find('\0') != std::string::npos) return {};
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(),
      static_cast<int>(path.size()), nullptr, 0);
  if (!count) return {};
  std::wstring wide(count, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(),
      static_cast<int>(path.size()), wide.data(), count);
  const auto attributes = GetFileAttributesW(wide.c_str());
  return attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)
      ? std::wstring() : wide;
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
  if (!arguments) return false;
  const auto* args = std::get_if<flutter::EncodableMap>(arguments);
  if (!args) return false;
  const std::vector<uint8_t> image = BytesOf(*args, "image");
  const std::vector<uint8_t> dib = BytesOf(*args, "dib");
  if (image.empty() && dib.empty()) return false;

  const auto file_path = FilePathOf(*args);
  if (!StringOf(*args, "filePath").empty() && file_path.empty()) return false;
  return WriteImageTransferClipboard(owner, ImageTransferFormats(file_path, image, dib));
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
  *alive_ = false;
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
  if (call.method_name() == "startDrag") {
    const auto* args = call.arguments()
        ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    const auto path = args ? FilePathOf(*args) : std::wstring();
    if (path.empty()) {
      result->Error("invalid_image", "无法读取要拖出的图片");
      return;
    }
    // OLE runs a nested message loop: the window may close or another method
    // call may arrive before it returns. Do not dereference this afterwards.
    static bool dragging = false;
    if (dragging) {
      result->Error("drag_busy", "已有图片正在拖动");
      return;
    }
    const auto alive = alive_;
    dragging = true;
    DWORD effect = DROPEFFECT_NONE;
    const auto status = DragImageFile(owner_, path, StringOf(*args, "internalToken"), &effect);
    dragging = false;
    if (!*alive) return;
    if (FAILED(status)) {
      result->Error("drag_failed", "Windows 无法开始图片拖动");
    } else {
      result->Success(flutter::EncodableValue(
          status == DRAGDROP_S_DROP && effect == DROPEFFECT_COPY ? "copied" : "cancelled"));
    }
    return;
  }
  result->NotImplemented();
}
