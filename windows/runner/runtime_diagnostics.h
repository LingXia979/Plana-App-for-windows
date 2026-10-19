#ifndef RUNNER_RUNTIME_DIAGNOSTICS_H_
#define RUNNER_RUNTIME_DIAGNOSTICS_H_

#include <windows.h>

#include <string>

// Installed before the Flutter engine. Files stay on this computer.
bool InitializeRuntimeDiagnostics(
    const char* version, const std::wstring& directory_override = {});
void RecordRuntimeEvent(const char* event, DWORD error = 0);

#endif  // RUNNER_RUNTIME_DIAGNOSTICS_H_
