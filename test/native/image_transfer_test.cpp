#include "image_transfer.h"

#include <shellapi.h>
#include <shlobj.h>
#include <cstring>
#include <iostream>
#include <stdexcept>

void Require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

FORMATETC Format(CLIPFORMAT id) {
  return {id, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
}

void DataTests() {
  const std::wstring path = L"C:\\Temp\\图片 导出\\plana_123.jpg";
  auto formats = ImageTransferFormats(path, {1, 2, 3, 4}, {5, 6}, "opaque-id");
  auto* data = CreateImageTransferDataObject(formats);
  Require(data != nullptr, "data object");
  void* unknown = nullptr;
  Require(data->QueryInterface(IID_IDataObject, &unknown) == S_OK, "query IDataObject");
  static_cast<IDataObject*>(unknown)->Release();
  Require(data->QueryInterface(IID_IDropTarget, &unknown) == E_NOINTERFACE && !unknown,
          "unsupported interface");

  auto drop = Format(CF_HDROP);
  STGMEDIUM a = {}, b = {};
  Require(data->GetData(&drop, &a) == S_OK && data->GetData(&drop, &b) == S_OK,
          "multiple independent consumers");
  Require(a.hGlobal != b.hGlobal, "separate ownership for each consumer");
  const auto handle = static_cast<HDROP>(a.hGlobal);
  Require(DragQueryFileW(handle, 0xFFFFFFFF, nullptr, 0) == 1, "one exported file");
  wchar_t buffer[512] = {};
  DragQueryFileW(handle, 0, buffer, 512);
  Require(path == buffer, "Unicode filename retained for file-upload/Explorer consumers");
  const auto* payload = static_cast<const uint8_t*>(GlobalLock(a.hGlobal));
  const auto* header = reinterpret_cast<const DROPFILES*>(payload);
  const auto* files = reinterpret_cast<const wchar_t*>(payload + header->pFiles);
  Require(header->fWide && files[path.size()] == 0 && files[path.size() + 1] == 0,
          "double-NUL Unicode DROPFILES");
  GlobalUnlock(a.hGlobal);
  Require(ReadImageTransferToken(data) == "opaque-id", "return-to-app identity");
  auto copy = Format(static_cast<CLIPFORMAT>(RegisterClipboardFormatW(CFSTR_PREFERREDDROPEFFECT)));
  STGMEDIUM preferred = {};
  Require(data->GetData(&copy, &preferred) == S_OK, "preferred effect present");
  const auto* effect = static_cast<const DWORD*>(GlobalLock(preferred.hGlobal));
  Require(*effect == DROPEFFECT_COPY, "never move or remove gallery source");
  GlobalUnlock(preferred.hGlobal);
  ReleaseStgMedium(&preferred);

  IEnumFORMATETC* enumerator = nullptr;
  Require(data->EnumFormatEtc(DATADIR_GET, &enumerator) == S_OK, "format enumeration");
  FORMATETC format = {};
  ULONG fetched = 0;
  size_t count = 0;
  while (enumerator->Next(1, &format, &fetched) == S_OK) {
    Require(data->QueryGetData(&format) == S_OK, "advertised format is readable");
    STGMEDIUM content = {};
    Require(data->GetData(&format, &content) == S_OK, "rich image fallback readable");
    Require(content.tymed == TYMED_HGLOBAL, "HGLOBAL transfer");
    ReleaseStgMedium(&content);
    ++count;
  }
  Require(count == formats.size(), "all PNG/DIB/file formats advertised");
  enumerator->Release();

  drop.dwAspect = DVASPECT_THUMBNAIL;
  Require(data->QueryGetData(&drop) == DV_E_DVASPECT, "invalid aspect");
  drop = Format(CF_HDROP);
  drop.tymed = TYMED_ISTREAM;
  Require(data->GetData(&drop, &preferred) == DV_E_TYMED, "invalid medium");
  drop = Format(CF_HDROP);
  drop.lindex = 0;
  Require(data->QueryGetData(&drop) == DV_E_LINDEX, "invalid file index");
  Require(data->QueryGetData(nullptr) == E_POINTER, "null request");
  data->Release();
  // Windows consumers may hold a medium longer than the source data object.
  Require(DragQueryFileW(static_cast<HDROP>(b.hGlobal), 0xFFFFFFFF, nullptr, 0) == 1,
          "medium survives drag source");
  ReleaseStgMedium(&a);
  ReleaseStgMedium(&b);

  auto* external = CreateImageTransferDataObject(ImageTransferFormats(path));
  Require(ReadImageTransferToken(external).empty(), "foreign files have no internal identity");
  external->Release();
  Require(CreateImageTransferDataObject({}) == nullptr, "empty export rejected");
  // This preflight failure must never empty the real system clipboard.
  const auto sequence = GetClipboardSequenceNumber();
  Require(!WriteImageTransferClipboard(nullptr, {{0, {1}}}), "invalid clipboard format rejected");
  Require(GetClipboardSequenceNumber() == sequence, "failed preparation leaves clipboard untouched");
}

void SourceTests() {
  auto window = CreateWindowExW(0, L"STATIC", L"Hidden transfer test", 0,
      0, 0, 1, 1, HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), nullptr);
  Require(window != nullptr, "hidden window");
  auto* source = CreateImageDropSource(window);
  Require(source->QueryContinueDrag(FALSE, MK_LBUTTON) == S_OK, "hold continues");
  Require(source->QueryContinueDrag(FALSE, MK_LBUTTON | MK_SHIFT) == S_OK, "shift never requests move");
  Require(source->QueryContinueDrag(FALSE, 0) == DRAGDROP_S_DROP, "release drops");
  Require(source->QueryContinueDrag(TRUE, MK_LBUTTON) == DRAGDROP_S_CANCEL, "escape cancels");
  Require(source->QueryContinueDrag(FALSE, MK_LBUTTON | MK_RBUTTON) == DRAGDROP_S_CANCEL,
          "other mouse button cancels");
  Require(source->GiveFeedback(DROPEFFECT_COPY) == DRAGDROP_S_USEDEFAULTCURSORS, "native copy cursor");
  DestroyWindow(window);
  Require(source->QueryContinueDrag(FALSE, MK_LBUTTON) == DRAGDROP_S_CANCEL, "closing source cancels");
  source->Release();
}

int main() {
  const auto init = OleInitialize(nullptr);
  if (FAILED(init)) return 1;
  try {
    DataTests();
    SourceTests();
    std::cout << "Image transfer contracts passed (system clipboard unchanged).\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << "\n";
    OleUninitialize();
    return 1;
  }
  OleUninitialize();
  return 0;
}

