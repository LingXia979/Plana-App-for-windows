#include "image_transfer.h"

#include <shellapi.h>
#include <shlobj.h>

#include <atomic>
#include <cstring>
#include <utility>

namespace {
CLIPFORMAT Registered(const wchar_t* name) {
  return static_cast<CLIPFORMAT>(RegisterClipboardFormatW(name));
}

HGLOBAL CopyToGlobal(const std::vector<uint8_t>& bytes) {
  if (bytes.empty()) return nullptr;
  const auto handle = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (!handle) return nullptr;
  auto* memory = GlobalLock(handle);
  if (!memory) {
    GlobalFree(handle);
    return nullptr;
  }
  memcpy(memory, bytes.data(), bytes.size());
  GlobalUnlock(handle);
  return handle;
}

FORMATETC Format(CLIPFORMAT id) {
  return {id, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
}

class ImageDataObject final : public IDataObject {
 public:
  explicit ImageDataObject(std::vector<ImageTransferFormat> formats)
      : formats_(std::move(formats)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (!object) return E_POINTER;
    *object = nullptr;
    if (iid != IID_IUnknown && iid != IID_IDataObject) return E_NOINTERFACE;
    *object = static_cast<IDataObject*>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const auto remaining = --references_;
    if (!remaining) delete this;
    return remaining;
  }
  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* format) override {
    if (!format) return E_POINTER;
    if (format->dwAspect != DVASPECT_CONTENT) return DV_E_DVASPECT;
    if (format->lindex != -1) return DV_E_LINDEX;
    if (!(format->tymed & TYMED_HGLOBAL)) return DV_E_TYMED;
    for (const auto& entry : formats_) {
      if (entry.format == format->cfFormat) return S_OK;
    }
    return DV_E_FORMATETC;
  }
  HRESULT STDMETHODCALLTYPE GetData(FORMATETC* format, STGMEDIUM* medium) override {
    if (!medium) return E_POINTER;
    *medium = {};
    const auto status = QueryGetData(format);
    if (FAILED(status)) return status;
    for (const auto& entry : formats_) {
      if (entry.format != format->cfFormat) continue;
      auto memory = CopyToGlobal(entry.bytes);
      if (!memory) return E_OUTOFMEMORY;
      // Each caller owns a fresh copy, valid even after this object is released.
      medium->tymed = TYMED_HGLOBAL;
      medium->hGlobal = memory;
      return S_OK;
    }
    return DV_E_FORMATETC;
  }
  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override {
    return DATA_E_FORMATETC;
  }
  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC*, FORMATETC* out) override {
    if (!out) return E_POINTER;
    out->ptd = nullptr;
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE SetData(FORMATETC*, STGMEDIUM*, BOOL) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction, IEnumFORMATETC** out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (direction != DATADIR_GET) return E_NOTIMPL;
    std::vector<FORMATETC> formats;
    for (const auto& entry : formats_) formats.push_back(Format(entry.format));
    return SHCreateStdEnumFmtEtc(static_cast<UINT>(formats.size()), formats.data(), out);
  }
  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override {
    return OLE_E_ADVISENOTSUPPORTED;
  }
  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA**) override {
    return OLE_E_ADVISENOTSUPPORTED;
  }

 private:
  std::atomic<ULONG> references_{1};
  const std::vector<ImageTransferFormat> formats_;
};

class ImageDropSource final : public IDropSource {
 public:
  explicit ImageDropSource(HWND owner) : owner_(owner) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (!object) return E_POINTER;
    *object = nullptr;
    if (iid != IID_IUnknown && iid != IID_IDropSource) return E_NOINTERFACE;
    *object = static_cast<IDropSource*>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const auto remaining = --references_;
    if (!remaining) delete this;
    return remaining;
  }
  HRESULT STDMETHODCALLTYPE QueryContinueDrag(BOOL escape, DWORD keys) override {
    if (escape || !IsWindow(owner_) || (keys & (MK_RBUTTON | MK_MBUTTON))) {
      return DRAGDROP_S_CANCEL;
    }
    return (keys & MK_LBUTTON) ? S_OK : DRAGDROP_S_DROP;
  }
  HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD) override {
    return DRAGDROP_S_USEDEFAULTCURSORS;
  }
 private:
  std::atomic<ULONG> references_{1};
  HWND owner_;
};
}  // namespace

std::vector<ImageTransferFormat> ImageTransferFormats(
    const std::wstring& file_path, const std::vector<uint8_t>& png,
    const std::vector<uint8_t>& dib, const std::string& internal_token) {
  std::vector<ImageTransferFormat> formats;
  if (!file_path.empty() && file_path.find(L'\0') == std::wstring::npos) {
    DROPFILES header = {};
    header.pFiles = sizeof(DROPFILES);
    header.fWide = TRUE;
    // CF_HDROP is a DROPFILES header followed by a double-NUL Unicode list.
    std::vector<uint8_t> files(sizeof(header) + (file_path.size() + 2) * sizeof(wchar_t), 0);
    memcpy(files.data(), &header, sizeof(header));
    memcpy(files.data() + sizeof(header), file_path.data(), file_path.size() * sizeof(wchar_t));
    formats.push_back({CF_HDROP, std::move(files)});
    const DWORD copy = DROPEFFECT_COPY;
    std::vector<uint8_t> effect(sizeof(copy));
    memcpy(effect.data(), &copy, sizeof(copy));
    formats.push_back({Registered(CFSTR_PREFERREDDROPEFFECT), std::move(effect)});
  }
  if (!png.empty()) {
    formats.push_back({Registered(L"PNG"), png});
    formats.push_back({Registered(L"image/png"), png});
  }
  if (!dib.empty()) formats.push_back({CF_DIB, dib});
  if (!internal_token.empty() && internal_token.size() <= 128 &&
      internal_token.find('\0') == std::string::npos) {
    std::vector<uint8_t> token(internal_token.begin(), internal_token.end());
    token.push_back(0);
    formats.push_back({Registered(L"Plana.ImageTransfer"), std::move(token)});
  }
  return formats;
}

IDataObject* CreateImageTransferDataObject(std::vector<ImageTransferFormat> formats) {
  return formats.empty() ? nullptr : new ImageDataObject(std::move(formats));
}
IDropSource* CreateImageDropSource(HWND owner) { return new ImageDropSource(owner); }

std::string ReadImageTransferToken(IDataObject* data) {
  if (!data) return {};
  auto format = Format(Registered(L"Plana.ImageTransfer"));
  STGMEDIUM medium = {};
  if (FAILED(data->GetData(&format, &medium))) return {};
  std::string token;
  if (medium.tymed == TYMED_HGLOBAL && medium.hGlobal) {
    const auto size = GlobalSize(medium.hGlobal);
    if (size > 1 && size <= 129) {
      const auto* text = static_cast<const char*>(GlobalLock(medium.hGlobal));
      if (text) {
        const auto length = strnlen_s(text, size);
        if (length < size) token.assign(text, length);
        GlobalUnlock(medium.hGlobal);
      }
    }
  }
  ReleaseStgMedium(&medium);
  return token;
}

bool WriteImageTransferClipboard(HWND owner,
                                 const std::vector<ImageTransferFormat>& formats) {
  if (formats.empty()) return false;
  // Prepare ALL formats before touching the user's previous clipboard.
  std::vector<HGLOBAL> handles;
  for (const auto& format : formats) {
    auto handle = format.format ? CopyToGlobal(format.bytes) : nullptr;
    if (!handle) {
      for (const auto memory : handles) GlobalFree(memory);
      return false;
    }
    handles.push_back(handle);
  }
  bool opened = false;
  for (int attempt = 0; attempt < 10 && !opened; ++attempt) {
    opened = OpenClipboard(owner) != FALSE;
    if (!opened) Sleep(5);
  }
  bool success = opened && EmptyClipboard();
  if (success) {
    for (size_t i = 0; i < formats.size(); ++i) {
      if (SetClipboardData(formats[i].format, handles[i])) {
        handles[i] = nullptr;  // The system owns this handle now.
      } else {
        success = false;
      }
    }
  }
  if (opened) CloseClipboard();
  for (const auto memory : handles) {
    if (memory) GlobalFree(memory);
  }
  return success;
}

HRESULT DragImageFile(HWND owner, const std::wstring& file_path,
                      const std::string& internal_token, DWORD* effect) {
  if (!effect) return E_POINTER;
  *effect = DROPEFFECT_NONE;
  // Encoding may finish after the mouse was released. Never start a stuck drag.
  if (!IsWindow(owner) || !(GetAsyncKeyState(VK_LBUTTON) & 0x8000)) {
    return DRAGDROP_S_CANCEL;
  }
  const auto attributes = GetFileAttributesW(file_path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
    return HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
  }
  auto* data = CreateImageTransferDataObject(ImageTransferFormats(file_path, {}, {}, internal_token));
  if (!data) return E_INVALIDARG;
  auto* source = CreateImageDropSource(owner);
  // End Flutter's mouse capture before OLE takes ownership of the gesture.
  ReleaseCapture();
  const auto status = DoDragDrop(data, source, DROPEFFECT_COPY, effect);
  source->Release();
  data->Release();
  return status;
}
