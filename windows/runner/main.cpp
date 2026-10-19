#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <algorithm>
#include <windows.h>
#include <ole2.h>

#include "flutter_window.h"
#include "utils.h"
#include "runtime_diagnostics.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  InitializeRuntimeDiagnostics(FLUTTER_VERSION);
  RecordRuntimeEvent("runner-start");
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT ole_status = ::OleInitialize(nullptr);
  RecordRuntimeEvent("ole-initialize", static_cast<DWORD>(ole_status));

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  const POINT anchor = {40, 40};
  const HMONITOR monitor = MonitorFromPoint(anchor, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!GetMonitorInfo(monitor, &monitor_info)) {
    RecordRuntimeEvent("monitor-info-failed", GetLastError());
    monitor_info.rcWork = {0, 0, 1280, 800};
  }
  const double scale = (std::max)(1.0, FlutterDesktopGetDpiForMonitor(monitor) / 96.0);
  const double available_width =
      (monitor_info.rcWork.right - monitor_info.rcWork.left) / scale;
  const double available_height =
      (monitor_info.rcWork.bottom - monitor_info.rcWork.top) / scale;
  Win32Window::Point origin(24, 24);
  Win32Window::Size size(
      static_cast<unsigned int>((std::clamp)(available_width - 48, 320.0, 1440.0)),
      static_cast<unsigned int>((std::clamp)(available_height - 72, 240.0, 900.0)));
  if (!window.Create(L"Plana app for windows", origin, size)) {
    RecordRuntimeEvent("window-create-failed", GetLastError());
    if (SUCCEEDED(ole_status)) ::OleUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg = {};
  BOOL message_status;
  while ((message_status = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (message_status == -1) {
    RecordRuntimeEvent("message-loop-failed", GetLastError());
  }
  if (SUCCEEDED(ole_status)) ::OleUninitialize();
  RecordRuntimeEvent("runner-exit", message_status == -1 ? ERROR_INVALID_DATA : 0);
  return message_status == -1 ? EXIT_FAILURE : EXIT_SUCCESS;
}
