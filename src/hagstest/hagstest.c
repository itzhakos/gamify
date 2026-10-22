/* hagstest: does Wine report hardware-accelerated GPU scheduling (HAGS)?
 * Enumerates adapters with gdi32 D3DKMTEnumAdapters2 (falls back to
 * D3DKMTOpenAdapterFromGdiDisplayName), then asks D3DKMTQueryAdapterInfo for
 * KMTQAITYPE_WDDM_2_7_CAPS (what DLSS Frame Generation checks), plus
 * KMTQAITYPE_DRIVERVERSION and KMTQAITYPE_CHECKDRIVERUPDATESTATUS.
 * gdi32 -> win32u NtGdiDdDDI* is Wine's own code (src/patches/win32u-d3dkmt-hwsched.patch).
 * Exit code 0 = HwSchEnabled on the first adapter, 1 = not enabled, 2 = query failed.
 * The structs are declared here so the build needs no DDK headers.
 */
#include <stdio.h>
#include <windows.h>

typedef UINT D3DKMT_HANDLE;
typedef struct { D3DKMT_HANDLE hAdapter; LUID AdapterLuid; ULONG NumOfSources; BOOL bPrecisePresentRegionsPreferred; } D3DKMT_ADAPTERINFO;
typedef struct { ULONG NumAdapters; D3DKMT_ADAPTERINFO *pAdapters; } D3DKMT_ENUMADAPTERS2;
typedef struct { WCHAR DeviceName[32]; D3DKMT_HANDLE hAdapter; LUID AdapterLuid; UINT VidPnSourceId; } D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME;
typedef struct { D3DKMT_HANDLE hAdapter; } D3DKMT_CLOSEADAPTER;
typedef struct { D3DKMT_HANDLE hAdapter; int Type; void *pPrivateDriverData; UINT PrivateDriverDataSize; } D3DKMT_QUERYADAPTERINFO;
typedef union
{
    struct { UINT HwSchSupported : 1, HwSchEnabled : 1, HwSchEnabledByDefault : 1, IndependentVidPnVSyncControl : 1, Reserved : 28; };
    UINT Value;
} D3DKMT_WDDM_2_7_CAPS;

#define KMTQAITYPE_CHECKDRIVERUPDATESTATUS 11
#define KMTQAITYPE_DRIVERVERSION 13
#define KMTQAITYPE_WDDM_2_7_CAPS 70

typedef LONG (WINAPI *PFN_ENUM2)(D3DKMT_ENUMADAPTERS2 *);
typedef LONG (WINAPI *PFN_OPENGDI)(D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME *);
typedef LONG (WINAPI *PFN_CLOSE)(D3DKMT_CLOSEADAPTER *);
typedef LONG (WINAPI *PFN_QUERY)(D3DKMT_QUERYADAPTERINFO *);

static PFN_QUERY query;

static LONG query_info(D3DKMT_HANDLE adapter, int type, void *data, UINT size)
{
    D3DKMT_QUERYADAPTERINFO q = { adapter, type, data, size };
    return query(&q);
}

int main(void)
{
    HMODULE gdi32 = LoadLibraryA("gdi32.dll");
    PFN_ENUM2 enum2 = (PFN_ENUM2)GetProcAddress(gdi32, "D3DKMTEnumAdapters2");
    PFN_OPENGDI open_gdi = (PFN_OPENGDI)GetProcAddress(gdi32, "D3DKMTOpenAdapterFromGdiDisplayName");
    PFN_CLOSE close_adapter = (PFN_CLOSE)GetProcAddress(gdi32, "D3DKMTCloseAdapter");
    D3DKMT_ADAPTERINFO infos[16];
    D3DKMT_ENUMADAPTERS2 e = { 0, NULL };
    D3DKMT_HANDLE adapter = 0;
    D3DKMT_WDDM_2_7_CAPS caps;
    LONG st;
    UINT version = 0;
    BOOL update = TRUE;

    query = (PFN_QUERY)GetProcAddress(gdi32, "D3DKMTQueryAdapterInfo");
    if (!query) { printf("gdi32 has no D3DKMTQueryAdapterInfo\n"); return 2; }

    if (enum2 && !(st = enum2(&e)) && e.NumAdapters)
    {
        if (e.NumAdapters > 16) e.NumAdapters = 16;
        e.pAdapters = infos;
        st = enum2(&e);
        printf("D3DKMTEnumAdapters2: status 0x%08lx, %lu adapter(s)\n", st, e.NumAdapters);
        if (!st && e.NumAdapters)
        {
            adapter = infos[0].hAdapter;
            printf("adapter 0: handle 0x%x, LUID %08lx:%08lx, sources %lu\n", adapter,
                   infos[0].AdapterLuid.HighPart, infos[0].AdapterLuid.LowPart, infos[0].NumOfSources);
        }
    }
    else printf("D3DKMTEnumAdapters2: %s\n", enum2 ? "no adapters" : "missing");

    if (!adapter && open_gdi)
    {
        D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME o = { L"\\\\.\\DISPLAY1" };
        st = open_gdi(&o);
        printf("D3DKMTOpenAdapterFromGdiDisplayName: status 0x%08lx, handle 0x%x\n", st, o.hAdapter);
        if (!st) adapter = o.hAdapter;
    }
    if (!adapter) { printf("no adapter handle\n"); return 2; }

    st = query_info(adapter, KMTQAITYPE_DRIVERVERSION, &version, sizeof(version));
    printf("KMTQAITYPE_DRIVERVERSION: status 0x%08lx, version %u\n", st, st ? 0 : version);
    st = query_info(adapter, KMTQAITYPE_CHECKDRIVERUPDATESTATUS, &update, sizeof(update));
    printf("KMTQAITYPE_CHECKDRIVERUPDATESTATUS: status 0x%08lx, value %d\n", st, st ? -1 : update);

    caps.Value = 0;
    st = query_info(adapter, KMTQAITYPE_WDDM_2_7_CAPS, &caps, sizeof(caps));
    if (st) printf("KMTQAITYPE_WDDM_2_7_CAPS: status 0x%08lx%s\n", st,
                   st == (LONG)0xc0000002 ? " (STATUS_NOT_IMPLEMENTED)" : "");
    else printf("KMTQAITYPE_WDDM_2_7_CAPS: status 0, HwSchSupported=%u HwSchEnabled=%u HwSchEnabledByDefault=%u\n",
                caps.HwSchSupported, caps.HwSchEnabled, caps.HwSchEnabledByDefault);

    if (close_adapter) { D3DKMT_CLOSEADAPTER c = { adapter }; close_adapter(&c); }
    if (st) return 2;
    return caps.HwSchEnabled ? 0 : 1;
}
