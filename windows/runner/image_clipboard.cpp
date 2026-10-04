#include "image_clipboard.h"

#include <shellapi.h>

#include <algorithm>
#include <cstring>
#include <cwctype>
#include <stdexcept>
#include <utility>

namespace {
constexpr size_t kMaxImageBytes = 64 * 1024 * 1024;

template <typename T>
T Read(const std::vector<uint8_t>& bytes, size_t offset) {
  if (offset > bytes.size() || sizeof(T) > bytes.size() - offset) {
    throw std::invalid_argument("The clipboard bitmap is incomplete.");
  }
  T value;
  std::memcpy(&value, bytes.data() + offset, sizeof(T));
  return value;
}

std::vector<uint8_t> CopyGlobal(HANDLE handle) {
  if (!handle) throw std::runtime_error("The clipboard image could not be read.");
  const SIZE_T length = GlobalSize(handle);
  if (!length || length > kMaxImageBytes) {
    throw std::runtime_error("Clipboard images must be at most 64 MB.");
  }
  const auto* memory = static_cast<const uint8_t*>(GlobalLock(handle));
  if (!memory) throw std::runtime_error("The clipboard image is unavailable.");
  try {
    std::vector<uint8_t> copy(memory, memory + length);
    GlobalUnlock(handle);
    return copy;
  } catch (...) {
    GlobalUnlock(handle);
    throw;
  }
}

bool ImagePath(const std::wstring& path) {
  const auto dot = path.find_last_of(L'.');
  if (dot == std::wstring::npos) return false;
  std::wstring extension = path.substr(dot);
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return extension == L".png" || extension == L".jpg" ||
         extension == L".jpeg" || extension == L".webp" ||
         extension == L".bmp" || extension == L".gif";
}

std::string Utf8(const std::wstring& text) {
  const int length = WideCharToMultiByte(CP_UTF8, 0, text.data(),
      static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string output(length, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      output.data(), length, nullptr, nullptr);
  return output;
}
}  // namespace

std::vector<uint8_t> ClipboardBitmapFile(const std::vector<uint8_t>& dib) {
  if (dib.size() > kMaxImageBytes) {
    throw std::invalid_argument("The clipboard bitmap is too large.");
  }
  const uint32_t header = Read<uint32_t>(dib, 0);
  uint32_t width, height, palette = 0, masks = 0;
  uint16_t bits, planes;
  if (header == 12) {
    width = Read<uint16_t>(dib, 4);
    height = Read<uint16_t>(dib, 6);
    planes = Read<uint16_t>(dib, 8);
    bits = Read<uint16_t>(dib, 10);
    if (bits <= 8) palette = (1u << bits) * 3;
  } else {
    if (header != 40 && header != 52 && header != 56 &&
        header != 108 && header != 124) {
      throw std::invalid_argument("Unsupported clipboard bitmap header.");
    }
    if (header > dib.size()) throw std::invalid_argument("Incomplete bitmap header.");
    const int32_t signed_width = Read<int32_t>(dib, 4);
    const int64_t signed_height = Read<int32_t>(dib, 8);
    if (signed_width <= 0) throw std::invalid_argument("Invalid bitmap width.");
    width = static_cast<uint32_t>(signed_width);
    height = static_cast<uint32_t>(signed_height < 0 ? -signed_height : signed_height);
    planes = Read<uint16_t>(dib, 12);
    bits = Read<uint16_t>(dib, 14);
    const uint32_t compression = Read<uint32_t>(dib, 16);
    if (compression != BI_RGB && compression != BI_BITFIELDS && compression != 6) {
      throw std::invalid_argument("Unsupported clipboard bitmap compression.");
    }
    if (compression != BI_RGB && bits != 16 && bits != 32) {
      throw std::invalid_argument("Invalid bitmap bit masks.");
    }
    if (header == 40 && compression != BI_RGB) masks = compression == 6 ? 16 : 12;
    uint32_t colors = Read<uint32_t>(dib, 32);
    if (!colors && bits <= 8) colors = 1u << bits;
    if (colors > 256 || (bits <= 8 && colors > (1u << bits))) {
      throw std::invalid_argument("Invalid bitmap palette.");
    }
    palette = colors * 4;
  }
  if (planes != 1 || !width || !height || width > 32768 || height > 32768 ||
      (bits != 1 && bits != 4 && bits != 8 && bits != 16 && bits != 24 && bits != 32)) {
    throw std::invalid_argument("Invalid clipboard bitmap dimensions.");
  }
  const uint64_t offset = static_cast<uint64_t>(header) + masks + palette;
  const uint64_t stride = ((static_cast<uint64_t>(width) * bits + 31) / 32) * 4;
  if (offset + stride * height > dib.size()) {
    throw std::invalid_argument("The clipboard bitmap pixels are incomplete.");
  }
  BITMAPFILEHEADER file_header = {};
  static_assert(sizeof(file_header) == 14, "Unexpected BMP header alignment");
  file_header.bfType = 0x4D42;
  file_header.bfSize = static_cast<DWORD>(sizeof(file_header) + dib.size());
  file_header.bfOffBits = static_cast<DWORD>(sizeof(file_header) + offset);
  std::vector<uint8_t> output(sizeof(file_header) + dib.size());
  std::memcpy(output.data(), &file_header, sizeof(file_header));
  std::memcpy(output.data() + sizeof(file_header), dib.data(), dib.size());
  return output;
}

ClipboardImage ReadClipboardImage(HWND owner) {
  ClipboardImage image;
  const UINT png = RegisterClipboardFormatW(L"PNG");
  const UINT mime_png = RegisterClipboardFormatW(L"image/png");
  const bool encoded = IsClipboardFormatAvailable(png) || IsClipboardFormatAvailable(mime_png);
  const bool bitmap = IsClipboardFormatAvailable(CF_DIBV5) || IsClipboardFormatAvailable(CF_DIB);
  const bool files = IsClipboardFormatAvailable(CF_HDROP);
  if (!encoded && !bitmap && !files) return image;
  if (!OpenClipboard(owner)) {
    // Do not consume a normal text paste just because an unrelated file list
    // is temporarily locked by its owner.
    image.recognized = encoded || bitmap;
    image.error = "clipboard_busy";
    return image;
  }
  try {
    if (encoded) {
      image.recognized = true;
      image.bytes = CopyGlobal(GetClipboardData(IsClipboardFormatAvailable(png) ? png : mime_png));
    } else if (bitmap) {
      image.recognized = true;
      const UINT format = IsClipboardFormatAvailable(CF_DIBV5) ? CF_DIBV5 : CF_DIB;
      image.bytes = ClipboardBitmapFile(CopyGlobal(GetClipboardData(format)));
      image.bitmap = true;
    } else {
      const auto drop = static_cast<HDROP>(GetClipboardData(CF_HDROP));
      if (drop) {
        const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
          for (UINT i = 0; i < count && i < 65; ++i) {
            const UINT length = DragQueryFileW(drop, i, nullptr, 0);
            if (!length || length > 32767) throw std::runtime_error("Invalid clipboard file path.");
            std::vector<wchar_t> buffer(length + 1);
            DragQueryFileW(drop, i, buffer.data(), length + 1);
            const std::wstring path(buffer.data(), length);
            if (!ImagePath(path)) { image.paths.clear(); break; }
            image.paths.push_back(Utf8(path));
          }
          image.recognized = !image.paths.empty();
          if (image.recognized && count > 64) {
            image.paths.clear();
            image.error = "too_many_images";
          }
      }
    }
  } catch (...) {
    image.bytes.clear();
    image.paths.clear();
    image.error = "invalid_image";
  }
  CloseClipboard();
  return image;
}

ImageClipboard::ImageClipboard(HWND window, Receiver receiver, Reader reader)
    : window_(window), receiver_(std::move(receiver)), reader_(std::move(reader)) {
  attached_ = SetWindowSubclass(window_, WindowProc,
      reinterpret_cast<UINT_PTR>(this), reinterpret_cast<DWORD_PTR>(this)) != FALSE;
}

ImageClipboard::~ImageClipboard() {
  if (attached_) RemoveWindowSubclass(window_, WindowProc, reinterpret_cast<UINT_PTR>(this));
}

bool ImageClipboard::HandleKey(UINT message, WPARAM key, LPARAM flags,
                              bool control, bool shift, bool alt) {
  if (message == WM_KILLFOCUS) {
    suppress_v_ = suppress_insert_ = suppress_char_ = false;
    return false;
  }
  if (message == WM_CHAR && key == 0x16 && suppress_char_) {
    suppress_char_ = false;
    return true;
  }
  if (key != 'V' && key != VK_INSERT) return false;
  bool& suppressed = key == 'V' ? suppress_v_ : suppress_insert_;
  if (message == WM_KEYUP && suppressed) {
    suppressed = false;
    return true;
  }
  if (message != WM_KEYDOWN) return false;
  if (suppressed) return true;
  const bool paste = !alt && ((key == 'V' && control && !shift) ||
                             (key == VK_INSERT && shift && !control));
  if (!paste || (flags & (static_cast<LPARAM>(1) << 30))) return false;
  POINT position = {};
  GetCursorPos(&position);
  ScreenToClient(window_, &position);
  ClipboardImage image = reader_(window_);
  if (!image.recognized) return false;  // Text keeps Flutter's normal paste path.
  image.position = position;
  suppressed = true;
  suppress_char_ = key == 'V';
  receiver_(std::move(image));
  return true;
}

LRESULT CALLBACK ImageClipboard::WindowProc(HWND window, UINT message, WPARAM key,
                                            LPARAM flags, UINT_PTR id, DWORD_PTR data) {
  auto* self = reinterpret_cast<ImageClipboard*>(data);
  if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(window, WindowProc, id);
    self->attached_ = false;
  } else if (message == WM_KEYDOWN || message == WM_KEYUP ||
             message == WM_CHAR || message == WM_KILLFOCUS) {
    try {
      const bool control = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
      const bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
      const bool alt = (GetKeyState(VK_MENU) & 0x8000) != 0 ||
                       (GetKeyState(VK_LWIN) & 0x8000) != 0 ||
                       (GetKeyState(VK_RWIN) & 0x8000) != 0;
      if (self->HandleKey(message, key, flags, control, shift, alt)) return 0;
    } catch (...) {
      // Exceptions must never escape a Windows window procedure.
    }
  }
  return DefSubclassProc(window, message, key, flags);
}
