/* rgm-display-fix.exe: repair Wine's display layout after a monitor is plugged in
 * or unplugged while Wine runs.
 *
 * win32u keeps each display source's logical index (the source order, primary
 * first) as a volatile registry symlink:
 *   HKLM\System\CurrentControlSet\Hardware Profiles\Current\System\
 *        CurrentControlSet\Control\Video\{gpu}\0000 -> ...\Video\{gpu}\Sources\<display id>
 * It re-points a link with REG_OPTION_OPEN_LINK, which neither win32u's
 * reg_create_key nor wineserver honors on create, so a link never changes target
 * within a session (Wine 11.16 and master). Once the primary display changes,
 * every process reads a stale layout: no primary source, a 1024x768 "WinDisc"
 * placeholder or the removed monitor's size. Games then size their fullscreen
 * window and cursor clip to that, and the cursor can't reach part of the screen.
 *
 * repair:  delete the stale links (only the links: opened with OBJ_OPENLINK and
 *          checked for a REG_LINK SymbolicLinkValue), start a fresh process so
 *          win32u finds no source, re-enumerates the displays and recreates the
 *          links, then broadcast WM_DISPLAYCHANGE and drop any cursor clip.
 * watch [exe]: poll Wine's monitor layout every second; after it changes (a monitor
 *          was plugged in or removed), let it settle and run repair once. With
 *          exe, exit once no process of that name is left (play.sh passes the app,
 *          so this never keeps Wine running after the app quits).
 * show:    print Wine's monitors.
 * refresh: (internal) the fresh process that triggers the re-enumeration.
 */
#include <windows.h>
#include <winternl.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <wchar.h>

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define KEY_VALUE_PARTIAL_INFO 2 /* KeyValuePartialInformation */
typedef struct { ULONG TitleIndex, Type, DataLength; UCHAR Data[1]; } KEY_VALUE_PARTIAL;

NTSTATUS WINAPI NtOpenKey(HANDLE *, ACCESS_MASK, const OBJECT_ATTRIBUTES *);
NTSTATUS WINAPI NtDeleteKey(HANDLE);
NTSTATUS WINAPI NtQueryValueKey(HANDLE, const UNICODE_STRING *, int, void *, ULONG, ULONG *);

#define VIDEO_KEY L"System\\CurrentControlSet\\Hardware Profiles\\Current\\System\\CurrentControlSet\\Control\\Video"
#define VIDEO_KEY_NT L"\\Registry\\Machine\\" VIDEO_KEY

static BOOL CALLBACK add_monitor(HMONITOR mon, HDC dc, RECT *rect, LPARAM lp)
{
    MONITORINFOEXW info = { .cbSize = sizeof(info) };
    WCHAR *sig = (WCHAR *)lp, line[128];
    GetMonitorInfoW(mon, (MONITORINFO *)&info);
    swprintf(line, ARRAY_SIZE(line), L"%ls %ld,%ld-%ld,%ld%ls; ", info.szDevice, info.rcMonitor.left,
             info.rcMonitor.top, info.rcMonitor.right, info.rcMonitor.bottom,
             (info.dwFlags & MONITORINFOF_PRIMARY) ? L" primary" : L"");
    if (wcslen(sig) + wcslen(line) < 2048) wcscat(sig, line);
    return TRUE;
}

static void layout(WCHAR *sig)
{
    sig[0] = 0;
    EnumDisplayMonitors(NULL, NULL, add_monitor, (LPARAM)sig);
}

static BOOL is_link_name(const WCHAR *name)
{
    if (wcslen(name) != 4) return FALSE;
    for (int i = 0; i < 4; i++) if (!iswxdigit(name[i])) return FALSE;
    return TRUE;
}

static BOOL query_value(HANDLE key, const WCHAR *name, ULONG *type)
{
    UNICODE_STRING str;
    BYTE buf[1024];
    ULONG size;

    RtlInitUnicodeString(&str, name);
    if (NtQueryValueKey(key, &str, KEY_VALUE_PARTIAL_INFO, buf, sizeof(buf), &size)) return FALSE;
    *type = ((KEY_VALUE_PARTIAL *)buf)->Type;
    return TRUE;
}

/* Delete one logical-index link key, never its target. The bug also leaves a stray
   REG_LINK SymbolicLinkValue in old targets, so a key that has a GPUID value is a
   source key, not a link. */
static BOOL delete_link(const WCHAR *gpu, const WCHAR *name)
{
    WCHAR path[512];
    UNICODE_STRING str;
    OBJECT_ATTRIBUTES attr;
    ULONG type;
    HANDLE key;
    BOOL ret = FALSE;

    swprintf(path, ARRAY_SIZE(path), L"%ls\\%ls\\%ls", VIDEO_KEY_NT, gpu, name);
    RtlInitUnicodeString(&str, path);
    InitializeObjectAttributes(&attr, &str, OBJ_CASE_INSENSITIVE | OBJ_OPENLINK, NULL, NULL);
    if (NtOpenKey(&key, DELETE | KEY_QUERY_VALUE, &attr)) return FALSE;

    if (query_value(key, L"SymbolicLinkValue", &type) && type == REG_LINK && !query_value(key, L"GPUID", &type))
        ret = !NtDeleteKey(key);
    CloseHandle(key);
    return ret;
}

static int delete_links(void)
{
    WCHAR gpu[256], name[256];
    HKEY video, gpu_key;
    int deleted = 0;

    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, VIDEO_KEY, 0, KEY_ENUMERATE_SUB_KEYS, &video)) return 0;
    for (DWORD i = 0, len = ARRAY_SIZE(gpu); !RegEnumKeyExW(video, i, gpu, &len, NULL, NULL, NULL, NULL);
         i++, len = ARRAY_SIZE(gpu))
    {
        if (RegOpenKeyExW(video, gpu, 0, KEY_ENUMERATE_SUB_KEYS, &gpu_key)) continue;
        /* Collect names first: deleting while enumerating shifts the indexes. */
        WCHAR names[32][8];
        int count = 0;
        for (DWORD j = 0, n = ARRAY_SIZE(name); count < 32 &&
             !RegEnumKeyExW(gpu_key, j, name, &n, NULL, NULL, NULL, NULL); j++, n = ARRAY_SIZE(name))
            if (is_link_name(name)) wcscpy(names[count++], name);
        RegCloseKey(gpu_key);
        for (int j = 0; j < count; j++) deleted += delete_link(gpu, names[j]);
    }
    RegCloseKey(video);
    return deleted;
}

static BOOL run_self(const WCHAR *arg)
{
    WCHAR exe[MAX_PATH], cmd[MAX_PATH + 32];
    STARTUPINFOW si = { .cb = sizeof(si) };
    PROCESS_INFORMATION pi;

    GetModuleFileNameW(NULL, exe, ARRAY_SIZE(exe));
    swprintf(cmd, ARRAY_SIZE(cmd), L"\"%ls\" %ls", exe, arg);
    /* Same stdout/stderr, so the repair's report lands in play.sh's log. */
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    if (!CreateProcessW(exe, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) return FALSE;
    WaitForSingleObject(pi.hProcess, 30000);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return TRUE;
}

static void repair(void)
{
    WCHAR before[2048], after[2048];
    DWORD_PTR result;

    layout(before);
    int deleted = delete_links();
    run_self(L"refresh");
    layout(after);
    SendMessageTimeoutW(HWND_BROADCAST, WM_DISPLAYCHANGE, 32,
                        MAKELPARAM(GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)),
                        SMTO_ABORTIFHUNG, 2000, &result);
    ClipCursor(NULL);
    printf("display-fix: removed %d stale link(s)\n  before: %ls\n  after:  %ls\n", deleted, before, after);
    fflush(stdout);
}

static BOOL process_running(const WCHAR *name)
{
    PROCESSENTRY32W entry = { .dwSize = sizeof(entry) };
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    BOOL found = FALSE;

    if (snap == INVALID_HANDLE_VALUE) return TRUE; /* can't tell: keep watching */
    for (BOOL more = Process32FirstW(snap, &entry); more && !found; more = Process32NextW(snap, &entry))
        found = !_wcsicmp(entry.szExeFile, name);
    CloseHandle(snap);
    return found;
}

int wmain(int argc, WCHAR **argv)
{
    WCHAR sig[2048], last[2048];
    const WCHAR *mode = argc > 1 ? argv[1] : L"show", *app = argc > 2 ? argv[2] : NULL;

    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (!wcscmp(mode, L"refresh")) { layout(sig); return 0; }
    if (!wcscmp(mode, L"repair")) { repair(); return 0; }
    if (!wcscmp(mode, L"show")) { layout(sig); printf("%ls\n", sig); return 0; }
    if (wcscmp(mode, L"watch")) { fprintf(stderr, "usage: rgm-display-fix.exe show|repair|watch [exe]\n"); return 2; }

    layout(last);
    printf("display-fix: watching the display layout: %ls\n", last);
    fflush(stdout);
    for (;;)
    {
        Sleep(1000);
        if (app && !process_running(app)) return 0;
        layout(sig);
        if (!wcscmp(sig, last)) continue;
        Sleep(2000); /* let macOS and Wine finish the reconfiguration */
        run_self(L"repair");
        Sleep(500);
        layout(last);
    }
}
