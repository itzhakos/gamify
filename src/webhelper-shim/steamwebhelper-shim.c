/*
 * steamwebhelper-shim: replaces Steam's steamwebhelper.exe and re-launches the
 * real binary (renamed steamwebhelper_real.exe) with extra Chromium flags.
 *
 * Why: under Wine on macOS, Steam's CEF paints its windows black and its
 * out-of-process NetworkService fails on Wine's winsock. Forcing
 * --disable-gpu --single-process keeps rendering on the CPU and all CEF
 * services inside one process, which is enough for Steam's 2D UI.
 *
 * Build (mingw-w64):
 *   x86_64-w64-mingw32-gcc -municode -O2 -Wall -static -mwindows \
 *     -o steamwebhelper.exe steamwebhelper-shim.c
 */
#ifndef UNICODE
#define UNICODE
#endif
#include <windows.h>
#include <wchar.h>
#include <stdlib.h>

#define REAL_NAME   L"steamwebhelper_real.exe"
#define EXTRA_FLAGS L"--disable-gpu --single-process "

/* Skip the first token (our own path) of the raw command line. */
static const wchar_t *skip_argv0(const wchar_t *cmd)
{
    if (*cmd == L'"') {
        cmd++;
        while (*cmd && *cmd != L'"') cmd++;
        if (*cmd == L'"') cmd++;
    } else {
        while (*cmd && *cmd != L' ' && *cmd != L'\t') cmd++;
    }
    while (*cmd == L' ' || *cmd == L'\t') cmd++;
    return cmd;
}

int WINAPI wWinMain(HINSTANCE hi, HINSTANCE hp, PWSTR args, int show)
{
    (void)hi; (void)hp; (void)args; (void)show;

    wchar_t self[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, self, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return 1;
    wchar_t *slash = wcsrchr(self, L'\\');
    if (!slash) return 1;
    slash[1] = L'\0';

    wchar_t real[MAX_PATH];
    if (wcslen(self) + wcslen(REAL_NAME) + 1 > MAX_PATH) return 1;
    wcscpy(real, self);
    wcscat(real, REAL_NAME);

    const wchar_t *rest = skip_argv0(GetCommandLineW());
    size_t cap = 1 + wcslen(real) + 2 + wcslen(EXTRA_FLAGS) + wcslen(rest) + 1;
    wchar_t *cmd = calloc(cap, sizeof(wchar_t));
    if (!cmd) return 1;
    wcscpy(cmd, L"\"");
    wcscat(cmd, real);
    wcscat(cmd, L"\" ");
    wcscat(cmd, EXTRA_FLAGS);
    wcscat(cmd, rest);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    if (!CreateProcessW(real, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        free(cmd);
        return (int)GetLastError();
    }
    free(cmd);
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}
