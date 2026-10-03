#ifndef RUNNER_IMAGE_DROP_TARGET_H_
#define RUNNER_IMAGE_DROP_TARGET_H_

#include <windows.h>
#include <ole2.h>
#include <oleidl.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>

// Receives local files only. Never returns MOVE: dropping into Plana must not
// remove the source in Explorer, even when Shift is held.
class ImageDropTarget final : public IDropTarget {
 public:
  ImageDropTarget(HWND window, flutter::BinaryMessenger* messenger);
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD keys,
                                      POINTL point, DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragOver(DWORD keys, POINTL point,
                                     DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragLeave() override;
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD keys,
                                 POINTL point, DWORD* effect) override;

 private:
  void SendPosition(const char* method, POINTL point,
                    flutter::EncodableList paths = {});
  ULONG references_ = 1;
  HWND window_;
  bool accepts_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
