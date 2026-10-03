#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <algorithm>
#include <windows.h>
#include <ole2.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::OleInitialize(nullptr);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  const POINT anchor = {40, 40};
  const HMONITOR monitor = MonitorFromPoint(anchor, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(monitor_info);
  GetMonitorInfo(monitor, &monitor_info);
  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const double available_width =
      (monitor_info.rcWork.right - monitor_info.rcWork.left) / scale;
  const double available_height =
      (monitor_info.rcWork.bottom - monitor_info.rcWork.top) / scale;
  Win32Window::Point origin(24, 24);
  Win32Window::Size size(
      static_cast<unsigned int>((std::min)(1440.0, available_width - 48)),
      static_cast<unsigned int>((std::min)(900.0, available_height - 72)));
  if (!window.Create(L"Plana app for windows", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::OleUninitialize();
  return EXIT_SUCCESS;
}
