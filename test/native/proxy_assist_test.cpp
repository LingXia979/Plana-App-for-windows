#include <winsock2.h>
#include <ws2tcpip.h>
#include "proxy_assist.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <algorithm>

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

int main(int argc, char** argv) {
  try {
    Require(argc >= 2, "Pass a synthetic OCR fixture");
    const auto hasFlag = [&](const std::string& flag) {
      for (int i = 2; i < argc; ++i) if (argv[i] == flag) return true;
      return false;
    };
    std::ifstream file(argv[1], std::ios::binary);
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)), {});
    const auto text = RecognizeProxyImage(bytes);
    std::cout << text;
    if (hasFlag("--text-only")) return 0;
    Require(text.find("7897") != std::string::npos, "OCR must read the mixed port");
    Require(text.find("9090") != std::string::npos, "OCR must retain other fields for disambiguation");
    std::string compact = text;
    compact.erase(std::remove(compact.begin(), compact.end(), ' '), compact.end());
    Require(compact.find(hasFlag("--chinese") ? "混合端口" : "MixedPort") != std::string::npos,
            "OCR must read the HTTP/Mixed label, not just the port number");
    bool rejected = false;
    try { RecognizeProxyImage({}); } catch (...) { rejected = true; }
    Require(rejected, "Empty images rejected");
    rejected = false;
    try { RecognizeProxyImage({1, 2, 3}); } catch (...) { rejected = true; }
    Require(rejected, "Invalid images rejected without crashing");
    Require(DetectProxySoftware("remote.example", 7897) == "unknown", "No remote software guessing");
    WSADATA data{};
    Require(WSAStartup(MAKEWORD(2, 2), &data) == 0, "WSAStartup");
    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in address{}; address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    Require(bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0, "bind");
    Require(listen(listener, 1) == 0, "listen");
    int size = sizeof(address);
    Require(getsockname(listener, reinterpret_cast<sockaddr*>(&address), &size) == 0, "getsockname");
    const auto kind = DetectProxySoftware("127.0.0.1", ntohs(address.sin_port));
    Require(kind == (hasFlag("--clash") ? "clash" : "other"), "Identify actual listener owner, independent of port");
    closesocket(listener); WSACleanup();
    std::cout << "Local OCR and listener identification passed.\n";
    return 0;
  } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
  catch (...) { std::cerr << "Windows OCR unavailable or native operation failed.\n"; return 1; }
}
