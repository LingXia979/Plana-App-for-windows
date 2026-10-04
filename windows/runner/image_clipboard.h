#ifndef RUNNER_IMAGE_CLIPBOARD_H_
#define RUNNER_IMAGE_CLIPBOARD_H_

#include <windows.h>
#include <commctrl.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

struct ClipboardImage {
  bool recognized = false;
  bool bitmap = false;
  std::vector<uint8_t> bytes;
  std::vector<std::string> paths;
  std::string error;
  POINT position = {};
};

// Clipboard DIBs omit the BMP file header. Validate their bounds before adding
// that header; Flutter will decode and convert the bitmap to a portable PNG.
std::vector<uint8_t> ClipboardBitmapFile(const std::vector<uint8_t>& dib);
ClipboardImage ReadClipboardImage(HWND owner);

class ImageClipboard {
 public:
  using Receiver = std::function<void(ClipboardImage)>;
  using Reader = std::function<ClipboardImage(HWND)>;
  ImageClipboard(HWND window, Receiver receiver,
                 Reader reader = ReadClipboardImage);
  ~ImageClipboard();
  bool attached() const { return attached_; }

  // Kept independent of global keyboard state for deterministic native tests.
  bool HandleKey(UINT message, WPARAM key, LPARAM flags,
                 bool control, bool shift, bool alt);

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM key,
                                    LPARAM flags, UINT_PTR id, DWORD_PTR data);
  HWND window_;
  Receiver receiver_;
  Reader reader_;
  bool attached_ = false;
  bool suppress_v_ = false;
  bool suppress_insert_ = false;
  bool suppress_char_ = false;
};

#endif  // RUNNER_IMAGE_CLIPBOARD_H_
