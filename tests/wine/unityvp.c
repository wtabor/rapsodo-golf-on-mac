// Read a video the way Unity 2022's VideoPlayer (WindowsVideoMedia) does, per
// UnityPlayer.dll: async source reader, DXGI device manager, DISABLE_DXVA=0,
// HARDWARE_TRANSFORMS=1, ADVANCED_VIDEO_PROCESSING=1, D3D11_BIND_FLAGS=8,
// XVP_DISABLE_FRC=1, output ARGB32 (D3D) and per frame IMFDXGIBuffer ->
// ID3D11Texture2D. Then copy each texture back and check it holds a picture.
// NOD3D=1 is the system-memory path Unity takes once patch_unity_video.py hides
// MFCreateDXGIDeviceManager (no DXGI manager, Unity's stride lookup and copy).
// Usage: unityvp.exe <file.mp4>   env: OUT=nv12|argb|rgb32  ADV=0  SYNC=1  NOD3D=1  HOLD=n
// Last line: "summary: frames N first_ts T last_ts T nonblank N" (times in 100 ns);
// scripts/test.sh (tier 2) checks it. Exit status 0 when at least one frame came out.
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <stdio.h>
#include <stdlib.h>

static const GUID XVP_DISABLE_FRC = {0x2c0afa19, 0x7a97, 0x4d5a, {0x9e, 0xe8, 0x16, 0xd4, 0xfc, 0x51, 0x8d, 0x8c}};

static ID3D11Device *dev;
static ID3D11DeviceContext *ctx;
static IMFSourceReader *reader;
static HANDLE done;
static volatile LONG frames, d3dframes, callbacks, nonblank;
static LONGLONG first_ts = -1, last_ts = -1;
static HRESULT last_status;
static IMFSample *held[1024]; static int nheld, hold_max;
static void hold(IMFSample *s) { if (!hold_max) return; if (nheld == hold_max) { IMFSample_Release(held[0]); memmove(held, held + 1, sizeof(*held) * --nheld); } IMFSample_AddRef(s); held[nheld++] = s; }

static int env_is(const char *name, const char *val) {
    const char *v = getenv(name);
    return v && !_stricmp(v, val);
}

static LONG unity_stride;
static void unity_copy(IMFSample *sample, int n) {
    IMFMediaBuffer *buf = NULL; IMF2DBuffer *b2 = NULL;
    if (FAILED(IMFSample_ConvertToContiguousBuffer(sample, &buf))) { printf("frame %d: ConvertToContiguousBuffer failed\n", n); return; }
    if (SUCCEEDED(IMFMediaBuffer_QueryInterface(buf, &IID_IMF2DBuffer, (void **)&b2))) {
        BYTE *scan0; LONG pitch; DWORD len = 0;
        HRESULT hr = IMF2DBuffer_Lock2D(b2, &scan0, &pitch);
        IMF2DBuffer_GetContiguousLength(b2, &len);
        DWORD rows = unity_stride ? len / (DWORD)unity_stride : 0;
        double top = 0, bottom = 0;
        if (SUCCEEDED(hr)) {
            for (int y = 0; y < 64; y++) for (int x = 0; x < 480; x++) {
                top += scan0[(LONG)y * pitch + x * (abs(pitch) >= 1920 ? 4 : 1) + 1];
                bottom += scan0[(LONG)(639 - y) * pitch + x * (abs(pitch) >= 1920 ? 4 : 1) + 1];
            }
            IMF2DBuffer_Unlock2D(b2);
        }
        if (n < 2) printf("frame %d: Unity copy: IMF2DBuffer Lock2D 0x%08lx pitch %ld, contiguous %lu, unity stride %ld -> rows %lu; top rows %.1f bottom rows %.1f\n",
                          n, hr, pitch, len, unity_stride, rows, top / (64 * 480), bottom / (64 * 480));
        IMF2DBuffer_Release(b2);
    } else {
        BYTE *p; DWORD max, len;
        if (n < 2 && SUCCEEDED(IMFMediaBuffer_Lock(buf, &p, &max, &len))) {
            int bpp = len >= 480 * 640 * 4 ? 4 : 1, off = bpp == 4 ? 1 : 0;
            double top = 0, bottom = 0;
            for (int y = 0; y < 64; y++) for (int x = 0; x < 480; x++) {
                top += p[(size_t)y * 480 * bpp + x * bpp + off];
                bottom += p[(size_t)(639 - y) * 480 * bpp + x * bpp + off];
            }
            printf("frame %d: no IMF2DBuffer, Lock len %lu, unity stride %ld -> rows %lu; memory rows 0-63 mean %.1f, rows 576-639 mean %.1f\n",
                   n, len, unity_stride, unity_stride ? len / (DWORD)labs(unity_stride) : 0, top / (64 * 480), bottom / (64 * 480));
            IMFMediaBuffer_Unlock(buf);
        }
    }
    IMFMediaBuffer_Release(buf);
}

static void inspect(IMFSample *sample, int n) {
    if (getenv("NOD3D")) unity_copy(sample, n);
    DWORD count = 0;
    IMFSample_GetBufferCount(sample, &count);
    IMFMediaBuffer *buf = NULL;
    if (FAILED(IMFSample_GetBufferByIndex(sample, 0, &buf))) return;
    IMFDXGIBuffer *dbuf = NULL;
    if (FAILED(IMFMediaBuffer_QueryInterface(buf, &IID_IMFDXGIBuffer, (void **)&dbuf))) {
        BYTE *p; DWORD max, len;
        if (SUCCEEDED(IMFMediaBuffer_Lock(buf, &p, &max, &len))) {
            BYTE lo = 255, hi = 0;
            for (DWORD i = 0; i < len; i += 61) { if (p[i] < lo) lo = p[i]; if (p[i] > hi) hi = p[i]; }
            if (len && hi - lo > 16) InterlockedIncrement(&nonblank);
            if (n < 3) {
                unsigned long long sum = 0; DWORD nz = 0;
                for (DWORD i = 0; i < len; i++) { sum += p[i]; nz += p[i] != 0; }
                printf("frame %d: system memory buffer, %lu bytes, mean %.1f, nonzero %lu\n", n, len, len ? (double)sum / len : 0, nz);
            }
            IMFMediaBuffer_Unlock(buf);
        }
        IMFMediaBuffer_Release(buf);
        return;
    }
    InterlockedIncrement(&d3dframes);
    ID3D11Texture2D *tex = NULL;
    UINT sub = 0;
    HRESULT hr = IMFDXGIBuffer_GetResource(dbuf, &IID_ID3D11Texture2D, (void **)&tex);
    IMFDXGIBuffer_GetSubresourceIndex(dbuf, &sub);
    if (SUCCEEDED(hr) && (n < 1 || n % 10 == 0)) {
        D3D11_TEXTURE2D_DESC d;
        ID3D11Texture2D_GetDesc(tex, &d);
        D3D11_TEXTURE2D_DESC sd = d;
        sd.Usage = D3D11_USAGE_STAGING; sd.BindFlags = 0; sd.MiscFlags = 0;
        sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ; sd.ArraySize = 1; sd.MipLevels = 1;
        ID3D11Texture2D *st = NULL;
        HRESULT h2 = ID3D11Device_CreateTexture2D(dev, &sd, NULL, &st);
        double mean = -1, amean = -1; UINT nz = 0, total = 0; unsigned long long asum = 0, acnt = 0;
        if (SUCCEEDED(h2)) {
            ID3D11DeviceContext_CopySubresourceRegion(ctx, (ID3D11Resource *)st, 0, 0, 0, 0, (ID3D11Resource *)tex, sub, NULL);
            D3D11_MAPPED_SUBRESOURCE m;
            h2 = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)st, 0, D3D11_MAP_READ, 0, &m);
            if (SUCCEEDED(h2)) {
                UINT bpp = d.Format == DXGI_FORMAT_NV12 ? 1 : 4;
                unsigned long long sum = 0;
                for (UINT y = 0; y < d.Height; y++) {
                    const BYTE *row = (const BYTE *)m.pData + (size_t)y * m.RowPitch;
                    for (UINT x = 0; x < d.Width * bpp; x++) {
                        if (bpp == 4 && x % 4 == 3) { asum += row[x]; acnt++; continue; }
                        sum += row[x]; nz += row[x] != 0; total++;
                    }
                }
                mean = total ? (double)sum / total : 0; amean = acnt ? (double)asum / acnt : -1;
                ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)st, 0);
            }
            ID3D11Texture2D_Release(st);
        }
        printf("frame %d: buffers %lu, texture %ux%u fmt %d bind 0x%x misc 0x%x array %u sub %u; readback 0x%08lx mean %.1f nonzero %u/%u alpha mean %.1f\n",
               n, count, d.Width, d.Height, d.Format, d.BindFlags, d.MiscFlags, d.ArraySize, sub, h2, mean, nz, total, amean);
    } else if (FAILED(hr)) {
        printf("frame %d: GetResource 0x%08lx\n", n, hr);
    }
    if (tex) ID3D11Texture2D_Release(tex);
    IMFDXGIBuffer_Release(dbuf);
    IMFMediaBuffer_Release(buf);
}

static HRESULT WINAPI cb_qi(IMFSourceReaderCallback *iface, REFIID riid, void **out) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IMFSourceReaderCallback)) {
        *out = iface;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG WINAPI cb_addref(IMFSourceReaderCallback *iface) { return 2; }
static ULONG WINAPI cb_release(IMFSourceReaderCallback *iface) { return 1; }
static HRESULT WINAPI cb_on_read(IMFSourceReaderCallback *iface, HRESULT status, DWORD stream, DWORD flags, LONGLONG ts, IMFSample *sample) {
    LONG c = InterlockedIncrement(&callbacks);
    if (c <= 5 || hold_max || FAILED(status) || (flags & ~MF_SOURCE_READERF_ENDOFSTREAM))
        printf("callback %ld: status 0x%08lx stream %lu flags 0x%lx ts %lld sample %p\n", c, status, stream, flags, ts, sample);
    last_status = status;
    if (sample) {
        if (first_ts < 0) first_ts = ts;
        last_ts = ts;
        inspect(sample, InterlockedIncrement(&frames) - 1); hold(sample);
    }
    if (FAILED(status) || (flags & (MF_SOURCE_READERF_ENDOFSTREAM | MF_SOURCE_READERF_ERROR)) || c > 400) {
        SetEvent(done);
        return S_OK;
    }
    HRESULT hr = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, NULL, NULL, NULL, NULL);
    if (FAILED(hr)) { printf("ReadSample (async) 0x%08lx\n", hr); SetEvent(done); }
    return S_OK;
}
static HRESULT WINAPI cb_on_flush(IMFSourceReaderCallback *iface, DWORD stream) { return S_OK; }
static HRESULT WINAPI cb_on_event(IMFSourceReaderCallback *iface, DWORD stream, IMFMediaEvent *event) { return S_OK; }
static IMFSourceReaderCallbackVtbl cb_vtbl = {cb_qi, cb_addref, cb_release, cb_on_read, cb_on_flush, cb_on_event};
static IMFSourceReaderCallback cb = {&cb_vtbl};

int wmain(int argc, wchar_t **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);  // keep output if the test's timeout kills us
    if (argc < 2) { printf("usage: unityvp <file>\n"); return 2; }
    hold_max = getenv("HOLD") ? atoi(getenv("HOLD")) : 0;
    BOOL use_d3d = !getenv("NOD3D"), sync = env_is("SYNC", "1"), adv = !env_is("ADV", "0");
    const GUID *sub = use_d3d ? &MFVideoFormat_ARGB32 : &MFVideoFormat_NV12;
    if (env_is("OUT", "nv12")) sub = &MFVideoFormat_NV12;
    if (env_is("OUT", "rgb32")) sub = &MFVideoFormat_RGB32;
    if (env_is("OUT", "argb")) sub = &MFVideoFormat_ARGB32;
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION, MFSTARTUP_FULL);
    done = CreateEventW(NULL, TRUE, FALSE, NULL);
    IMFAttributes *attr = NULL;
    MFCreateAttributes(&attr, 8);
    if (!sync) IMFAttributes_SetUnknown(attr, &MF_SOURCE_READER_ASYNC_CALLBACK, (IUnknown *)&cb);
    IMFAttributes_SetUINT32(attr, &MF_SOURCE_READER_DISABLE_DXVA, 0);
    IMFAttributes_SetUINT32(attr, &MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1);
    if (adv) {
        IMFAttributes_SetUINT32(attr, &MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1);
        IMFAttributes_SetUINT32(attr, &MF_SOURCE_READER_D3D11_BIND_FLAGS, D3D11_BIND_SHADER_RESOURCE);
        IMFAttributes_SetUINT32(attr, &XVP_DISABLE_FRC, 1);
    }
    if (use_d3d) {
        D3D_FEATURE_LEVEL fl;
        UINT devflags = getenv("DEVFLAGS") ? strtoul(getenv("DEVFLAGS"), NULL, 0) : (D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT);
        D3D_FEATURE_LEVEL want = D3D_FEATURE_LEVEL_11_0;
        HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, devflags,
                                       getenv("FL110") ? &want : NULL, getenv("FL110") ? 1 : 0, D3D11_SDK_VERSION, &dev, &fl, &ctx);
        printf("device flags 0x%x, feature level 0x%x\n", devflags, fl);
        if (FAILED(hr)) { printf("D3D11CreateDevice 0x%08lx\n", hr); return 1; }
        ID3D10Multithread *mt = NULL;
        if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_ID3D10Multithread, (void **)&mt))) {
            ID3D10Multithread_SetMultithreadProtected(mt, TRUE);
            ID3D10Multithread_Release(mt);
        }
        UINT token = 0;
        IMFDXGIDeviceManager *mgr = NULL;
        MFCreateDXGIDeviceManager(&token, &mgr);
        IMFDXGIDeviceManager_ResetDevice(mgr, (IUnknown *)dev, token);
        IMFAttributes_SetUnknown(attr, &MF_SOURCE_READER_D3D_MANAGER, (IUnknown *)mgr);
    }
    printf("mode: %s, %s, advanced %d, output %s\n", sync ? "sync" : "async", use_d3d ? "D3D11" : "no D3D", adv,
           sub == &MFVideoFormat_NV12 ? "NV12" : sub == &MFVideoFormat_RGB32 ? "RGB32" : "ARGB32");
    DWORD t0 = GetTickCount();
    HRESULT hr = MFCreateSourceReaderFromURL(argv[1], attr, &reader);
    printf("MFCreateSourceReaderFromURL: 0x%08lx (%lu ms)\n", hr, GetTickCount() - t0);
    if (FAILED(hr)) return 1;
    IMFMediaType *type = NULL;
    MFCreateMediaType(&type);
    IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, sub);
    if (env_is("OUT", "native")) IMFSourceReader_GetNativeMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &type);
    hr = IMFSourceReader_SetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, type);
    printf("SetCurrentMediaType: 0x%08lx\n", hr);
    if (FAILED(hr)) return 1;
    IMFMediaType *cur = NULL;
    if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, &cur))) {
        GUID g; UINT64 fs = 0; UINT32 stride = 0;
        IMFMediaType_GetGUID(cur, &MF_MT_SUBTYPE, &g);
        IMFMediaType_GetUINT64(cur, &MF_MT_FRAME_SIZE, &fs);
        IMFMediaType_GetUINT32(cur, &MF_MT_DEFAULT_STRIDE, &stride);
        printf("current type: subtype %08lx, %ux%u, stride %d\n", g.Data1, (UINT)(fs >> 32), (UINT)fs, (int)stride);
        if (FAILED(IMFMediaType_GetUINT32(cur, &MF_MT_DEFAULT_STRIDE, (UINT32 *)&unity_stride))) {
            HRESULT h = MFGetStrideForBitmapInfoHeader(g.Data1, (UINT)(fs >> 32), &unity_stride);
            printf("no MF_MT_DEFAULT_STRIDE; MFGetStrideForBitmapInfoHeader 0x%08lx -> %ld\n", h, unity_stride);
        }
    }
    t0 = GetTickCount();
    if (sync) {
        for (;;) {
            DWORD stream, flags = 0; LONGLONG ts; IMFSample *sample = NULL;
            hr = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &stream, &flags, &ts, &sample);
            if (FAILED(hr)) { printf("ReadSample 0x%08lx\n", hr); break; }
            if (sample) {
                if (first_ts < 0) first_ts = ts;
                last_ts = ts;
                inspect(sample, frames++); IMFSample_Release(sample);
            }
            if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
        }
    } else {
        hr = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, NULL, NULL, NULL, NULL);
        printf("ReadSample (async start): 0x%08lx\n", hr);
        if (WaitForSingleObject(done, 20000) == WAIT_TIMEOUT) printf("TIMEOUT: no end of stream after 20 s\n");
    }
    printf("callbacks %ld, frames %ld (D3D %ld), last status 0x%08lx, %lu ms\n", callbacks, frames, d3dframes, last_status, GetTickCount() - t0);
    printf("summary: frames %ld first_ts %lld last_ts %lld nonblank %ld\n", frames, first_ts, last_ts, nonblank);
    fflush(stdout);
    return frames > 0 ? 0 : 1;
}
