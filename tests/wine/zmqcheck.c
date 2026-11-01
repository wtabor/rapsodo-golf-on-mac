// Fix 1 (30-build-libzmq.sh): stock libzmq 4.3.5 deadlocks under Wine on macOS the
// first time it makes its internal socket pair (make_fdpair_tcpip sends 1 MB over a
// blocking loopback socket before reading). The rebuilt DLL must also keep CURVE
// (through the app's libsodium-26.dll), which the app and the monitor use.
// Loads <dir>\libzmq.dll by full path (its dependencies come from the same folder),
// then: create a context and sockets, PAIR round trip over loopback TCP, and a
// DEALER/ROUTER round trip with CURVE. Run it under a timeout: a deadlock hangs.
// Usage: zmqcheck.exe <folder with libzmq.dll>   Exit status 0 when all passed.
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define ZMQ_PAIR 0
#define ZMQ_DEALER 5
#define ZMQ_ROUTER 6
#define ZMQ_LINGER 17
#define ZMQ_RCVTIMEO 27
#define ZMQ_SNDTIMEO 28
#define ZMQ_LAST_ENDPOINT 32
#define ZMQ_CURVE_SERVER 47
#define ZMQ_CURVE_PUBLICKEY 48
#define ZMQ_CURVE_SECRETKEY 49
#define ZMQ_CURVE_SERVERKEY 50

typedef void *(*ctx_new_fn)(void);
typedef int (*ctx_term_fn)(void *);
typedef void *(*socket_fn)(void *, int);
typedef int (*close_fn)(void *);
typedef int (*sockopt_fn)(void *, int, const void *, size_t);
typedef int (*getsockopt_fn)(void *, int, void *, size_t *);
typedef int (*endpoint_fn)(void *, const char *);
typedef int (*send_fn)(void *, const void *, size_t, int);
typedef int (*recv_fn)(void *, void *, size_t, int);
typedef int (*keypair_fn)(char *, char *);
typedef int (*has_fn)(const char *);
typedef void (*version_fn)(int *, int *, int *);
typedef int (*errno_fn)(void);
typedef const char *(*strerror_fn)(int);

static ctx_new_fn zctx_new;
static ctx_term_fn zctx_term;
static socket_fn zsocket;
static close_fn zclose;
static sockopt_fn zset;
static getsockopt_fn zget;
static endpoint_fn zbind, zconnect;
static send_fn zsend;
static recv_fn zrecv;
static keypair_fn zkeypair;
static has_fn zhas;
static version_fn zversion;
static errno_fn zerrno;
static strerror_fn zstrerror;
static int failures;

static void check(int ok, const char *what) {
    printf("%s: %s", ok ? "ok" : "FAIL", what);
    if (!ok) printf(" (%s)", zstrerror ? zstrerror(zerrno()) : "?");
    printf("\n");
    if (!ok) failures++;
}

static void *sock(void *ctx, int type) {
    void *s = zsocket(ctx, type);
    int ms = 5000, zero = 0;
    if (s) {
        zset(s, ZMQ_RCVTIMEO, &ms, sizeof ms);
        zset(s, ZMQ_SNDTIMEO, &ms, sizeof ms);
        zset(s, ZMQ_LINGER, &zero, sizeof zero);
    }
    return s;
}

static int bind_any(void *s, char *endpoint, size_t len) {
    if (zbind(s, "tcp://127.0.0.1:*") != 0) return 0;
    return zget(s, ZMQ_LAST_ENDPOINT, endpoint, &len) == 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 2) { printf("usage: zmqcheck <folder with libzmq.dll>\n"); return 2; }
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%s\\libzmq.dll", argv[1]);
    HMODULE z = LoadLibraryExA(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!z) { printf("FAIL: load %s (error %lu)\n", path, GetLastError()); return 1; }
#define GET(var, type, name) var = (type)(void *)GetProcAddress(z, name); if (!var) { printf("FAIL: no export %s\n", name); return 1; }
    GET(zctx_new, ctx_new_fn, "zmq_ctx_new") GET(zctx_term, ctx_term_fn, "zmq_ctx_term")
    GET(zsocket, socket_fn, "zmq_socket") GET(zclose, close_fn, "zmq_close")
    GET(zset, sockopt_fn, "zmq_setsockopt") GET(zget, getsockopt_fn, "zmq_getsockopt")
    GET(zbind, endpoint_fn, "zmq_bind") GET(zconnect, endpoint_fn, "zmq_connect")
    GET(zsend, send_fn, "zmq_send") GET(zrecv, recv_fn, "zmq_recv")
    GET(zkeypair, keypair_fn, "zmq_curve_keypair") GET(zhas, has_fn, "zmq_has")
    GET(zversion, version_fn, "zmq_version") GET(zerrno, errno_fn, "zmq_errno")
    GET(zstrerror, strerror_fn, "zmq_strerror")
    int maj, min, pat;
    zversion(&maj, &min, &pat);
    printf("libzmq %d.%d.%d from %s\n", maj, min, pat, path);

    DWORD t0 = GetTickCount();
    void *ctx = zctx_new();
    check(ctx != NULL, "zmq_ctx_new");
    if (!ctx) return 1;
    // The first socket makes the internal signaler pair: this is where stock 4.3.5 hangs.
    void *a = sock(ctx, ZMQ_PAIR), *b = sock(ctx, ZMQ_PAIR);
    check(a && b, "zmq_socket (internal socket pair, the stock DLL's deadlock)");
    if (!a || !b) return 1;
    char ep[256], buf[64];
    int ok = bind_any(a, ep, sizeof ep) && zconnect(b, ep) == 0;
    check(ok, "PAIR bind/connect on loopback TCP");
    ok = ok && zsend(b, "ping", 4, 0) == 4 && zrecv(a, buf, sizeof buf, 0) == 4 && !memcmp(buf, "ping", 4);
    check(ok, "PAIR round trip");
    zclose(a);
    zclose(b);

    check(zhas("curve") == 1, "built with CURVE");
    char spub[41], ssec[41], cpub[41], csec[41];
    ok = zkeypair(spub, ssec) == 0 && zkeypair(cpub, csec) == 0;
    check(ok, "zmq_curve_keypair (libsodium)");
    if (ok) {
        void *srv = sock(ctx, ZMQ_ROUTER), *cli = sock(ctx, ZMQ_DEALER);
        int one = 1;
        ok = srv && cli && zset(srv, ZMQ_CURVE_SERVER, &one, sizeof one) == 0 &&
             zset(srv, ZMQ_CURVE_SECRETKEY, ssec, 40) == 0 && bind_any(srv, ep, sizeof ep) &&
             zset(cli, ZMQ_CURVE_SERVERKEY, spub, 40) == 0 && zset(cli, ZMQ_CURVE_PUBLICKEY, cpub, 40) == 0 &&
             zset(cli, ZMQ_CURVE_SECRETKEY, csec, 40) == 0 && zconnect(cli, ep) == 0;
        check(ok, "CURVE DEALER/ROUTER setup");
        char id[256];
        int n = -1;
        if (ok && zsend(cli, "hello", 5, 0) == 5) {
            int idlen = zrecv(srv, id, sizeof id, 0);
            n = idlen > 0 ? zrecv(srv, buf, sizeof buf, 0) : -1;
        }
        check(n == 5 && !memcmp(buf, "hello", 5), "CURVE round trip (encrypted handshake and message)");
        if (srv) zclose(srv);
        if (cli) zclose(cli);
    }
    zctx_term(ctx);
    printf("%s (%lu ms)\n", failures ? "zmqcheck: FAILED" : "zmqcheck: all checks passed", GetTickCount() - t0);
    return failures ? 1 : 0;
}
