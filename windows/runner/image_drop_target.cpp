#include "image_drop_target.h"

#include <shellapi.h>
#include <flutter/standard_method_codec.h>
#include <vector>
#include <string>

namespace {
FORMATETC FileFormat() {
  return {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
}

std::string Utf8(const std::wstring& text) {
  const int count = WideCharToMultiByte(CP_UTF8, 0, text.data(),
      static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string out(count, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
      out.data(), count, nullptr, nullptr);
  return out;
}
}  // namespace

ImageDropTarget::ImageDropTarget(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window), channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, "plana/image_drop", &flutter::StandardMethodCodec::GetInstance())) {}

HRESULT ImageDropTarget::QueryInterface(REFIID iid, void** object) {
  if (!object) return E_POINTER;
  *object = nullptr;
  if (iid == IID_IUnknown || iid == IID_IDropTarget) {
    *object = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }
  return E_NOINTERFACE;
}
ULONG ImageDropTarget::AddRef() { return ++references_; }
ULONG ImageDropTarget::Release() {
  const ULONG remaining = --references_;
  if (!remaining) delete this;
  return remaining;
}

void ImageDropTarget::SendPosition(const char* method, POINTL point,
                                   flutter::EncodableList paths) {
  POINT local = {point.x, point.y};
  ScreenToClient(window_, &local);
  flutter::EncodableMap args;
  args[flutter::EncodableValue("x")] = flutter::EncodableValue(static_cast<double>(local.x));
  args[flutter::EncodableValue("y")] = flutter::EncodableValue(static_cast<double>(local.y));
  args[flutter::EncodableValue("paths")] = flutter::EncodableValue(paths);
  channel_->InvokeMethod(method, std::make_unique<flutter::EncodableValue>(args));
}

HRESULT ImageDropTarget::DragEnter(IDataObject* data, DWORD, POINTL point, DWORD* effect) {
  if (!effect) return E_POINTER;
  auto format = FileFormat();
  accepts_ = data && data->QueryGetData(&format) == S_OK && (*effect & DROPEFFECT_COPY);
  *effect = accepts_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
  if (accepts_) SendPosition("over", point);
  return S_OK;
}
HRESULT ImageDropTarget::DragOver(DWORD, POINTL point, DWORD* effect) {
  if (!effect) return E_POINTER;
  *effect = accepts_ && (*effect & DROPEFFECT_COPY) ? DROPEFFECT_COPY : DROPEFFECT_NONE;
  if (*effect == DROPEFFECT_COPY) SendPosition("over", point);
  return S_OK;
}
HRESULT ImageDropTarget::DragLeave() {
  accepts_ = false;
  channel_->InvokeMethod("leave", nullptr);
  return S_OK;
}
HRESULT ImageDropTarget::Drop(IDataObject* data, DWORD, POINTL point, DWORD* effect) {
  if (!effect) return E_POINTER;
  const bool copy = accepts_ && (*effect & DROPEFFECT_COPY);
  *effect = DROPEFFECT_NONE;
  accepts_ = false;
  auto format = FileFormat();
  STGMEDIUM medium = {};
  if (!copy || !data || FAILED(data->GetData(&format, &medium))) {
    return DragLeave();
  }
  flutter::EncodableList paths;
  const auto drop = static_cast<HDROP>(medium.hGlobal);
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  // Dart reports an oversized batch; do not load arbitrary-sized path lists.
  for (UINT i = 0; i < count && i < 65; ++i) {
    const UINT length = DragQueryFileW(drop, i, nullptr, 0);
    std::vector<wchar_t> buffer(length + 1);
    DragQueryFileW(drop, i, buffer.data(), length + 1);
    paths.emplace_back(Utf8(std::wstring(buffer.data(), length)));
  }
  ReleaseStgMedium(&medium);
  if (!paths.empty()) {
    SendPosition("drop", point, std::move(paths));
    *effect = DROPEFFECT_COPY;
  } else {
    DragLeave();
  }
  return S_OK;
}
