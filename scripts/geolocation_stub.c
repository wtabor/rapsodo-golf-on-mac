// Drop-in replacement for the Rapsodo games' GeolocationPlugin.dll.
//
// The original asks WinRT Windows.Devices.Geolocation.Geolocator for access and a
// position. Wine doesn't grant it, so the game shows "Unable to get location
// permission state" and its "Open Settings" button (ms-settings:) does nothing.
// This stub reports access as Allowed and returns a fixed position taken from the
// environment (set in scripts/env.sh), which the game uses for elevation.
//
// ABI, from disassembling the original (sha256 46058374…, all three games):
//   CheckLocationPermission() -> 8-byte struct in RAX: {int32 status; bool ok}
//     status is GeolocationAccessStatus: 0 Unspecified, 1 Allowed, 2 Denied.
//   GetLocation() -> 32-byte struct via hidden pointer:
//     {double lat; double lon; double alt; int32 positionSource; bool ok}
//     ok=false and all-zero when there's no fix.
// Build: x86_64-w64-mingw32-gcc -shared -O2 -s -o GeolocationPlugin.dll geolocation_stub.c
#include <stdint.h>
#include <stdlib.h>
#include <windows.h>

typedef struct {
    int32_t status;
    uint8_t ok;
} LocationPermission;

typedef struct {
    double latitude;
    double longitude;
    double altitude;
    int32_t position_source;  // Windows PositionSource; 0 = Cellular
    uint8_t ok;
} Location;

static int env_double(const char *name, double *out) {
    char buf[64];
    DWORD n = GetEnvironmentVariableA(name, buf, sizeof buf);
    if (n == 0 || n >= sizeof buf) return 0;
    char *end;
    *out = strtod(buf, &end);
    return end != buf;
}

__declspec(dllexport) LocationPermission CheckLocationPermission(void) {
    LocationPermission p = {1, 1};  // Allowed
    return p;
}

__declspec(dllexport) Location GetLocation(void) {
    Location loc = {0};
    if (env_double("RGM_GEO_LAT", &loc.latitude) && env_double("RGM_GEO_LON", &loc.longitude)) {
        if (!env_double("RGM_GEO_ALT", &loc.altitude)) loc.altitude = 0.0;
        loc.ok = 1;
    }
    return loc;
}
