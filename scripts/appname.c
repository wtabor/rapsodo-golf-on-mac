// Names each Wine process after the Windows program it runs ("Rapsodo Golf",
// "Driving Range", ...) instead of "wine" in the Dock, Command-Tab and Force Quit.
//
// macOS names an app without a bundle after its executable, and every Wine process
// runs the same lib/wine/x86_64-unix/wine. An app may rename only itself
// (`lsappinfo setinfo` on another process is ignored), so the launcher loads this
// into Wine with DYLD_INSERT_LIBRARIES; every Wine process the app starts, games
// included, inherits it. Once Wine's Cocoa app has finished launching, it sets the
// LaunchServices display name the way Chromium names its helper processes: private
// LaunchServices calls, looked up at run time, so a missing one changes nothing.
// Processes that never open a window (wineserver, services) are left alone.
//
// Built by 50-make-launcher.sh (x86_64, since Wine runs under Rosetta, plus arm64).
#include <CoreFoundation/CoreFoundation.h>
#include <crt_externs.h>
#include <string.h>
#include <strings.h>

typedef const void *ls_asn;
typedef ls_asn (*get_asn_fn)(void);
typedef OSStatus (*set_info_fn)(int session, ls_asn asn, CFStringRef key, CFTypeRef value,
                                CFDictionaryRef *out);

static const struct {
    const char *exe, *name;
} known[] = {
    {"RapsodoGolf.exe", "Rapsodo Golf"},
    {"DrivingRange.exe", "Driving Range"},
    {"Practice_TargetRange.exe", "Target Range"},
    {"RapsodoStudiosGolf_development.exe", "Rapsodo Studios"},
};

// Wine rewrites argv so that argv[0] is the Windows program ("C:\...\DrivingRange.exe").
// Its file name, mapped to a friendly name when known, without ".exe" otherwise.
static CFStringRef display_name(void) {
    char **argv = *_NSGetArgv();
    if (!argv || !argv[0]) return NULL;
    const char *exe = argv[0], *p;
    if ((p = strrchr(exe, '\\'))) exe = p + 1;
    if ((p = strrchr(exe, '/'))) exe = p + 1;
    if (!*exe || !strcmp(exe, "wine")) return NULL;
    for (size_t i = 0; i < sizeof(known) / sizeof(known[0]); i++)
        if (!strcasecmp(exe, known[i].exe))
            return CFStringCreateWithCString(NULL, known[i].name, kCFStringEncodingUTF8);
    size_t len = strlen(exe);
    if (len > 4 && !strcasecmp(exe + len - 4, ".exe")) len -= 4;
    return CFStringCreateWithBytes(NULL, (const UInt8 *)exe, (CFIndex)len, kCFStringEncodingUTF8, false);
}

static void did_finish_launching(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                                 const void *object, CFDictionaryRef info) {
    CFBundleRef ls = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.LaunchServices"));
    if (!ls) return;
    get_asn_fn get_asn = (get_asn_fn)CFBundleGetFunctionPointerForName(ls, CFSTR("_LSGetCurrentApplicationASN"));
    set_info_fn set_info = (set_info_fn)CFBundleGetFunctionPointerForName(ls, CFSTR("_LSSetApplicationInformationItem"));
    CFStringRef *key = (CFStringRef *)CFBundleGetDataPointerForName(ls, CFSTR("_kLSDisplayNameKey"));
    ls_asn asn;
    CFStringRef display;
    if (!get_asn || !set_info || !key || !*key || !(asn = get_asn()) || !(display = display_name())) return;
    set_info(-2 /* current session, as Chromium and WebKit pass it */, asn, *key, display, NULL);
    CFRelease(display);
}

__attribute__((constructor)) static void init(void) {
    // NSNotificationCenter's default center is the CF local center.
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL, did_finish_launching,
                                    CFSTR("NSApplicationDidFinishLaunchingNotification"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
