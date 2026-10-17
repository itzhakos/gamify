/* Minimal DXGI + D3D12 smoke test: create a device, a command queue, a flip-model
 * swap chain on a window, and clear + present N frames with a fence per frame.
 * Prints the adapter and the max feature level / shader model D3DMetal reports.
 * Build: make -C src/d3dtest  (x86_64-w64-mingw32-gcc) */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <d3d12.h>
#include <dxgi1_4.h>

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(h, m, w, l);
}

#define CHECK(what, expr) do { HRESULT hr_ = (expr); if (FAILED(hr_)) { \
    printf("%s failed: 0x%08lx\n", what, hr_); fflush(stdout); return 1; } } while (0)

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 120;
    WNDCLASSW wc = { 0 };
    wc.lpfnWndProc = wndproc; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"d3d12test";
    RegisterClassW(&wc);
    HWND hwnd = CreateWindowW(L"d3d12test", L"d3d12test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                              100, 100, 640, 480, NULL, NULL, wc.hInstance, NULL);

    IDXGIFactory4 *factory;
    CHECK("CreateDXGIFactory1", CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory));
    IDXGIAdapter1 *adapter; DXGI_ADAPTER_DESC1 ad;
    CHECK("EnumAdapters1", IDXGIFactory4_EnumAdapters1(factory, 0, &adapter));
    IDXGIAdapter1_GetDesc1(adapter, &ad);
    printf("adapter: %ls (vendor 0x%04x device 0x%04x)\n", ad.Description, ad.VendorId, ad.DeviceId);

    ID3D12Device *dev;
    CHECK("D3D12CreateDevice", D3D12CreateDevice((IUnknown *)adapter, D3D_FEATURE_LEVEL_11_0,
                                                 &IID_ID3D12Device, (void **)&dev));
    D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_12_0,
                                   D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_2 };
    D3D12_FEATURE_DATA_FEATURE_LEVELS fl = { ARRAYSIZE(levels), levels, 0 };
    ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_FEATURE_LEVELS, &fl, sizeof(fl));
    D3D12_FEATURE_DATA_SHADER_MODEL sm = { D3D_SHADER_MODEL_6_6 };
    ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_SHADER_MODEL, &sm, sizeof(sm));
    printf("D3D12CreateDevice: ok, max feature level 0x%x, shader model 0x%x\n",
           fl.MaxSupportedFeatureLevel, sm.HighestShaderModel);
    fflush(stdout);

    D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT };
    ID3D12CommandQueue *queue;
    CHECK("CreateCommandQueue", ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&queue));

    DXGI_SWAP_CHAIN_DESC1 sd = { 0 };
    sd.Width = 640; sd.Height = 480; sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount = 2; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain1 *sc1; IDXGISwapChain3 *sc;
    CHECK("CreateSwapChainForHwnd", IDXGIFactory4_CreateSwapChainForHwnd(factory, (IUnknown *)queue, hwnd, &sd,
                                                                         NULL, NULL, &sc1));
    CHECK("QueryInterface(IDXGISwapChain3)", IDXGISwapChain1_QueryInterface(sc1, &IID_IDXGISwapChain3, (void **)&sc));

    D3D12_DESCRIPTOR_HEAP_DESC hd = { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 2 };
    ID3D12DescriptorHeap *heap;
    CHECK("CreateDescriptorHeap", ID3D12Device_CreateDescriptorHeap(dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&heap));
    UINT inc = ID3D12Device_GetDescriptorHandleIncrementSize(dev, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_CPU_DESCRIPTOR_HANDLE rtv[2]; ID3D12Resource *bb[2];
    /* mingw's C binding returns the struct through a hidden out parameter */
    heap->lpVtbl->GetCPUDescriptorHandleForHeapStart(heap, &rtv[0]);
    rtv[1].ptr = rtv[0].ptr + inc;
    for (int i = 0; i < 2; i++) {
        CHECK("GetBuffer", IDXGISwapChain3_GetBuffer(sc, i, &IID_ID3D12Resource, (void **)&bb[i]));
        ID3D12Device_CreateRenderTargetView(dev, bb[i], NULL, rtv[i]);
    }

    ID3D12CommandAllocator *alloc; ID3D12GraphicsCommandList *list; ID3D12Fence *fence;
    CHECK("CreateCommandAllocator", ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                                                       &IID_ID3D12CommandAllocator, (void **)&alloc));
    CHECK("CreateCommandList", ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL,
                                                             &IID_ID3D12GraphicsCommandList, (void **)&list));
    ID3D12GraphicsCommandList_Close(list);
    CHECK("CreateFence", ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence));
    HANDLE ev = CreateEventW(NULL, FALSE, FALSE, NULL);
    UINT64 fv = 0;

    DWORD t0 = GetTickCount();
    for (int f = 0; f < frames; f++) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        UINT i = IDXGISwapChain3_GetCurrentBackBufferIndex(sc);
        ID3D12CommandAllocator_Reset(alloc);
        ID3D12GraphicsCommandList_Reset(list, alloc, NULL);
        D3D12_RESOURCE_BARRIER b = { D3D12_RESOURCE_BARRIER_TYPE_TRANSITION };
        b.Transition.pResource = bb[i]; b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        b.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT; b.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
        ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
        float c[4] = { 0.4f + 0.4f * (f % 60) / 60.0f, 0.1f, 0.3f, 1.0f };
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv[i], c, 0, NULL);
        b.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET; b.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
        ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
        ID3D12GraphicsCommandList_Close(list);
        ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);
        HRESULT hr = IDXGISwapChain3_Present(sc, 1, 0);
        if (FAILED(hr)) { printf("Present failed 0x%08lx at frame %d\n", hr, f); return 3; }
        ID3D12CommandQueue_Signal(queue, fence, ++fv);
        if (ID3D12Fence_GetCompletedValue(fence) < fv) {
            ID3D12Fence_SetEventOnCompletion(fence, fv, ev);
            WaitForSingleObject(ev, INFINITE);
        }
    }
    DWORD dt = GetTickCount() - t0;
    printf("presented %d frames in %lu ms (%.1f fps)\n", frames, dt, dt ? 1000.0 * frames / dt : 0.0);
    fflush(stdout);
    return 0;
}
