#include "proxy_assist_channel.h"
#include "proxy_assist.h"
#include <flutter/standard_method_codec.h>
#include <winrt/base.h>

namespace { constexpr UINT_PTR kPollTimer = 0x504f4352; }

ProxyAssistChannel::ProxyAssistChannel(HWND owner, flutter::BinaryMessenger* messenger)
    : owner_(owner), channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "plana/proxy_assist", &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (jobs_.size() >= 2) { result->Error("busy", "Recognition is already running."); return; }
    const auto* args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    if (!args) { result->Error("invalid_args", "Missing arguments."); return; }
    std::function<std::string()> task;
    if (call.method_name() == "recognizeImage") {
      const auto it = args->find(flutter::EncodableValue("image"));
      const auto* bytes = it == args->end() ? nullptr : std::get_if<std::vector<uint8_t>>(&it->second);
      if (!bytes || bytes->empty() || bytes->size() > 32 * 1024 * 1024) {
        result->Error("image_size", "Choose one screenshot smaller than 32 MB."); return;
      }
      task = [data = *bytes]() { return RecognizeProxyImage(data); };
    } else if (call.method_name() == "detectSoftware") {
      const auto h = args->find(flutter::EncodableValue("host"));
      const auto p = args->find(flutter::EncodableValue("port"));
      const auto* host = h == args->end() ? nullptr : std::get_if<std::string>(&h->second);
      const auto* port = p == args->end() ? nullptr : std::get_if<int32_t>(&p->second);
      if (!host || !port || *port < 1 || *port > 65535) {
        result->Error("invalid_args", "Invalid proxy address."); return;
      }
      task = [name = *host, value = static_cast<uint16_t>(*port)]() { return DetectProxySoftware(name, value); };
    } else { result->NotImplemented(); return; }
    // Complete platform replies on the window thread, never from the OCR worker.
    if (!SetTimer(owner_, kPollTimer, 40, nullptr)) {
      result->Error("unavailable", "Could not schedule recognition."); return;
    }
    auto job = std::make_unique<Job>();
    job->result = std::move(result);
    try {
      jobs_.reserve(jobs_.size() + 1);
      job->worker = std::thread([state = job.get(), work = std::move(task)] {
        try { state->value = work(); }
        catch (const ProxyAssistError& e) { state->error = e.code; state->message = e.what(); }
        catch (const winrt::hresult_error&) { state->error = "ocr_unavailable"; }
        catch (...) { state->error = "recognition_failed"; }
        state->ready.store(true, std::memory_order_release);
      });
      jobs_.push_back(std::move(job));
    } catch (...) { job->result->Error("unavailable", "Could not start recognition."); }
  });
}

ProxyAssistChannel::~ProxyAssistChannel() {
  channel_->SetMethodCallHandler(nullptr);
  KillTimer(owner_, kPollTimer);
  // Join workers before the engine is destroyed. No worker holds a window pointer.
  for (auto& job : jobs_) {
    job->worker.join();
    job->result->Error("cancelled", "Window closed.");
  }
}

bool ProxyAssistChannel::HandleMessage(UINT message, WPARAM wparam) {
  if (message != WM_TIMER || wparam != kPollTimer) return false;
  for (auto it = jobs_.begin(); it != jobs_.end();) {
    auto& job = *it;
    if (!job->ready.load(std::memory_order_acquire)) { ++it; continue; }
    job->worker.join();
    if (job->error.empty()) job->result->Success(flutter::EncodableValue(job->value));
    else job->result->Error(job->error, job->message);
    it = jobs_.erase(it);
  }
  if (jobs_.empty()) KillTimer(owner_, kPollTimer);
  return true;
}
