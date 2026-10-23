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
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#ifndef RGM_WINE
#error "RGM_WINE not defined"
#endif

int main(void) {
    setenv("WINEPREFIX", RGM_PREFIX, 1);
    setenv("WINEDEBUG", "-all", 1);
    // The games inherit this environment. Without these, DXVK on MoltenVK logs
    // ~500k "VkDescriptorPool exhausted" warnings (~86 MB) per 10-minute session.
    setenv("MVK_CONFIG_LOG_LEVEL", "1", 0);  // MoltenVK: errors only
    setenv("DXVK_LOG_LEVEL", "warn", 0);
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
                    "--disable-gpu-compositing", "--in-process-gpu", NULL};
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
