#ifndef RUNNER_PROXY_ASSIST_CHANNEL_H_
#define RUNNER_PROXY_ASSIST_CHANNEL_H_

#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include <atomic>
#include <thread>
#include <memory>
#include <vector>

class ProxyAssistChannel {
 public:
  ProxyAssistChannel(HWND owner, flutter::BinaryMessenger* messenger);
  ~ProxyAssistChannel();
  bool HandleMessage(UINT message, WPARAM wparam);
 private:
  struct Job {
    std::thread worker;
    std::atomic<bool> ready{false};
    std::string value;
    std::string error;
    std::string message;
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  };
  HWND owner_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::vector<std::unique_ptr<Job>> jobs_;
};
#endif
