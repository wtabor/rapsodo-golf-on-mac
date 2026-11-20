// rgm-game-runner.exe: stands in for a Unity game's exe in the app's Wine when
// RGM_GAME_RUNTIME=crossover (49-game-runtime.sh puts it there and keeps the real exe
// as <Game>.exe.rgm-unity). The app starts it exactly as it starts the game
// ("C:\...\games\<id>\<ver>\<Game>.exe" -language=en) and checks the task list for
// <Game>.exe, so it has to stay up for as long as the game runs.
//
// It asks game-runner.sh (on the Mac side) to run the real game under CrossOver,
// through files in C:\ProgramData\rgm-game-runner\:
//   <pid>.req    written by us: line 1 our own path, line 2 our arguments (UTF-8).
//                Touched every second as a heartbeat; game-runner.sh closes the game
//                when it goes stale (the app killed us).
//   <pid>.started  written by game-runner.sh when it picks the request up.
//   <pid>.exit   written by game-runner.sh when the game exits: its exit code.
// The marker below lets 49 tell this stub from a real game exe.
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

__attribute__((used)) static const char marker[] = "RGM-GAME-RUNNER-STUB-1";

#define DIRW L"C:\\ProgramData\\rgm-game-runner"

static int write_utf8(HANDLE h, const wchar_t *s) {
  char buf[4 * 32768];
  int n = WideCharToMultiByte(CP_UTF8, 0, s, -1, buf, sizeof buf, NULL, NULL);
  DWORD w;
  return n > 0 && WriteFile(h, buf, (DWORD)(n - 1), &w, NULL);
}

static void fail(const wchar_t *msg) {
  MessageBoxW(NULL, msg, L"Rapsodo Golf on Mac", MB_OK | MB_ICONERROR);
}

int wmain(void) {
  wchar_t self[MAX_PATH], req[MAX_PATH], tmp[MAX_PATH], started[MAX_PATH], ex[MAX_PATH];
  if (!GetModuleFileNameW(NULL, self, MAX_PATH)) return 1;

  // Our arguments: the command line after argv[0] (quoted or not).
  const wchar_t *args = GetCommandLineW();
  if (*args == L'"') {
    args++;
    while (*args && *args != L'"') args++;
    if (*args) args++;
  } else {
    while (*args && *args != L' ' && *args != L'\t') args++;
  }
  while (*args == L' ' || *args == L'\t') args++;

  DWORD pid = GetCurrentProcessId();
  CreateDirectoryW(DIRW, NULL);
  swprintf(req, MAX_PATH, DIRW L"\\%lu.req", pid);
  swprintf(tmp, MAX_PATH, DIRW L"\\%lu.tmp", pid);
  swprintf(started, MAX_PATH, DIRW L"\\%lu.started", pid);
  swprintf(ex, MAX_PATH, DIRW L"\\%lu.exit", pid);

  HANDLE h = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
  if (h == INVALID_HANDLE_VALUE) {
    fail(L"Couldn't write the game request (C:\\ProgramData\\rgm-game-runner).");
    return 1;
  }
  int ok = write_utf8(h, self) && write_utf8(h, L"\n") && write_utf8(h, args) &&
           write_utf8(h, L"\n");
  CloseHandle(h);
  // Rename, so game-runner.sh never reads a half-written request.
  if (!ok || !MoveFileExW(tmp, req, MOVEFILE_REPLACE_EXISTING)) {
    DeleteFileW(tmp);
    fail(L"Couldn't write the game request (C:\\ProgramData\\rgm-game-runner).");
    return 1;
  }

  for (int waited = 0;; waited++) {
    Sleep(1000);
    HANDLE e = CreateFileW(ex, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL,
                           OPEN_EXISTING, 0, NULL);
    if (e != INVALID_HANDLE_VALUE) {
      char buf[32] = {0};
      DWORD r = 0;
      ReadFile(e, buf, sizeof buf - 1, &r, NULL);
      CloseHandle(e);
      DeleteFileW(req);
      DeleteFileW(started);
      DeleteFileW(ex);
      return atoi(buf);
    }
    // Heartbeat: game-runner.sh closes the game once this goes stale.
    HANDLE t = CreateFileW(req, FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE |
                           FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    if (t != INVALID_HANDLE_VALUE) {
      FILETIME now;
      GetSystemTimeAsFileTime(&now);
      SetFileTime(t, NULL, NULL, &now);
      CloseHandle(t);
    }
    if (waited == 20 && GetFileAttributesW(started) == INVALID_FILE_ATTRIBUTES) {
      DeleteFileW(req);
      fail(L"The game runner isn't running, so the game can't start.\n\n"
           L"Start Rapsodo Golf from the Dock (or scripts/play.sh). To run games in "
           L"this Wine again, remove RGM_GAME_RUNTIME=crossover from "
           L"scripts/env.local.sh and start the app again.");
      return 1;
    }
  }
}
