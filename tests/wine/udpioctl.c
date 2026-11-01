// Fix 2 (patch_devicemanager.py) relies on how Wine answers the two UDP ioctls
// Go's runtime sends for every UDP socket: SIO_UDP_CONNRESET must succeed (Wine
// stubs it), because the patch turns the SIO_UDP_NETRESET call (which Wine
// rejects with WSAEOPNOTSUPP) into a second CONNRESET. If a Wine update stops
// accepting CONNRESET, the patched deviceManagerServer and MediaMTX break again.
// Usage: udpioctl.exe   Exit status 0 when SIO_UDP_CONNRESET succeeded.
#include <winsock2.h>
#include <mstcpip.h>
#include <stdio.h>

// The two codes patch_devicemanager.py swaps (0x9800000c and 0x9800000f).
#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif
#ifndef SIO_UDP_NETRESET
#define SIO_UDP_NETRESET _WSAIOW(IOC_VENDOR, 15)
#endif

static int try_ioctl(SOCKET s, DWORD code, const char *name) {
    BOOL off = FALSE;
    DWORD ret = 0;
    int rc = WSAIoctl(s, code, &off, sizeof off, NULL, 0, &ret, NULL, NULL);
    int err = rc ? WSAGetLastError() : 0;
    printf("%s (0x%08lx): %s", name, code, rc ? "error" : "ok");
    if (rc) printf(" %d", err);
    printf("\n");
    return rc == 0;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa)) { printf("FAIL: WSAStartup\n"); return 1; }
    SOCKET s = WSASocketW(AF_INET, SOCK_DGRAM, IPPROTO_UDP, NULL, 0, WSA_FLAG_OVERLAPPED);
    if (s == INVALID_SOCKET) { printf("FAIL: UDP socket (%d)\n", WSAGetLastError()); return 1; }
    int connreset = try_ioctl(s, SIO_UDP_CONNRESET, "SIO_UDP_CONNRESET");
    int netreset = try_ioctl(s, SIO_UDP_NETRESET, "SIO_UDP_NETRESET");
    printf("info: SIO_UDP_NETRESET %s\n", netreset ? "now works: the Fix 2 patch may no longer be needed"
                                                    : "rejected, as expected (that's what Fix 2 works around)");
    closesocket(s);
    WSACleanup();
    printf("%s\n", connreset ? "udpioctl: ok" : "udpioctl: FAILED (SIO_UDP_CONNRESET rejected)");
    return connreset ? 0 : 1;
}
