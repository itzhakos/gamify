# Portal 2 audio ticks: x87 DirectSound resampler under Rosetta (2026-10-17)

Symptom: in bottle `steamtest` (runtime winecx-full, Steam), Portal 2 (AppID 620, 32-bit Source
engine) plays dialogue and music, but with small, irregular ticks/crackles during play.

## Audio path (measured, not assumed)
`sample <pid> 2` on the running `portal2.exe` (pid 30290, ~294% CPU) shows the threads:
- `wine_dsound_mixer`: Wine's DirectSound mixer (dlls/dsound/mixer.c `DSOUND_mixthread`)
- `audio_client_timer` + `com.apple.audio.IOThread.client`: mmdevapi -> winecoreaudio.drv -> CoreAudio
- `wine_mmdevapi_notification`
So Source uses **DirectSound -> mmdevapi -> winecoreaudio**. No XAudio2.

No thread is blocked in `CoreAudio_request_capture_authorization` any more (the microphone
permission is answered).

Output device: Steinberg UR22C, **48000 Hz** (`system_profiler SPAudioDataType`). Source plays
its mix at **44100 Hz**. Wine's dsound mixes at the device mix format (primary.c
`DSOUND_WaveFormat` uses `GetMixFormat` unless the app has DSSCL_WRITEPRIMARY) and winecoreaudio
always reports the device's nominal rate (coreaudio.c, `kAudioDevicePropertyNominalSampleRate`).
So every 44.1 kHz buffer goes through `cp_fields_resample`: a windowed-sinc FIR
(fir.h: `fir_len` 7907, `fir_step` 120, i.e. ~66 taps, plus re-interpolating the 66
coefficients for each output sample, per channel).

## Root cause
In the sample, the `wine_dsound_mixer` thread was in user code in 203 of 208 samples (98%), with
return addresses in `DSOUND_mixthread` (image at 0x6f930000, SizeOfImage 0x13b000 = our i386
dsound.dll). One core spent on the mixer, which barely keeps up, so any extra load (the game uses
~3 cores under Rosetta) makes it miss a period, and you hear a tick.

Why so expensive: **our runtimes build the i386 PE DLLs with mingw gcc's default flags
(`-g -O2`, configure.ac line 849), so all float math is x87.** Rosetta 2 translates SSE to NEON
directly but has to emulate the x87 register stack, which is many times slower.

| i386 DLL (runtimes/winecx-full) | x87 ops | SSE scalar ops |
|---|---|---|
| dsound.dll | 1603 | 0 |
| xaudio2_7.dll (FAudio) | 1468 | 0 |
| wined3d.dll | 6027 | 0 |
| ucrtbase.dll / msvcrt.dll | 6364 / 3408 | 0 |
| user32.dll / gdi32.dll / ntdll.dll | 656 / 570 / 1101 | 0 |
| x86_64 dsound.dll (same build) | 0 | 352 |
| CrossOver 25.1's own i386 dsound.dll | 52 | 741 |
| our SSE build of i386 dsound.dll | 57 | 722 |

(objdump instruction counts. CrossOver's i386 PE side is SSE: they build it with a compiler/flags
that use SSE for float math, we don't. The 64-bit side is SSE by ABI, so 64-bit games are not
affected.)

## Benchmark: `src/dsbench` (32-bit, `make -C src/dsbench`)
Plays N silent looping 16-bit stereo DirectSound buffers (0.5 s, DSSCL_PRIORITY, like Source) for
10 s and prints the process CPU. Run in a scratch prefix on winecx-full (isolated wineserver),
while Portal 2 was running:

| case | x87 dsound (current) | SSE dsound |
|---|---|---|
| 1 buffer @ 44100 Hz (resampled) | **50.0%** of a core | **1.5%** |
| 4 buffers @ 44100 Hz | **100.4%** (saturated: underruns) | **3.9%** |
| 1 buffer @ 48000 Hz (no resampling) | 1.6% | 0.8% |

33x less CPU for the same work. The resampling path alone is what costs; the 48 kHz case shows
that a matching sample rate also avoids it (but games pick their own rates, typically 44.1 or
22.05 kHz, so this is not a fix we can rely on).

## Experiments (one at a time)
1. **Registry knobs**: the dsound in this Wine only reads `HelBuflen`
   (`HKCU\Software\Wine\DirectSound`, also per app under AppDefaults); `SndQueueMax` and the
   other old keys are gone. winecoreaudio.drv reads no tuning keys (only the device GUID map);
   its period is fixed (`def_period` 10 ms, `min_period` 5 ms). No key selects the sample rate
   or the resampler quality. So no registry-only fix exists for the CPU cost.
2. **Device at 44.1 kHz** (Audio MIDI Setup): makes `freqAdjustNum == freqAdjustDen` and skips the
   FIR (1.6% in the benchmark). Not applied: it changes the user's interface for every app, and
   a game with 22.05 kHz sounds would still resample.
3. **SSE i386 dsound.dll** (`scripts/dsound-sse.sh`): built from the same CrossOver 25.1 source
   with `i386_CFLAGS="-g -O2 -msse2 -mfpmath=sse"`, the "Wine builtin DLL" marker blanked so the
   loader accepts it as native, installed in `bottles/steamtest/drive_c/windows/syswow64`
   (original kept as `dsound.dll.wine-x87.bak`) with
   `HKCU\Software\Wine\DllOverrides "dsound"="native,builtin"`. Benchmark above.
4. Source cvars (`snd_mixahead`, `snd_async_fullyasync`, `dsp_off`), WINEESYNC on/off and
   wined3d vs D9VK: not needed once the mixer cost was found; they only shift when the starved
   mixer misses a period. (Note: `snd_mixahead` raises latency and does not reduce the 50% cost.)

## Result (in game)
- First restart after installing: still the x87 image (mapped size 0x13b000), because a parallel
  session had pinned `AppDefaults\portal2.exe\DllOverrides "dsound"="builtin"` for its own A/B.
  The user reported the ticks gone, but that run did not have the fix, so it doesn't count.
  Pin removed with the user's OK.
- Second restart (pid 43092): mapped dsound image 0x6f930000-0x6fa69000 = 0x139000 = the SSE
  build. `sample 43092 3`: `wine_dsound_mixer` waits in `__wine_syscall_dispatcher` in 670 of 678
  samples (~1% busy), down from 203/208 (~98%) busy before. **The user confirms: clean audio, no
  ticks.**
- Persistent for the bottle: the DLL file in syswow64 (not a Wine placeholder, so `wineboot
  --update` leaves it alone) + the `DllOverrides` value in `bottles/steamtest/user.reg`.
  Reproduce on another bottle: `scripts/dsound-sse.sh install <bottle>`.
- An `AppDefaults\<game>.exe\DllOverrides "dsound"="builtin"` value overrides the global key and
  silently brings back the x87 DLL: check for it first if the ticks return. (The mouse-stutter
  session may set it temporarily for its A/B runs and has said it will remove it afterwards.)

## What Gamify should do for every game
- **Runtime (all games, the real fix)**: build the i386 PE side with SSE, i.e. add
  `i386_CFLAGS="-g -O2 -msse2 -mfpmath=sse"` to `CONFIGURE_FLAGS` in `scripts/build-winecx.sh`
  and `scripts/build-winecx-full.sh` and rebuild both runtimes. Every SSE2-less x86 CPU is
  irrelevant on a Mac (Rosetta implements SSE up to SSE4.2), and Wine already compiles i386 with
  `-mpreferred-stack-boundary=2` (configure.ac line 992), so gcc assumes only the Win32 4-byte
  stack alignment and realigns dynamically where SSE needs 16 bytes (`and $-16,%esp` in 4
  functions of the SSE dsound.dll). This also speeds up 32-bit wined3d, FAudio/XAudio2, user32
  and the CRTs. Then `scripts/dsound-sse.sh` and the bottle override are no longer needed
  (remove the override and restore `dsound.dll.wine-x87.bak`, or let wineboot recreate it).
- **Until then (per bottle)**: `scripts/dsound-sse.sh install <bottle>` for bottles that run
  32-bit DirectSound games.
- **Not per game**: nothing Portal-2-specific is needed; no Source cvars, no device sample rate.
