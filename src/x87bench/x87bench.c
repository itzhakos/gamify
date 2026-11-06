/* x87bench: the same float loop built twice for 32-bit Windows, with x87 math
 * (x87bench387.exe, -mfpmath=387, what Unity 5's Mono JIT emits) and with SSE
 * (x87benchsse.exe). Rosetta 2 emulates x87 in software, so the 387 build is the
 * one the x87sidecar (performance.x87 = sidecar) speeds up. Prints seconds and a
 * checksum (both builds must agree to a few digits).
 *   wine x87bench387.exe [million-iterations]   (default 50 = 250M float ops) */
#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

int main(int argc, char **argv)
{
    long n = (argc > 1 ? atol(argv[1]) : 50) * 1000000L, i;
    volatile double seed = 1.0000001;
    double a = seed, b = 0.0;
    LARGE_INTEGER f, t0, t1;

    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&t0);
    for (i = 0; i < n; i++)
    {
        b += a * (double)(i & 1023);   /* convert, multiply, add */
        a = a * 0.9999999 + 1e-7;      /* multiply, add */
    }
    QueryPerformanceCounter(&t1);
    printf("%s: %ld M iterations (%ld M float ops) in %.3f s, checksum %.6e\n",
           sizeof(void *) == 4 ? "i386" : "x86_64", n / 1000000L, 5 * n / 1000000L,
           (double)(t1.QuadPart - t0.QuadPart) / f.QuadPart, b);
    return 0;
}
