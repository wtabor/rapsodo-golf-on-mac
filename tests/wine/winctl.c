// Keeps tier 3's windows out of the way: minimizes, without activating, every visible
// top-level window of the named programs, five times a second, until killed. The app
// shows its window again after each game, so a one-time minimize isn't enough.
// Usage: winctl.exe RapsodoGolf.exe DrivingRange.exe ...
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

static int nprogs;
static wchar_t **progs;

static BOOL CALLBACK each(HWND h, LPARAM unused) {
    (void)unused;
    if (!IsWindowVisible(h) || IsIconic(h)) return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!p) return TRUE;
    wchar_t path[MAX_PATH];
    DWORD len = MAX_PATH;
    BOOL ok = QueryFullProcessImageNameW(p, 0, path, &len);
    CloseHandle(p);
    if (!ok) return TRUE;
    const wchar_t *exe = wcsrchr(path, L'\\');
    exe = exe ? exe + 1 : path;
    for (int i = 0; i < nprogs; i++) {
        if (!_wcsicmp(exe, progs[i])) {
            ShowWindow(h, SW_SHOWMINNOACTIVE);
            wprintf(L"minimized %ls window %p\n", exe, (void *)h);
            fflush(stdout);
            break;
        }
    }
    return TRUE;
}

int wmain(int argc, wchar_t **argv) {
    nprogs = argc - 1;
    progs = argv + 1;
    if (!nprogs) {
        fwprintf(stderr, L"usage: winctl.exe PROGRAM.exe ...\n");
        return 2;
    }
    for (;;) {
        EnumWindows(each, 0);
        Sleep(200);
    }
}
