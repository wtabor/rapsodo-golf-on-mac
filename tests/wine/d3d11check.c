// D3D11 for the Unity games goes through DXVK-macOS (Fix 3, 45-install-dxvk.sh):
// Wine's own wined3d can't create a D3D11 device on macOS. Run with
// WINEDLLOVERRIDES="d3d11,d3d10core=n,b" (the per-game overrides 45 sets don't
// cover this exe). Checks: d3d11.dll is DXVK (not Wine's builtin), a hardware
// device with the flags Unity's video player uses reaches feature level 11_0, a
// BGRA texture survives an upload and readback, and an NV12 texture can be made.
// Informational: shared textures (DXVK-macOS can't share them; that's why
// patch_unity_video.py exists).
// Usage: d3d11check.exe   Exit status 0 when every check passed.
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <string.h>

static int failures;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) failures++;
}

// Wine marks its builtin PE modules with "Wine builtin DLL" after the DOS header.
static int is_wine_builtin(HMODULE mod) {
    const char *base = (const char *)mod;
    return mod && !memcmp(base + 0x40, "Wine builtin DLL", 16);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL,
                                   D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                                   NULL, 0, D3D11_SDK_VERSION, &dev, &fl, &ctx);
    HMODULE d3d11 = GetModuleHandleA("d3d11.dll");
    char path[MAX_PATH] = "";
    GetModuleFileNameA(d3d11, path, sizeof path);
    printf("d3d11.dll: %s (%s)\n", path, is_wine_builtin(d3d11) ? "Wine builtin" : "native");
    check(d3d11 && !is_wine_builtin(d3d11), "d3d11.dll is DXVK, not Wine's builtin");
    printf("D3D11CreateDevice: 0x%08lx, feature level 0x%x\n", hr, fl);
    check(SUCCEEDED(hr) && dev, "hardware D3D11 device (BGRA + video support)");
    if (FAILED(hr) || !dev) return 1;
    check(fl >= D3D_FEATURE_LEVEL_11_0, "feature level 11_0 or higher");

    IDXGIDevice *dxgi = NULL;
    IDXGIAdapter *adapter = NULL;
    if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgi)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgi, &adapter))) {
        DXGI_ADAPTER_DESC d;
        if (SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &d)))
            printf("adapter: %ls, %llu MB video memory\n", d.Description, (unsigned long long)(d.DedicatedVideoMemory >> 20));
    }

    // Upload a known pattern, copy it to a staging texture, read it back.
    enum { W = 64, H = 64 };
    static DWORD px[W * H];
    for (int i = 0; i < W * H; i++) px[i] = 0xff000000u | (DWORD)(i * 2654435761u >> 8);
    D3D11_TEXTURE2D_DESC td = {W, H, 1, 1, DXGI_FORMAT_B8G8R8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT,
                               D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET, 0, 0};
    D3D11_SUBRESOURCE_DATA init = {px, W * 4, 0};
    ID3D11Texture2D *tex = NULL, *staging = NULL;
    hr = ID3D11Device_CreateTexture2D(dev, &td, &init, &tex);
    D3D11_TEXTURE2D_DESC sd = td;
    sd.Usage = D3D11_USAGE_STAGING;
    sd.BindFlags = 0;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateTexture2D(dev, &sd, NULL, &staging);
    int same = 0;
    if (SUCCEEDED(hr)) {
        ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)tex);
        D3D11_MAPPED_SUBRESOURCE m;
        hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &m);
        if (SUCCEEDED(hr)) {
            same = 1;
            for (int y = 0; y < H && same; y++)
                same = !memcmp((const BYTE *)m.pData + (size_t)y * m.RowPitch, px + y * W, W * 4);
            ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
        }
    }
    printf("BGRA upload/readback: 0x%08lx\n", hr);
    check(SUCCEEDED(hr) && same, "BGRA texture reads back what was uploaded");

    D3D11_TEXTURE2D_DESC nd = {480, 640, 1, 1, DXGI_FORMAT_NV12, {1, 0}, D3D11_USAGE_DEFAULT, D3D11_BIND_SHADER_RESOURCE, 0, 0};
    ID3D11Texture2D *nv12 = NULL;
    hr = ID3D11Device_CreateTexture2D(dev, &nd, NULL, &nv12);
    printf("NV12 480x640 texture: 0x%08lx\n", hr);
    check(SUCCEEDED(hr), "NV12 texture (video frame format)");

    // What Unity's D3D11 video path needs and DXVK-macOS lacks; reported, not checked.
    td.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    ID3D11Texture2D *shared = NULL;
    HANDLE handle = NULL;
    hr = ID3D11Device_CreateTexture2D(dev, &td, NULL, &shared);
    if (SUCCEEDED(hr)) {
        IDXGIResource *res = NULL;
        if (SUCCEEDED(ID3D11Texture2D_QueryInterface(shared, &IID_IDXGIResource, (void **)&res)))
            hr = IDXGIResource_GetSharedHandle(res, &handle);
    }
    printf("info: shared texture handle: 0x%08lx (%s)\n", hr,
           SUCCEEDED(hr) && handle ? "sharing works: patch_unity_video.py may no longer be needed"
                                   : "no sharing, as expected for DXVK-macOS");
    printf("%s\n", failures ? "d3d11check: FAILED" : "d3d11check: all checks passed");
    return failures ? 1 : 0;
}
