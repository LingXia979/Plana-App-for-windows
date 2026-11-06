#ifndef RUNNER_IMAGE_TRANSFER_H_
#define RUNNER_IMAGE_TRANSFER_H_

#include <windows.h>
#include <ole2.h>

#include <cstdint>
#include <string>
#include <vector>

struct ImageTransferFormat {
  CLIPFORMAT format;
  std::vector<uint8_t> bytes;
};

// Every representation must come from the SAME already-processed export.
// Never include a gallery source path when metadata was removed/customized.
std::vector<ImageTransferFormat> ImageTransferFormats(
    const std::wstring& file_path, const std::vector<uint8_t>& png = {},
    const std::vector<uint8_t>& dib = {}, const std::string& internal_token = {});
IDataObject* CreateImageTransferDataObject(std::vector<ImageTransferFormat> formats);
IDropSource* CreateImageDropSource(HWND owner);
std::string ReadImageTransferToken(IDataObject* data);
bool WriteImageTransferClipboard(HWND owner,
                                 const std::vector<ImageTransferFormat>& formats);
HRESULT DragImageFile(HWND owner, const std::wstring& file_path,
                      const std::string& internal_token, DWORD* effect);

#endif
