#include "runtime_diagnostics.h"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>

namespace fs = std::filesystem;

namespace {
void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

std::string Read(const fs::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input), {});
}

LONG WINAPI PreviousFilter(EXCEPTION_POINTERS*) {
  RecordRuntimeEvent("previous-filter");
  return EXCEPTION_EXECUTE_HANDLER;
}

DWORD RunChild(const fs::path& executable, const fs::path& directory,
               const wchar_t* mode) {
  std::wstring command = L"\"" + executable.wstring() + L"\" " + mode +
                         L" \"" + directory.wstring() + L"\"";
  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  Require(CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0,
                         nullptr, nullptr, &startup, &process) != FALSE,
          "start isolated diagnostics fixture");
  const DWORD wait = WaitForSingleObject(process.hProcess, 15000);
  if (wait != WAIT_OBJECT_0) TerminateProcess(process.hProcess, 1);
  DWORD exit_code = 1;
  GetExitCodeProcess(process.hProcess, &exit_code);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  Require(wait == WAIT_OBJECT_0, "diagnostics fixture exits without a dialog");
  return exit_code;
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  if (argc == 3) {
    SetUnhandledExceptionFilter(PreviousFilter);
    const bool opened = InitializeRuntimeDiagnostics("fixture", argv[2]);
    RecordRuntimeEvent("fixture-event");
    if (std::wstring(argv[1]) == L"blocked") return opened ? 1 : 0;
    if (!opened) return 1;
    if (std::wstring(argv[1]) == L"crash") {
      RaiseException(0xE000504C, EXCEPTION_NONCONTINUABLE, 0, nullptr);
      return 1;
    }
    RecordRuntimeEvent("runner-exit");
    return 0;
  }
  fs::path directory;
  try {
    wchar_t temp[MAX_PATH] = {};
    Require(GetTempPathW(MAX_PATH, temp) > 0, "temporary directory");
    directory = fs::path(temp) /
        (L"plana-diagnostics-test-" + std::to_wstring(GetCurrentProcessId()));
    fs::remove_all(directory);
    fs::create_directories(directory);
    const auto unrelated = directory / L"user-file.txt";
    std::ofstream(unrelated) << "keep";
    wchar_t executable[32768] = {};
    Require(GetModuleFileNameW(nullptr, executable, 32768) > 0, "fixture executable");
    for (int i = 0; i < 12; ++i) {
      Require(RunChild(executable, directory, L"write") == 0, "normal log session");
    }
    Require(RunChild(executable, unrelated, L"blocked") == 0,
            "unwritable diagnostics never prevents startup");
    Require(RunChild(executable, directory, L"crash") == 0xE000504C,
            "crash retains its exception exit code");
    size_t logs = 0, dumps = 0;
    bool found_exit = false, found_crash = false;
    for (const auto& entry : fs::directory_iterator(directory)) {
      if (entry.path().extension() == L".log") {
        ++logs;
        const auto text = Read(entry.path());
        found_exit |= text.find("runner-exit") != std::string::npos;
        found_crash |= text.find("native-crash code=0xE000504C") != std::string::npos;
        Require(text.find("fixture-event") != std::string::npos, "session events persist");
        if (text.find("native-crash") != std::string::npos) {
          Require(text.find("previous-filter") != std::string::npos,
                  "previous exception filter is preserved");
        }
      } else if (entry.path().extension() == L".dmp") {
        ++dumps;
        Require(Read(entry.path()).substr(0, 4) == "MDMP", "valid Windows minidump signature");
      }
    }
    Require(logs == 10, "bounded retention of ten native sessions");
    Require(dumps == 1 && found_crash, "crash log and minidump survive child exit");
    Require(found_exit, "normal exits are distinguishable from crashes");
    Require(Read(unrelated) == "keep", "unrelated files are preserved");
    fs::remove_all(directory);
    std::cout << "Native diagnostics persistence, retention and crash tests passed.\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    if (!directory.empty()) {
      std::wcerr << L"Evidence kept at " << directory.wstring() << L'\n';
    }
    return 1;
  }
}
