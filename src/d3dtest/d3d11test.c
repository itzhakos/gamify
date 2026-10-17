/* Minimal DXGI + D3D11 smoke test: enumerate adapters, create a device and a
 * swap chain on a window, clear it for N frames. Prints the adapter description
 * so we can tell wined3d, D3DMetal 2.1 and D3DMetal 3.0 apart.
 * Build: make -C src/d3dtest  (x86_64-w64-mingw32-gcc) */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <d3d11.h>
#include <dxgi.h>

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(h, m, w, l);
}

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 120;
    WNDCLASSW wc = { 0 };
    wc.lpfnWndProc = wndproc; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"d3d11test";
    RegisterClassW(&wc);
    HWND hwnd = CreateWindowW(L"d3d11test", L"d3d11test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                              100, 100, 640, 480, NULL, NULL, wc.hInstance, NULL);

    IDXGIFactory1 *factory = NULL;
    HRESULT hr = CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory);
    printf("CreateDXGIFactory1: 0x%08lx\n", hr); fflush(stdout);
    if (FAILED(hr)) return 1;
    for (UINT i = 0;; i++) {
        IDXGIAdapter1 *a; DXGI_ADAPTER_DESC1 d;
        if (IDXGIFactory1_EnumAdapters1(factory, i, &a) != S_OK) break;
        IDXGIAdapter1_GetDesc1(a, &d);
        printf("adapter %u: %ls (vendor 0x%04x device 0x%04x vram %llu MB)\n", i, d.Description,
               d.VendorId, d.DeviceId, (unsigned long long)d.DedicatedVideoMemory >> 20);
        IDXGIAdapter1_Release(a);
    }
    fflush(stdout);

    DXGI_SWAP_CHAIN_DESC sd = { 0 };
    sd.BufferCount = 2; sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1; sd.Windowed = TRUE; sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    ID3D11Device *dev; ID3D11DeviceContext *ctx; IDXGISwapChain *sc; D3D_FEATURE_LEVEL fl;
    hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                       D3D11_SDK_VERSION, &sd, &sc, &dev, &fl, &ctx);
    printf("D3D11CreateDeviceAndSwapChain: 0x%08lx feature level 0x%x\n", hr, fl); fflush(stdout);
    if (FAILED(hr)) return 2;

    ID3D11Texture2D *bb; ID3D11RenderTargetView *rtv;
    IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb);
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv);
    DWORD t0 = GetTickCount();
    for (int f = 0; f < frames; f++) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        float c[4] = { 0.1f, 0.4f + 0.4f * (f % 60) / 60.0f, 0.2f, 1.0f };
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, c);
        hr = IDXGISwapChain_Present(sc, 1, 0);
        if (FAILED(hr)) { printf("Present failed 0x%08lx at frame %d\n", hr, f); return 3; }
    }
    DWORD dt = GetTickCount() - t0;
    printf("presented %d frames in %lu ms (%.1f fps)\n", frames, dt, dt ? 1000.0 * frames / dt : 0.0);
    fflush(stdout);
    return 0;
}
