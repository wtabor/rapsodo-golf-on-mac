// Fix 4 (geolocation_stub.c): call a built GeolocationPlugin.dll through the raw ABI
// the games use (see the comment in scripts/geolocation_stub.c), not through the
// stub's own struct definitions:
//   CheckLocationPermission(): 8 bytes in RAX, int32 status (1 = Allowed) + bool ok
//   GetLocation(): 32-byte struct through a hidden pointer in RCX:
//     double lat, lon, alt; int32 positionSource; bool ok
// Expects RGM_GEO_LAT/LON/ALT set to the values given on the command line, or with
// "unset", that GetLocation reports no fix.
// Usage: geocheck.exe <GeolocationPlugin.dll> <lat> <lon> <alt> | <dll> unset
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

typedef unsigned long long (*perm_fn)(void);
typedef void *(*loc_fn)(void *hidden_return);

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 3) { printf("usage: geocheck <dll> <lat> <lon> <alt> | <dll> unset\n"); return 2; }
    HMODULE m = LoadLibraryA(argv[1]);
    if (!m) { printf("FAIL: load %s (error %lu)\n", argv[1], GetLastError()); return 1; }
    perm_fn perm = (perm_fn)(void *)GetProcAddress(m, "CheckLocationPermission");
    loc_fn loc = (loc_fn)(void *)GetProcAddress(m, "GetLocation");
    if (!perm || !loc) { printf("FAIL: missing export\n"); return 1; }
    int failures = 0;

    unsigned long long rax = perm();
    int status = (int)(rax & 0xffffffffu), ok = (int)((rax >> 32) & 0xff);
    printf("CheckLocationPermission: status %d ok %d\n", status, ok);
    if (status != 1 || ok != 1) { printf("FAIL: expected status 1 (Allowed), ok 1\n"); failures++; }

    unsigned char out[32];
    memset(out, 0xcc, sizeof out);
    void *ret = loc(out);
    double lat, lon, alt;
    int source;
    memcpy(&lat, out, 8);
    memcpy(&lon, out + 8, 8);
    memcpy(&alt, out + 16, 8);
    memcpy(&source, out + 24, 4);
    int fix = out[28];
    printf("GetLocation: lat %.6f lon %.6f alt %.2f source %d ok %d (returned %s pointer)\n", lat, lon, alt, source, fix,
           ret == out ? "the hidden" : "another");
    if (ret != out) { printf("FAIL: GetLocation must return the hidden pointer in RAX\n"); failures++; }
    if (!strcmp(argv[2], "unset")) {
        if (fix != 0) { printf("FAIL: expected no fix without RGM_GEO_*\n"); failures++; }
    } else if (argc >= 5) {
        double want_lat = atof(argv[2]), want_lon = atof(argv[3]), want_alt = atof(argv[4]);
        if (fix != 1 || fabs(lat - want_lat) > 1e-9 || fabs(lon - want_lon) > 1e-9 || fabs(alt - want_alt) > 1e-9) {
            printf("FAIL: expected %.6f %.6f %.2f with ok 1\n", want_lat, want_lon, want_alt);
            failures++;
        }
    }
    printf("%s\n", failures ? "geocheck: FAILED" : "geocheck: ok");
    return failures ? 1 : 0;
}
