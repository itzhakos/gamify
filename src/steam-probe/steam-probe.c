/*
 * steam-probe: asks the running Steam client, through steam_api64.dll, what a game
 * would be told about the signed-in account and its licences.
 *
 *   steam-probe.exe [--fix] [--dll <path to steam_api64.dll>] <appid> [<appid> ...]
 *
 * Run it from a directory holding steam_appid.txt (480, Spacewar, which every account
 * owns) or with SteamAppId=480 in the environment; Steam then treats the probe as
 * Spacewar for a moment. Output is one "key: value" line per fact, then one
 * "app <id> subscribed=<0|1> installed=<0|1> purchased=<unix time>" line per appid,
 * for `cross steam check` to parse. Exit code 0 when SteamAPI init succeeded, 2 when
 * the dll could not be loaded, 3 when init failed (Steam not running, not signed in).
 *
 * Before that it compares HKCU\Software\Valve\Steam\ActiveProcess\pid with the running
 * steam.exe: games built with older SDKs (SteamAPI_IsSteamRunning) refuse to start
 * their Steam session when that pid is not a live steam.exe. With --fix a wrong pid
 * is replaced by the steam.exe pid ("active process: fixed ...").
 *
 * Only the flat C exports are used, found by name, so any steam_api64.dll from SDK
 * 1.48 on works (the accessor versions, e.g. SteamAPI_SteamApps_v008, are looked up
 * in the export table instead of being hard-coded).
 */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned char sbool;               /* C++ bool across the ABI */
typedef unsigned long long u64;

typedef sbool (*init_fn)(void);
typedef int (*init_flat_fn)(char *err);    /* ESteamAPIInitResult, SteamErrMsg[1024] */
typedef void (*void_fn)(void);
typedef int (*user_fn)(void);
typedef void *(*accessor_fn)(void);
typedef sbool (*b_app_fn)(void *self, unsigned appid);
typedef sbool (*b_fn)(void *self);
typedef u64 (*u64_fn)(void *self);
typedef unsigned (*u32_fn)(void *self);
typedef unsigned (*u32_app_fn)(void *self, unsigned appid);
typedef void *(*client_get_fn)(void *self, int user, int pipe, const char *version);
typedef void *(*client_get_utils_fn)(void *self, int pipe, const char *version);

static HMODULE dll;

static void *sym(const char *name) { return (void *)GetProcAddress(dll, name); }

/* The newest export whose name starts with prefix, e.g. SteamAPI_SteamApps_v008. */
static void *newest_export(const char *prefix, char *found, size_t found_size)
{
    BYTE *base = (BYTE *)dll;
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if (!dir.VirtualAddress) return NULL;
    IMAGE_EXPORT_DIRECTORY *exp = (IMAGE_EXPORT_DIRECTORY *)(base + dir.VirtualAddress);
    DWORD *names = (DWORD *)(base + exp->AddressOfNames);
    const char *best = NULL;
    size_t plen = strlen(prefix);
    for (DWORD i = 0; i < exp->NumberOfNames; i++) {
        const char *name = (const char *)(base + names[i]);
        if (strncmp(name, prefix, plen) == 0 && (!best || strcmp(name, best) > 0))
            best = name;
    }
    if (!best) return NULL;
    if (found) snprintf(found, found_size, "%s", best);
    return sym(best);
}

/* The interface version string compiled into the dll ("SteamUser019"): the newest
 * NUL-terminated string in the image that starts with prefix and continues with digits. */
static const char *version_string(const char *prefix)
{
    BYTE *base = (BYTE *)dll;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_SECTION_HEADER *sec = IMAGE_FIRST_SECTION(nt);
    size_t plen = strlen(prefix);
    const char *best = NULL;
    for (int s = 0; s < nt->FileHeader.NumberOfSections; s++) {
        if (sec[s].Characteristics & IMAGE_SCN_MEM_EXECUTE) continue;
        const char *p = (const char *)(base + sec[s].VirtualAddress);
        const char *end = p + sec[s].Misc.VirtualSize;
        for (; p + plen + 3 < end; p++) {
            if ((p == (const char *)base || p[-1] == 0) && memcmp(p, prefix, plen) == 0) {
                const char *q = p + plen;
                while (q < end && *q >= '0' && *q <= '9') q++;
                if (q < end && *q == 0 && q > p + plen && (!best || strcmp(p, best) > 0)) best = p;
            }
        }
    }
    return best;
}

enum which { USER, UTILS, APPS };

/* Interface pointer: SteamAPI_SteamXxx_vNNN() (SDK >= 1.48), else the old SteamXxx()
 * export, else (old flat API, SDK 1.3x) ISteamClient::GetISteamXxx with the version
 * string the dll was built with. */
static void *interface_ptr(enum which which, char *found, size_t found_size)
{
    static const char *flat[] = { "SteamAPI_SteamUser_v", "SteamAPI_SteamUtils_v", "SteamAPI_SteamApps_v" };
    static const char *old[] = { "SteamUser", "SteamUtils", "SteamApps" };
    static const char *version[] = { "SteamUser0", "SteamUtils0", "STEAMAPPS_INTERFACE_VERSION0" };
    static const char *getter[] = { "SteamAPI_ISteamClient_GetISteamUser", "SteamAPI_ISteamClient_GetISteamUtils",
                                    "SteamAPI_ISteamClient_GetISteamApps" };
    accessor_fn fn = (accessor_fn)newest_export(flat[which], found, found_size);
    if (!fn && (fn = (accessor_fn)sym(old[which])) != NULL)
        snprintf(found, found_size, "%s", old[which]);
    if (fn) return fn();

    accessor_fn client_fn = (accessor_fn)sym("SteamClient");
    user_fn get_user = (user_fn)sym("SteamAPI_GetHSteamUser");
    user_fn get_pipe = (user_fn)sym("SteamAPI_GetHSteamPipe");
    void *get = sym(getter[which]);
    if (!client_fn || !get_user || !get_pipe || !get) return NULL;
    void *client = client_fn();
    if (!client) return NULL;
    /* Old headers pass the version from the game's own steam_*.h, so it is not always
     * in the dll: then try the known ones, newest first (Steam returns NULL for others). */
    char buf[64];
    const char *v = version_string(version[which]);
    for (int n = 30; n > 0; n--) {
        if (!v) {
            snprintf(buf, sizeof(buf), "%s%02d", version[which], n);   /* SteamUser023, ..._VERSION008 */
        }
        const char *try_v = v ? v : buf;
        void *iface = which == UTILS ? ((client_get_utils_fn)get)(client, get_pipe(), try_v)
                                     : ((client_get_fn)get)(client, get_user(), get_pipe(), try_v);
        if (iface || v) {
            if (iface) snprintf(found, found_size, "%s(%s)", getter[which], try_v);
            return iface;
        }
    }
    return NULL;
}

/* The Windows pid of the first steam.exe in this prefix, 0 when none runs. */
static DWORD steam_exe_pid(void)
{
    DWORD pid = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32 pe = { .dwSize = sizeof(pe) };
    for (BOOL more = Process32First(snap, &pe); more; more = Process32Next(snap, &pe)) {
        if (_stricmp(pe.szExeFile, "steam.exe") == 0) {
            pid = pe.th32ProcessID;
            break;
        }
    }
    CloseHandle(snap);
    return pid;
}

static void check_active_process(int fix)
{
    HKEY key;
    DWORD reg_pid = 0, size = sizeof(reg_pid);
    LONG rc = RegOpenKeyExA(HKEY_CURRENT_USER, "Software\\Valve\\Steam\\ActiveProcess", 0,
                            KEY_QUERY_VALUE | KEY_SET_VALUE, &key);
    if (rc != ERROR_SUCCESS) {
        printf("active process: no registry key\n");
        return;
    }
    RegQueryValueExA(key, "pid", NULL, NULL, (BYTE *)&reg_pid, &size);
    DWORD live = steam_exe_pid();
    if (!live) {
        printf("active process: pid=%lu, no steam.exe running\n", reg_pid);
    } else if (reg_pid == live) {
        printf("active process: pid=%lu ok\n", reg_pid);
    } else if (fix && RegSetValueExA(key, "pid", 0, REG_DWORD, (const BYTE *)&live, sizeof(live)) == ERROR_SUCCESS) {
        printf("active process: fixed pid=%lu -> %lu\n", reg_pid, live);
    } else {
        printf("active process: wrong pid=%lu, steam.exe is %lu\n", reg_pid, live);
    }
    RegCloseKey(key);
}

int main(int argc, char **argv)
{
    const char *dll_path = "steam_api64.dll";
    int fix = 0, first = 1;
    for (; first < argc && strncmp(argv[first], "--", 2) == 0; first++) {
        if (strcmp(argv[first], "--fix") == 0) fix = 1;
        else if (strcmp(argv[first], "--dll") == 0 && first + 1 < argc) dll_path = argv[++first];
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    check_active_process(fix);

    dll = LoadLibraryA(dll_path);
    if (!dll) {
        printf("error: cannot load %s (error %lu)\n", dll_path, GetLastError());
        return 2;
    }
    char module[MAX_PATH];
    GetModuleFileNameA(dll, module, sizeof(module));
    printf("dll: %s\n", module);

    char env[32];
    DWORD n = GetEnvironmentVariableA("SteamAppId", env, sizeof(env));
    printf("env SteamAppId: %s\n", n && n < sizeof(env) ? env : "(unset)");

    /* Old SDKs refuse to init when this is false: it reads
     * HKCU\Software\Valve\Steam\ActiveProcess\pid and checks that process. */
    init_fn is_running = (init_fn)sym("SteamAPI_IsSteamRunning");
    if (is_running) printf("steam running: %d\n", is_running());

    /* Init: the oldest entry point that exists, since its semantics are the plainest. */
    sbool ok = 0;
    init_fn init = (init_fn)sym("SteamAPI_Init");
    init_fn init_safe = (init_fn)sym("SteamAPI_InitSafe");
    init_flat_fn init_flat = (init_flat_fn)sym("SteamAPI_InitFlat");
    if (init) {
        printf("init via: SteamAPI_Init\n");
        ok = init();
    } else if (init_safe) {
        printf("init via: SteamAPI_InitSafe\n");
        ok = init_safe();
    } else if (init_flat) {
        char err[1024] = "";
        printf("init via: SteamAPI_InitFlat\n");
        int result = init_flat(err);
        ok = result == 0;
        if (!ok) printf("init error: %d %s\n", result, err);
    } else {
        printf("error: no SteamAPI_Init/InitSafe/InitFlat export\n");
        return 2;
    }
    printf("init: %s\n", ok ? "ok" : "failed");
    if (!ok) return 3;

    user_fn get_user = (user_fn)sym("SteamAPI_GetHSteamUser");
    if (get_user) printf("hsteamuser: %d\n", get_user());

    char name[128] = "";
    void *user = interface_ptr(USER, name, sizeof(name));
    if (user) {
        printf("user interface: %s\n", name);
        b_fn logged_on = (b_fn)sym("SteamAPI_ISteamUser_BLoggedOn");
        u64_fn steam_id = (u64_fn)sym("SteamAPI_ISteamUser_GetSteamID");
        if (logged_on) printf("logged on: %d\n", logged_on(user));
        if (steam_id) printf("steamid: %llu\n", steam_id(user));
    }

    void *utils = interface_ptr(UTILS, name, sizeof(name));
    if (utils) {
        printf("utils interface: %s\n", name);
        u32_fn app_id = (u32_fn)sym("SteamAPI_ISteamUtils_GetAppID");
        if (app_id) printf("appid: %u\n", app_id(utils));
    }

    void *apps = interface_ptr(APPS, name, sizeof(name));
    if (!apps) {
        printf("error: no ISteamApps\n");
        return 4;
    }
    printf("apps interface: %s\n", name);
    b_fn subscribed = (b_fn)sym("SteamAPI_ISteamApps_BIsSubscribed");
    b_fn free_weekend = (b_fn)sym("SteamAPI_ISteamApps_BIsSubscribedFromFreeWeekend");
    b_fn family = (b_fn)sym("SteamAPI_ISteamApps_BIsSubscribedFromFamilySharing");
    u64_fn owner = (u64_fn)sym("SteamAPI_ISteamApps_GetAppOwner");
    if (subscribed) printf("current app subscribed: %d\n", subscribed(apps));
    if (free_weekend) printf("current app free weekend: %d\n", free_weekend(apps));
    if (family) printf("current app family sharing: %d\n", family(apps));
    if (owner) printf("current app owner: %llu\n", owner(apps));

    b_app_fn is_subscribed_app = (b_app_fn)sym("SteamAPI_ISteamApps_BIsSubscribedApp");
    b_app_fn is_installed = (b_app_fn)sym("SteamAPI_ISteamApps_BIsAppInstalled");
    u32_app_fn purchased = (u32_app_fn)sym("SteamAPI_ISteamApps_GetEarliestPurchaseUnixTime");
    for (int i = first; i < argc; i++) {
        unsigned appid = (unsigned)strtoul(argv[i], NULL, 10);
        if (!appid) continue;
        printf("app %u subscribed=%d installed=%d purchased=%u\n", appid,
               is_subscribed_app ? is_subscribed_app(apps, appid) : -1,
               is_installed ? is_installed(apps, appid) : -1,
               purchased ? purchased(apps, appid) : 0);
    }

    void_fn shutdown = (void_fn)sym("SteamAPI_Shutdown");
    if (shutdown) shutdown();
    return 0;
}
