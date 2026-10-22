/* avxtest: what a game's AVX check sees under Wine + Rosetta.
 * Reads cpuid (OSXSAVE, AVX, AVX2), then, like a real AVX check, executes
 * XGETBV(0) if OSXSAVE is set (or always with "avxtest force") and, if xcr0
 * says the YMM state is enabled, one 256-bit AVX add.
 * Rosetta only advertises AVX with ROSETTA_ADVERTISE_AVX=1; where Rosetta lacks
 * XGETBV, Wine emulates it (src/patches/ntdll-emulate-xgetbv.patch).
 * An illegal instruction is caught by a vectored handler and reported.
 * Exit code 0 = checks done, 3 = illegal instruction.
 */
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include <cpuid.h>

static const char *step = "start";

static LONG CALLBACK on_exception(EXCEPTION_POINTERS *ep)
{
    DWORD code = ep->ExceptionRecord->ExceptionCode;
    if (code != EXCEPTION_ILLEGAL_INSTRUCTION && code != EXCEPTION_PRIV_INSTRUCTION) return EXCEPTION_CONTINUE_SEARCH;
    printf("%s: exception 0x%08lx (%s) at %p\n", step, code,
           code == EXCEPTION_ILLEGAL_INSTRUCTION ? "EXCEPTION_ILLEGAL_INSTRUCTION" : "EXCEPTION_PRIV_INSTRUCTION",
           ep->ExceptionRecord->ExceptionAddress);
    fflush(stdout);
    ExitProcess(3);
    return EXCEPTION_CONTINUE_SEARCH;
}

__attribute__((target("avx")))
static float avx_add(void)
{
    float a[8] = { 1, 2, 3, 4, 5, 6, 7, 8 }, out[8];
    __asm__ volatile("vmovups %1, %%ymm0\n\t"
                     "vaddps %%ymm0, %%ymm0, %%ymm0\n\t"
                     "vmovups %%ymm0, %0\n\t"
                     "vzeroupper"
                     : "=m"(out) : "m"(a) : "xmm0");
    return out[7];
}

int main(int argc, char **argv)
{
    unsigned int a, b, c, d, lo, hi;
    int force = argc > 1 && !strcmp(argv[1], "force");
    int osxsave, avx;

    AddVectoredExceptionHandler(1, on_exception);
    __cpuid(1, a, b, c, d);
    osxsave = !!(c & (1u << 27));
    avx = !!(c & (1u << 28));
    printf("cpuid 1: ecx=%08x XSAVE=%d OSXSAVE=%d AVX=%d\n", c, !!(c & (1u << 26)), osxsave, avx);
    __cpuid_count(7, 0, a, b, c, d);
    printf("cpuid 7: ebx=%08x AVX2=%d AVX512F=%d\n", b, !!(b & (1u << 5)), !!(b & (1u << 16)));

    if (!osxsave && !force)
    {
        printf("no OSXSAVE: a game would not execute xgetbv (run \"avxtest force\" to do it anyway)\n");
        return 0;
    }
    step = "xgetbv";
    fflush(stdout);
    __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    printf("xgetbv(0) = 0x%08x%08x (x87=%u SSE=%u AVX/YMM=%u AVX-512=%u)\n", hi, lo,
           lo & 1, (lo >> 1) & 1, (lo >> 2) & 1, (lo & 0xe0) == 0xe0);

    if (avx && (lo & 6) == 6)
    {
        step = "vaddps ymm";
        fflush(stdout);
        printf("AVX vaddps ymm: 8 + 8 = %.0f\n", avx_add());
    }
    else printf("AVX not usable (cpuid AVX=%d, xcr0 YMM|SSE=%u): a game falls back to SSE\n", avx, (lo & 6) == 6);
    return 0;
}
