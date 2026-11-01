// Native launcher for "Rapsodo Golf on Mac.app".
//
// Why a compiled binary instead of a shell script: macOS Local Network privacy is
// granted per app. With a script as CFBundleExecutable, macOS never showed the
// permission prompt and silently blocked the app's mDNS/multicast discovery when
// launched from Finder. A signed Mach-O main executable that stays the parent
// of Wine gets the prompt.
//
// Paths are baked in at build time by 50-make-launcher.sh (-D flags).
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#ifndef RGM_WINE
#error "RGM_WINE not defined"
#endif
#ifndef RGM_APPNAME_DYLIB
#error "RGM_APPNAME_DYLIB not defined"
#endif

int main(void) {
    setenv("WINEPREFIX", RGM_PREFIX, 1);
    setenv("WINEDEBUG", "-all", 1);
    // The games inherit this environment. Without these, DXVK on MoltenVK logs
    // ~500k "VkDescriptorPool exhausted" warnings (~86 MB) per 10-minute session.
    setenv("MVK_CONFIG_LOG_LEVEL", "1", 0);  // MoltenVK: errors only
    setenv("DXVK_LOG_LEVEL", "warn", 0);
    // Game video decodes through GStreamer. Its VideoToolbox plugins link a second
    // MoltenVK, which clashes with Wine's ("MVKBlockObserver is implemented in both");
    // with them ranked off, libav decodes instead.
    setenv("GST_PLUGIN_FEATURE_RANK", "vtdec:NONE,vtdec_hw:NONE,avfassetsrc:NONE", 0);
    // Show the app and each game under its own name instead of "wine" in the Dock,
    // Command-Tab and Force Quit (appname.c). Only if it's there: dyld refuses to start
    // a process whose inserted library is missing.
    if (access(RGM_APPNAME_DYLIB, R_OK) == 0)
        setenv("DYLD_INSERT_LIBRARIES", RGM_APPNAME_DYLIB, 0);
    if (chdir(RGM_APP_DIR) != 0) {
        perror("chdir " RGM_APP_DIR);
        return 1;
    }
    int log = open(RGM_LOG, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (log >= 0) {
        dup2(log, STDOUT_FILENO);
        dup2(log, STDERR_FILENO);
        close(log);
    }
    // GPU off: Chromium's GPU path doesn't render under Wine on macOS.
    char *argv[] = {RGM_WINE, "RapsodoGolf.exe", "--no-sandbox", "--disable-gpu",
                    "--disable-gpu-compositing", "--in-process-gpu", NULL, NULL};
    // Tests only (scripts/test.sh, tier 3): RGM_REMOTE_DEBUGGING_PORT=<port> adds
    // Chromium's DevTools port on 127.0.0.1 so the suite can drive the app. Unset in
    // normal use (play.sh never sets it), so the app starts exactly as before.
    char debug_arg[40];
    const char *port = getenv("RGM_REMOTE_DEBUGGING_PORT");
    if (port && *port && strlen(port) <= 5 && strspn(port, "0123456789") == strlen(port)) {
        snprintf(debug_arg, sizeof debug_arg, "--remote-debugging-port=%s", port);
        argv[6] = debug_arg;
    }
    // Spawn (don't exec): this signed launcher must stay alive as the
    // "responsible" process. If it exec'd into the unsigned wine binary, macOS
    // would attribute Wine's network traffic to an app with no identity and
    // silently block local-network access without ever prompting.
    pid_t pid;
    int rc = posix_spawn(&pid, RGM_WINE, NULL, NULL, argv, environ);
    if (rc != 0) {
        fprintf(stderr, "posix_spawn %s: %d\n", RGM_WINE, rc);
        return 1;
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
