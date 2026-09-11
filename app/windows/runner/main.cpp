#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

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
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // ---- single instance -------------------------------------------------
  //
  // fooplayer runs resident and HIDDEN in the tray, so launching it again
  // (a desktop shortcut, the Start menu) silently produced a SECOND copy
  // with no visible sign -- reported live as "two instances running".
  // That is not merely untidy: two instances both scan the roots and both
  // write `.library.json`, and one writer of that file is the invariant
  // protecting every track's date_added.
  //
  // So: first instance owns a named mutex. Any later launch hands the
  // existing window to the user (SW_SHOW un-hides a tray-resident copy)
  // and exits without starting an engine.
  HANDLE instance_mutex =
      ::CreateMutex(nullptr, TRUE, L"fooplayer_single_instance");
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"fooplayer");
    if (existing != nullptr) {
      ::ShowWindow(existing, SW_SHOW);
      ::SetForegroundWindow(existing);
    }
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Checked BEFORE the move below, which empties the vector. --tray is
  // what the Windows Startup-folder shortcut passes so fooplayer boots
  // into the notification area as the library's indexer.
  const bool start_hidden =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--tray") != command_line_arguments.end();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"fooplayer", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
