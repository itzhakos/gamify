/* Minimal Direct3D 9 smoke test: print the adapter identifier, create a HAL device
 * on a window, then clear + draw one pre-transformed triangle (fixed function) for
 * N frames. Tells wined3d and DXVK's d3d9 apart (adapter description / driver).
 * Usage: d3d9test.exe [frames=120] [vsync=1]
 * Build: make -C src/d3d9test  (d3d9test.exe = 32-bit, d3d9test64.exe = 64-bit) */
#include <windows.h>
#include <stdio.h>
#include <d3d9.h>

struct vertex { float x, y, z, rhw; DWORD color; };

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(h, m, w, l);
}

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 120;
    int vsync = argc > 2 ? atoi(argv[2]) : 1;
    WNDCLASSW wc = { 0 };
    wc.lpfnWndProc = wndproc; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"d3d9test";
    RegisterClassW(&wc);
    HWND hwnd = CreateWindowW(L"d3d9test", L"d3d9test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                              100, 100, 640, 480, NULL, NULL, wc.hInstance, NULL);

    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    printf("Direct3DCreate9: %p (%u-bit)\n", (void *)d3d, (unsigned)sizeof(void *) * 8); fflush(stdout);
    if (!d3d) return 1;
    D3DADAPTER_IDENTIFIER9 id;
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id)))
        printf("adapter: %s (driver %s, vendor 0x%04lx device 0x%04lx)\n", id.Description, id.Driver,
               id.VendorId, id.DeviceId);
    D3DCAPS9 caps;
    if (SUCCEEDED(IDirect3D9_GetDeviceCaps(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, &caps)))
        printf("caps: VS %lu.%lu PS %lu.%lu\n", (caps.VertexShaderVersion >> 8) & 0xff,
               caps.VertexShaderVersion & 0xff, (caps.PixelShaderVersion >> 8) & 0xff,
               caps.PixelShaderVersion & 0xff);
    fflush(stdout);

    D3DPRESENT_PARAMETERS pp = { 0 };
    pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.BackBufferFormat = D3DFMT_UNKNOWN;
    pp.hDeviceWindow = hwnd;
    pp.PresentationInterval = vsync ? D3DPRESENT_INTERVAL_ONE : D3DPRESENT_INTERVAL_IMMEDIATE;
    IDirect3DDevice9 *dev = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                         D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    printf("CreateDevice: 0x%08lx\n", hr); fflush(stdout);
    if (FAILED(hr)) return 2;

    struct vertex tri[3] = {
        { 320.0f,  80.0f, 0.5f, 1.0f, 0xffff0000 },
        { 540.0f, 400.0f, 0.5f, 1.0f, 0xff00ff00 },
        { 100.0f, 400.0f, 0.5f, 1.0f, 0xff0000ff },
    };
    IDirect3DDevice9_SetFVF(dev, D3DFVF_XYZRHW | D3DFVF_DIFFUSE);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_LIGHTING, FALSE);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE);
    DWORD t0 = GetTickCount();
    for (int f = 0; f < frames; f++) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(25, 25 + (f % 60) * 3, 50), 1.0f, 0);
        IDirect3DDevice9_BeginScene(dev);
        IDirect3DDevice9_DrawPrimitiveUP(dev, D3DPT_TRIANGLELIST, 1, tri, sizeof(tri[0]));
        IDirect3DDevice9_EndScene(dev);
        hr = IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);
        if (FAILED(hr)) { printf("Present failed 0x%08lx at frame %d\n", hr, f); return 3; }
    }
    DWORD dt = GetTickCount() - t0;
    printf("presented %d frames in %lu ms (%.1f fps, vsync %d)\n", frames, dt,
           dt ? 1000.0 * frames / dt : 0.0, vsync);
    fflush(stdout);
    if (getenv("D3D9TEST_HOLD")) Sleep(atoi(getenv("D3D9TEST_HOLD")));
    IDirect3DDevice9_Release(dev);
    IDirect3D9_Release(d3d);
    return 0;
}
