#ifndef RUNNER_PROXY_ASSIST_H_
#define RUNNER_PROXY_ASSIST_H_

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

class ProxyAssistError : public std::runtime_error {
 public:
  ProxyAssistError(const char* code, const char* message)
      : std::runtime_error(message), code(code) {}
  std::string code;
};

// Local-only OCR; neither image bytes nor recognized text leave the process.
std::string RecognizeProxyImage(const std::vector<uint8_t>& bytes);
// Only inspect the listener selected by host:port, not unrelated applications.
std::string DetectProxySoftware(const std::string& host, uint16_t port);

#endif
