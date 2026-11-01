#include "proxy_assist.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <tlhelp32.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <cmath>
#include <cwctype>
#include <set>

namespace {
struct Apartment {
  Apartment() { winrt::init_apartment(winrt::apartment_type::multi_threaded); }
  ~Apartment() { winrt::uninit_apartment(); }
};

std::wstring ProcessName(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return {};
  wchar_t path[32768];
  DWORD length = static_cast<DWORD>(std::size(path));
  const bool ok = QueryFullProcessImageNameW(process, 0, path, &length) != FALSE;
  CloseHandle(process);
  if (!ok) return {};
  std::wstring name(path, length);
  name = name.substr(name.find_last_of(L"/\\") + 1);
  std::transform(name.begin(), name.end(), name.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return name;
}

std::string Classify(DWORD pid) {
  const auto name = ProcessName(pid);
  if (name.empty()) return "unknown";
  // Clash Verge Rev's own sidecars retain their identity in service mode.
  if (name.find(L"clash") != std::wstring::npos ||
      name == L"verge-mihomo.exe" || name == L"verge-mihomo-alpha.exe") return "clash";
  // A Mihomo core can belong to other frontends. Only call it Clash when its
  // actual parent is a Clash frontend; the core/port alone is not evidence.
  if (name.find(L"mihomo") != std::wstring::npos) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot != INVALID_HANDLE_VALUE) {
      PROCESSENTRY32W entry{};
      entry.dwSize = sizeof(entry);
      if (Process32FirstW(snapshot, &entry)) {
        do {
          if (entry.th32ProcessID == pid) {
            const auto parent = ProcessName(entry.th32ParentProcessID);
            CloseHandle(snapshot);
            return parent.find(L"clash") != std::wstring::npos ? "clash" : "other";
          }
        } while (Process32NextW(snapshot, &entry));
      }
      CloseHandle(snapshot);
    }
  }
  return "other";
}
}  // namespace

std::string RecognizeProxyImage(const std::vector<uint8_t>& bytes) {
  if (bytes.empty() || bytes.size() > 32 * 1024 * 1024) {
    throw ProxyAssistError("image_size", "Choose one screenshot smaller than 32 MB.");
  }
  Apartment apartment;
  using namespace winrt::Windows;
  auto engine = Media::Ocr::OcrEngine::TryCreateFromUserProfileLanguages();
  if (!engine) {
    engine = Media::Ocr::OcrEngine::TryCreateFromLanguage(Globalization::Language(L"en-US"));
  }
  if (!engine) throw ProxyAssistError("ocr_unavailable", "Windows OCR language is unavailable.");
  Storage::Streams::InMemoryRandomAccessStream stream;
  Storage::Streams::DataWriter writer(stream);
  writer.WriteBytes(bytes);
  writer.StoreAsync().get();
  writer.DetachStream();
  stream.Seek(0);
  auto decoder = Graphics::Imaging::BitmapDecoder::CreateAsync(stream).get();
  const auto width = decoder.PixelWidth();
  const auto height = decoder.PixelHeight();
  if (!width || !height || static_cast<uint64_t>(width) * height > 64000000) {
    throw ProxyAssistError("image_size", "Screenshot dimensions are too large.");
  }
  const auto limit = Media::Ocr::OcrEngine::MaxImageDimension();
  const double scale = std::min(1.0, static_cast<double>(limit) / std::max(width, height));
  std::string text;
  auto recognizeAtScale = [&](double factor) {
    Graphics::Imaging::BitmapTransform transform;
    transform.ScaledWidth(std::max(1u, static_cast<uint32_t>(std::floor(width * factor))));
    transform.ScaledHeight(std::max(1u, static_cast<uint32_t>(std::floor(height * factor))));
    auto bitmap = decoder.GetSoftwareBitmapAsync(
        Graphics::Imaging::BitmapPixelFormat::Bgra8,
        Graphics::Imaging::BitmapAlphaMode::Ignore, transform,
        Graphics::Imaging::ExifOrientationMode::RespectExifOrientation,
        Graphics::Imaging::ColorManagementMode::DoNotColorManage).get();
    auto recognized = engine.RecognizeAsync(bitmap).get();
    bool largeText = recognized.Lines().Size() == 0;
    for (const auto& line : recognized.Lines()) {
      for (const auto& word : line.Words()) {
        largeText = largeText || word.BoundingRect().Height > 40;
      }
      const auto value = winrt::to_string(line.Text()) + "\n";
      if (text.size() + value.size() > 128 * 1024) break;
      text += value;
    }
    return largeText;
  };
  // Windows OCR can drop Chinese labels in enlarged screenshots. Preserve both
  // readings; Dart deduplicates identical addresses and asks about disagreements.
  if (recognizeAtScale(scale) && std::max(width, height) * scale >= 600) {
    recognizeAtScale(scale * 0.5);
  }
  return text;
}

std::string DetectProxySoftware(const std::string& host, uint16_t port) {
  if (!port) return "unknown";
  const bool localhost = host == "localhost";
  IN_ADDR v4{};
  IN6_ADDR v6{};
  const bool ipv4 = InetPtonA(AF_INET, host.c_str(), &v4) == 1 &&
                    (ntohl(v4.S_un.S_addr) >> 24) == 127;
  const bool ipv6 = InetPtonA(AF_INET6, host.c_str(), &v6) == 1 &&
                    IN6_IS_ADDR_LOOPBACK(&v6);
  if (!localhost && !ipv4 && !ipv6) return "unknown";
  std::set<DWORD> owners;
  for (const auto family : {AF_INET, AF_INET6}) {
    if (!localhost && ((family == AF_INET && !ipv4) || (family == AF_INET6 && !ipv6))) continue;
    ULONG size = 0;
    auto status = GetExtendedTcpTable(nullptr, &size, FALSE, family,
                                     TCP_TABLE_OWNER_PID_LISTENER, 0);
    if (status != ERROR_INSUFFICIENT_BUFFER || size > 16 * 1024 * 1024) continue;
    std::vector<uint8_t> buffer(size);
    status = GetExtendedTcpTable(buffer.data(), &size, FALSE, family,
                                TCP_TABLE_OWNER_PID_LISTENER, 0);
    if (status != NO_ERROR) continue;
    if (family == AF_INET) {
      const auto* table = reinterpret_cast<MIB_TCPTABLE_OWNER_PID*>(buffer.data());
      for (DWORD i = 0; i < table->dwNumEntries; ++i) {
        const auto& row = table->table[i];
        const bool address = row.dwLocalAddr == 0 ||
            (localhost ? (ntohl(row.dwLocalAddr) >> 24) == 127 : row.dwLocalAddr == v4.S_un.S_addr);
        if (address && ntohs(static_cast<u_short>(row.dwLocalPort)) == port) owners.insert(row.dwOwningPid);
      }
    } else {
      const auto* table = reinterpret_cast<MIB_TCP6TABLE_OWNER_PID*>(buffer.data());
      for (DWORD i = 0; i < table->dwNumEntries; ++i) {
        const auto& row = table->table[i];
        const auto* address = reinterpret_cast<const IN6_ADDR*>(row.ucLocalAddr);
        if ((IN6_IS_ADDR_UNSPECIFIED(address) || IN6_IS_ADDR_LOOPBACK(address)) &&
            ntohs(static_cast<u_short>(row.dwLocalPort)) == port) owners.insert(row.dwOwningPid);
      }
    }
  }
  std::set<std::string> kinds;
  for (DWORD pid : owners) kinds.insert(Classify(pid));
  return kinds.size() == 1 ? *kinds.begin() : "unknown";
}
