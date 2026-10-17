/* mftest: decode a media file through Media Foundation's source reader
 * (mfplat -> winegstreamer under Wine) and report what came out.
 *
 *   wine mftest.exe <file>      e.g. Z:\path\to\test.mp4
 *
 * Asks for uncompressed output (NV12 video = the H.264 decoder's own output,
 * PCM audio), so the decoders have to run: under Wine that is GStreamer
 * (decodebin -> vtdec/atdec on macOS).
 * Exit code 0 = at least one video frame and one audio sample were decoded
 * (or the file has only one of the two and that one decoded).
 */
#define COBJMACROS
#include <stdio.h>
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>

static HRESULT set_output(IMFSourceReader *r, DWORD stream, REFGUID major, REFGUID sub)
{
    IMFMediaType *t;
    HRESULT hr = MFCreateMediaType(&t);
    if (FAILED(hr)) return hr;
    IMFMediaType_SetGUID(t, &MF_MT_MAJOR_TYPE, major);
    IMFMediaType_SetGUID(t, &MF_MT_SUBTYPE, sub);
    hr = IMFSourceReader_SetCurrentMediaType(r, stream, NULL, t);
    IMFMediaType_Release(t);
    return hr;
}

int wmain(int argc, WCHAR **argv)
{
    IMFSourceReader *r = NULL;
    IMFMediaType *t;
    HRESULT hr, hr_v, hr_a;
    UINT32 w = 0, h = 0, rate = 0, ch = 0;
    UINT64 size;
    LONGLONG last_v = 0, last_a = 0;
    int nv = 0, na = 0, done_v = 0, done_a = 0;

    if (argc < 2) { fprintf(stderr, "usage: mftest <file>\n"); return 2; }
    if (FAILED(hr = CoInitializeEx(NULL, COINIT_MULTITHREADED))) return 3;
    if (FAILED(hr = MFStartup(MF_VERSION, MFSTARTUP_FULL))) { printf("MFStartup 0x%08lx\n", hr); return 3; }

    hr = MFCreateSourceReaderFromURL(argv[1], NULL, &r);
    printf("MFCreateSourceReaderFromURL: 0x%08lx\n", hr);
    if (FAILED(hr)) return 4;

    hr_v = set_output(r, MF_SOURCE_READER_FIRST_VIDEO_STREAM, &MFMediaType_Video, &MFVideoFormat_NV12);
    hr_a = set_output(r, MF_SOURCE_READER_FIRST_AUDIO_STREAM, &MFMediaType_Audio, &MFAudioFormat_PCM);
    printf("video -> NV12:  0x%08lx   audio -> PCM: 0x%08lx\n", hr_v, hr_a);
    if (FAILED(hr_v)) done_v = 1;
    if (FAILED(hr_a)) done_a = 1;

    if (SUCCEEDED(hr_v) && SUCCEEDED(IMFSourceReader_GetCurrentMediaType(r, MF_SOURCE_READER_FIRST_VIDEO_STREAM, &t))) {
        if (SUCCEEDED(IMFMediaType_GetUINT64(t, &MF_MT_FRAME_SIZE, &size))) { w = size >> 32; h = (UINT32)size; }
        IMFMediaType_Release(t);
    }
    if (SUCCEEDED(hr_a) && SUCCEEDED(IMFSourceReader_GetCurrentMediaType(r, MF_SOURCE_READER_FIRST_AUDIO_STREAM, &t))) {
        IMFMediaType_GetUINT32(t, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
        IMFMediaType_GetUINT32(t, &MF_MT_AUDIO_NUM_CHANNELS, &ch);
        IMFMediaType_Release(t);
    }
    printf("video %ux%u, audio %u Hz x %u ch\n", w, h, rate, ch);

    while (!done_v || !done_a) {
        DWORD stream = done_v ? MF_SOURCE_READER_FIRST_AUDIO_STREAM : MF_SOURCE_READER_FIRST_VIDEO_STREAM;
        DWORD idx, flags = 0;
        LONGLONG ts = 0;
        IMFSample *s = NULL;

        if (!done_v && !done_a && (nv + na) % 2) stream = MF_SOURCE_READER_FIRST_AUDIO_STREAM;
        hr = IMFSourceReader_ReadSample(r, stream, 0, &idx, &flags, &ts, &s);
        if (FAILED(hr)) {
            printf("ReadSample(%s) failed 0x%08lx\n", stream == MF_SOURCE_READER_FIRST_VIDEO_STREAM ? "video" : "audio", hr);
            if (stream == MF_SOURCE_READER_FIRST_VIDEO_STREAM) done_v = 1; else done_a = 1;
            continue;
        }
        if (s) {
            if (stream == MF_SOURCE_READER_FIRST_VIDEO_STREAM) { nv++; last_v = ts; }
            else { na++; last_a = ts; }
            IMFSample_Release(s);
        }
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
            if (stream == MF_SOURCE_READER_FIRST_VIDEO_STREAM) done_v = 1; else done_a = 1;
        }
        if (nv + na > 5000) break;
    }
    printf("decoded %d video frames (last %.2f s), %d audio samples (last %.2f s)\n",
           nv, last_v / 1e7, na, last_a / 1e7);

    IMFSourceReader_Release(r);
    MFShutdown();
    if (SUCCEEDED(hr_v) && !nv) return 1;
    if (SUCCEEDED(hr_a) && !na) return 1;
    return (nv || na) ? 0 : 1;
}
