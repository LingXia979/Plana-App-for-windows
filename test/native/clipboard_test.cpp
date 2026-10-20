#include "image_clipboard.h"

#include <cstring>
#include <iostream>
#include <stdexcept>

void Require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

template <typename T>
void Put(std::vector<uint8_t>& bytes, size_t offset, T value) {
  std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

void BitmapTests() {
  std::vector<uint8_t> dib(40 + 16);
  Put<uint32_t>(dib, 0, 40);
  Put<int32_t>(dib, 4, 2);
  Put<int32_t>(dib, 8, 2);
  Put<uint16_t>(dib, 12, 1);
  Put<uint16_t>(dib, 14, 24);
  dib[40] = 10; dib[41] = 20; dib[42] = 30;
  auto bitmap = ClipboardBitmapFile(dib);
  BITMAPFILEHEADER header;
  std::memcpy(&header, bitmap.data(), sizeof(header));
  Require(header.bfType == 0x4D42 && header.bfOffBits == 54 && header.bfSize == 70,
          "24-bit bitmap file header");
  Require(bitmap[54] == 10 && bitmap[55] == 20 && bitmap[56] == 30,
          "bitmap pixels retained");
  Put<int32_t>(dib, 8, -2);
  Require(ClipboardBitmapFile(dib).size() == 70, "top-down screenshot");
  dib.resize(50);
  bool rejected = false;
  try { ClipboardBitmapFile(dib); } catch (const std::invalid_argument&) { rejected = true; }
  Require(rejected, "truncated bitmap rejected");
  std::vector<uint8_t> v5(124 + 8);
  Put<uint32_t>(v5, 0, 124);
  Put<int32_t>(v5, 4, 2); Put<int32_t>(v5, 8, -1);
  Put<uint16_t>(v5, 12, 1); Put<uint16_t>(v5, 14, 32);
  Put<uint32_t>(v5, 16, BI_BITFIELDS);
  Put<uint32_t>(v5, 40, 0x00FF0000); Put<uint32_t>(v5, 44, 0x0000FF00);
  Put<uint32_t>(v5, 48, 0x000000FF); Put<uint32_t>(v5, 52, 0xFF000000);
  v5[127] = 120;
  bitmap = ClipboardBitmapFile(v5);
  std::memcpy(&header, bitmap.data(), sizeof(header));
  Require(header.bfOffBits == 138 && bitmap[141] == 120, "DIBV5 alpha retained");
  Put<int32_t>(v5, 8, INT32_MIN);
  rejected = false;
  try { ClipboardBitmapFile(v5); } catch (const std::invalid_argument&) { rejected = true; }
  Require(rejected, "height overflow rejected");
  for (size_t size = 0; size < 12; ++size) {
    rejected = false;
    try { ClipboardBitmapFile(std::vector<uint8_t>(size)); }
    catch (const std::invalid_argument&) { rejected = true; }
    Require(rejected, "short bitmap rejected");
  }
}

void ShortcutTests() {
  HWND window = CreateWindowExW(0, L"STATIC", L"Clipboard unit test", WS_OVERLAPPED,
      0, 0, 50, 50, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  Require(window != nullptr, "hidden fixture window");
  int reads = 0, imports = 0;
  bool has_image = true;
  bool has_text = false;
  bool from_file = false;
  {
    ImageClipboard clipboard(window,
      [&](ClipboardImage image) { Require(image.recognized, "recognized image"); ++imports; },
      [&](HWND) {
        ++reads;
        ClipboardImage image;
        image.recognized = has_image;
        image.has_text = has_text;
        image.from_file = from_file;
        return image;
      });
    Require(clipboard.attached(), "Flutter-child subclass mechanism");
    Require(clipboard.HandleKey(WM_KEYDOWN, 'V', 0, true, false, false), "Ctrl+V image");
    Require(clipboard.HandleKey(WM_KEYDOWN, 'V', 1LL << 30, true, false, false), "repeat consumed");
    Require(reads == 1 && imports == 1, "one paste per press");
    Require(clipboard.HandleKey(WM_CHAR, 0x16, 0, true, false, false), "paste char consumed");
    Require(clipboard.HandleKey(WM_KEYUP, 'V', 0, false, false, false), "key-up consumed");
    has_image = false;
    Require(!clipboard.HandleKey(WM_KEYDOWN, 'V', 0, true, false, false), "plain text forwarded");
    Require(!clipboard.HandleKey(WM_KEYUP, 'V', 0, false, false, false), "plain text key-up forwarded");
    Require(imports == 1, "text is not imported");
    has_image = true;
    has_text = true;
    Require(!clipboard.HandleKey(WM_KEYDOWN, 'V', 0, true, false, false),
            "image with usable text is forwarded");
    Require(!clipboard.HandleKey(WM_KEYUP, 'V', 0, false, false, false),
            "mixed text key-up forwarded");
    Require(imports == 1, "mixed text is not imported");
    from_file = true;
    Require(clipboard.HandleKey(WM_KEYDOWN, 'V', 0, true, false, false),
            "copied image file overrides its filename text");
    Require(clipboard.HandleKey(WM_KEYUP, 'V', 0, false, false, false),
            "copied file key-up consumed");
    Require(imports == 2, "copied image file imported");
    from_file = false;
    Require(!clipboard.HandleKey(WM_KEYDOWN, 'V', 0, true, false, false),
            "next mixed text paste forwarded without a prior WM_CHAR");
    Require(!clipboard.HandleKey(WM_CHAR, 0x16, 0, true, false, false),
            "next text paste character forwarded");
    Require(!clipboard.HandleKey(WM_KEYUP, 'V', 0, false, false, false),
            "next text key-up forwarded");
    has_text = false;
    Require(!clipboard.HandleKey(WM_KEYDOWN, 'V', 0, true, true, false), "Ctrl+Shift+V retained");
    Require(!clipboard.HandleKey(WM_KEYDOWN, 'V', 0, true, false, true), "Alt shortcut retained");
    Require(clipboard.HandleKey(WM_KEYDOWN, VK_INSERT, 0, false, true, false), "Shift+Insert image");
    Require(clipboard.HandleKey(WM_KEYUP, VK_INSERT, 0, false, false, false), "Insert key-up consumed");
    Require(imports == 3, "alternate paste shortcut");
    clipboard.HandleKey(WM_KILLFOCUS, 0, 0, false, false, false);
  }
  DestroyWindow(window);
}

void TextTests() {
  const wchar_t normal[] = L"hello";
  Require(ClipboardUnicodeText(normal, sizeof(normal)) == L"hello",
          "bounded Unicode clipboard text");
  const wchar_t early_end[] = {L'a', L'\0', L'b'};
  Require(ClipboardUnicodeText(early_end, sizeof(early_end)) == L"a",
          "text ends at its first terminator");
  const wchar_t unterminated[] = {L'a', L'b'};
  bool rejected = false;
  try { ClipboardUnicodeText(unterminated, sizeof(unterminated)); }
  catch (const std::invalid_argument&) { rejected = true; }
  Require(rejected, "unterminated text never reads past its memory block");
  for (size_t length : {size_t{0}, size_t{1}, size_t{3}}) {
    rejected = false;
    try { ClipboardUnicodeText(unterminated, length); }
    catch (const std::invalid_argument&) { rejected = true; }
    Require(rejected, "short or odd text blocks rejected");
  }
}

int main() {
  try {
    BitmapTests();
    TextTests();
    ShortcutTests();
    std::cout << "Clipboard bitmap and shortcut tests passed; system clipboard untouched.\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
