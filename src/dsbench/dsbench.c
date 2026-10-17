/* dsbench: measure what Wine's DirectSound mixer costs.
 * Plays N looping 16-bit stereo secondary buffers (default 1 at 44100 Hz, like Source
 * engine games) for T seconds, then prints the CPU time of every thread in the process.
 * Wine's mixer is the thread that did not exist before DirectSoundCreate8.
 * usage: dsbench.exe [seconds=10] [buffers=1] [rate=44100] */
#include <windows.h>
#include <mmsystem.h>
#include <dsound.h>
#include <tlhelp32.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static double ft_sec(FILETIME f) { return (((ULONGLONG)f.dwHighDateTime << 32) | f.dwLowDateTime) / 1e7; }

static double thread_cpu(DWORD tid)
{
    FILETIME c, e, k, u;
    HANDLE h = OpenThread(THREAD_QUERY_INFORMATION, FALSE, tid);
    double r = -1;
    if (h && GetThreadTimes(h, &c, &e, &k, &u)) r = ft_sec(k) + ft_sec(u);
    if (h) CloseHandle(h);
    return r;
}

#define MAXT 256
static DWORD tids[MAXT]; static double t0[MAXT]; static int nt;

static void snapshot(void)
{
    THREADENTRY32 te = { sizeof(te) };
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    nt = 0;
    if (Thread32First(s, &te)) do {
        if (te.th32OwnerProcessID == GetCurrentProcessId() && nt < MAXT) {
            tids[nt] = te.th32ThreadID; t0[nt] = thread_cpu(te.th32ThreadID); nt++;
        }
    } while (Thread32Next(s, &te));
    CloseHandle(s);
}

int main(int argc, char **argv)
{
    int secs = argc > 1 ? atoi(argv[1]) : 10, nbuf = argc > 2 ? atoi(argv[2]) : 1;
    int rate = argc > 3 ? atoi(argv[3]) : 44100, i, j;
    WAVEFORMATEX wf = { WAVE_FORMAT_PCM, 2, rate, rate * 4, 4, 16, 0 };
    DSBUFFERDESC pd = { sizeof(pd), DSBCAPS_PRIMARYBUFFER }, bd = { sizeof(bd) };
    IDirectSound8 *ds; IDirectSoundBuffer *prim, *buf[64];
    HWND hwnd = CreateWindowA("STATIC", "dsbench", 0, 0, 0, 1, 1, NULL, NULL, NULL, NULL);
    FILETIME c, e, k0, u0, k1, u1;
    DWORD wall;

    if (nbuf > 64) nbuf = 64;
    if (FAILED(DirectSoundCreate8(NULL, &ds, NULL))) { puts("DirectSoundCreate8 failed"); return 1; }
    IDirectSound8_SetCooperativeLevel(ds, hwnd, DSSCL_PRIORITY);
    if (SUCCEEDED(IDirectSound8_CreateSoundBuffer(ds, &pd, &prim, NULL)))
        IDirectSoundBuffer_SetFormat(prim, &wf);

    bd.dwFlags = DSBCAPS_GETCURRENTPOSITION2 | DSBCAPS_GLOBALFOCUS | DSBCAPS_LOCSOFTWARE;
    bd.dwBufferBytes = rate * 4 / 2;   /* 0.5 s, like Source's DirectSound buffer */
    bd.lpwfxFormat = &wf;
    for (i = 0; i < nbuf; i++) {
        void *p; DWORD n; short *s;
        if (FAILED(IDirectSound8_CreateSoundBuffer(ds, &bd, &buf[i], NULL))) { puts("CreateSoundBuffer failed"); return 1; }
        IDirectSoundBuffer_Lock(buf[i], 0, 0, &p, &n, NULL, NULL, DSBLOCK_ENTIREBUFFER);
        for (s = p, j = 0; j < (int)n / 4; j++)   /* silent: the mixer does the same work for zeros */
            s[2 * j] = s[2 * j + 1] = 0;
        IDirectSoundBuffer_Unlock(buf[i], p, n, NULL, 0);
    }
    for (i = 0; i < nbuf; i++) IDirectSoundBuffer_Play(buf[i], 0, 0, DSBPLAY_LOOPING);

    Sleep(500);                        /* let the mixer settle */
    snapshot();
    GetProcessTimes(GetCurrentProcess(), &c, &e, &k0, &u0);
    wall = GetTickCount();
    Sleep(secs * 1000);
    GetProcessTimes(GetCurrentProcess(), &c, &e, &k1, &u1);
    wall = GetTickCount() - wall;

    printf("buffers=%d rate=%d wall=%.2fs process_cpu=%.1f%%\n", nbuf, rate, wall / 1000.0,
           100.0 * (ft_sec(k1) + ft_sec(u1) - ft_sec(k0) - ft_sec(u0)) / (wall / 1000.0));
    for (i = 0; i < nt; i++) {
        double d = thread_cpu(tids[i]) - t0[i];
        if (d > 0.005) printf("  thread %04lx cpu=%.1f%%\n", tids[i], 100.0 * d / (wall / 1000.0));
    }
    for (i = 0; i < nbuf; i++) IDirectSoundBuffer_Release(buf[i]);
    IDirectSound8_Release(ds);
    return 0;
}
