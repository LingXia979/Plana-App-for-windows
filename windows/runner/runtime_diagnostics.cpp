#include "runtime_diagnostics.h"

#include <dbghelp.h>
#include <shlobj.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <filesystem>
#include <iterator>
#include <vector>

namespace {
HANDLE log_file = INVALID_HANDLE_VALUE;
wchar_t dump_path[32768] = {};
LONG handling_crash = 0;
HMODULE dbghelp_module = nullptr;
using DumpWriter = decltype(&MiniDumpWriteDump);
DumpWriter dump_writer = nullptr;
LPTOP_LEVEL_EXCEPTION_FILTER previous_filter = nullptr;

void WriteLog(const char* message) {
  if (log_file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  WriteFile(log_file, message, static_cast<DWORD>(std::strlen(message)),
            &written, nullptr);
  FlushFileBuffers(log_file);
}

LONG WINAPI RecordCrash(EXCEPTION_POINTERS* exception) {
  if (InterlockedCompareExchange(&handling_crash, 1, 0) == 0) {
    const auto* record = exception ? exception->ExceptionRecord : nullptr;
    char line[1024];
    HMODULE fault_module = nullptr;
    wchar_t module_path[MAX_PATH] = {};
    const void* address = record ? record->ExceptionAddress : nullptr;
    if (address && GetModuleHandleExW(
                       GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(address), &fault_module)) {
      GetModuleFileNameW(fault_module, module_path, MAX_PATH);
    }
    const wchar_t* module_name = std::wcsrchr(module_path, L'\\');
    module_name = module_name ? module_name + 1 : module_path;
    std::snprintf(line, sizeof(line),
                  "native-crash code=0x%08lX address=%p module=%ls offset=0x%llX\r\n",
                  record ? record->ExceptionCode : DWORD{0}, address, module_name,
                  static_cast<unsigned long long>(
                      reinterpret_cast<ULONG_PTR>(address) -
                      reinterpret_cast<ULONG_PTR>(fault_module)));
    WriteLog(line);
    if (dump_writer && dump_path[0]) {
      HANDLE dump = CreateFileW(dump_path, GENERIC_WRITE, 0, nullptr,
                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (dump != INVALID_HANDLE_VALUE) {
        MINIDUMP_EXCEPTION_INFORMATION info = {};
        info.ThreadId = GetCurrentThreadId();
        info.ExceptionPointers = exception;
        const BOOL saved = dump_writer(
            GetCurrentProcess(), GetCurrentProcessId(), dump, MiniDumpNormal,
            exception ? &info : nullptr, nullptr, nullptr);
        const DWORD error = saved ? 0 : GetLastError();
        FlushFileBuffers(dump);
        CloseHandle(dump);
        std::snprintf(line, sizeof(line), "minidump saved=%d error=%lu\r\n",
                      saved ? 1 : 0, error);
        WriteLog(line);
        if (!saved) DeleteFileW(dump_path);
      }
    }
  }
  // Preserve Windows reporting and the previous handler, if one exists.
  return previous_filter ? previous_filter(exception) : EXCEPTION_CONTINUE_SEARCH;
}

void TrimReports(const std::filesystem::path& directory) {
  std::vector<std::filesystem::path> reports;
  std::error_code error;
  for (const auto& entry : std::filesystem::directory_iterator(directory, error)) {
    if (entry.path().filename().wstring().rfind(L"native-", 0) == 0 &&
        entry.path().extension() == L".log") {
      reports.push_back(entry.path());
    }
  }
  std::sort(reports.begin(), reports.end());
  for (size_t i = 0; i + 9 < reports.size(); ++i) {
    auto dump = reports[i];
    dump.replace_extension(L".dmp");
    std::filesystem::remove(reports[i], error);
    std::filesystem::remove(dump, error);
  }
}
}  // namespace

bool InitializeRuntimeDiagnostics(const char* version,
                                  const std::wstring& directory_override) {
  if (log_file != INVALID_HANDLE_VALUE) return true;
  try {
    std::filesystem::path directory(directory_override);
    if (directory.empty()) {
      PWSTR local_app_data = nullptr;
      const HRESULT status = SHGetKnownFolderPath(
          FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &local_app_data);
      if (SUCCEEDED(status) && local_app_data) directory = local_app_data;
      CoTaskMemFree(local_app_data);
      if (directory.empty()) {
        wchar_t temporary[MAX_PATH] = {};
        if (!GetTempPathW(MAX_PATH, temporary)) return false;
        directory = temporary;
      }
      directory /= L"Plana app for windows";
      directory /= L"diagnostics";
    }
    std::error_code error;
    std::filesystem::create_directories(directory, error);
    if (error) return false;
    TrimReports(directory);
    SYSTEMTIME now = {};
    GetSystemTime(&now);
    wchar_t name[100];
    std::swprintf(name, 100, L"native-%04u%02u%02u-%02u%02u%02u-%03u-%lu",
                   now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
                   now.wSecond, now.wMilliseconds, GetCurrentProcessId());
    const auto stem = directory / name;
    const auto log_path = stem.wstring() + L".log";
    log_file = CreateFileW(log_path.c_str(), FILE_APPEND_DATA,
                          FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                          CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (log_file == INVALID_HANDLE_VALUE) return false;
    const auto dump = stem.wstring() + L".dmp";
    if (dump.size() < std::size(dump_path)) {
      std::copy(dump.begin(), dump.end(), dump_path);
      dump_path[dump.size()] = L'\0';
    }
    // Resolve before crashing; loading DLLs in a fault handler is unsafe.
    dbghelp_module = LoadLibraryExW(L"dbghelp.dll", nullptr,
                                    LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (dbghelp_module) {
      const auto address = GetProcAddress(dbghelp_module, "MiniDumpWriteDump");
      static_assert(sizeof(address) == sizeof(dump_writer));
      std::memcpy(&dump_writer, &address, sizeof(dump_writer));
    }
    previous_filter = SetUnhandledExceptionFilter(RecordCrash);
    char line[256];
    std::snprintf(line, sizeof(line), "session-start version=%s pid=%lu\r\n",
                  version, GetCurrentProcessId());
    WriteLog(line);
    return true;
  } catch (...) {
    // Diagnostics must not make application startup fail.
    return false;
  }
}

void RecordRuntimeEvent(const char* event, DWORD error) {
  SYSTEMTIME now = {};
  GetSystemTime(&now);
  char line[512];
  std::snprintf(line, sizeof(line), "%02u:%02u:%02u.%03uZ %s error=%lu\r\n",
                now.wHour, now.wMinute, now.wSecond, now.wMilliseconds, event,
                error);
  WriteLog(line);
}
