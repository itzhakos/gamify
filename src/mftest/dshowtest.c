/* dshowtest: play a media file through DirectShow (quartz -> winegstreamer
 * under Wine), the path many games use for cutscenes. Opens the default video
 * window, plays to the end (or a timeout) and reports how it went.
 *
 *   wine dshowtest.exe <file> [timeout_ms]
 *
 * Exit code 0 = graph built and playback reached EC_COMPLETE.
 */
#define COBJMACROS
#include <stdio.h>
#include <windows.h>
#include <dshow.h>

int wmain(int argc, WCHAR **argv)
{
    IGraphBuilder *graph;
    IMediaControl *control;
    IMediaEvent *event;
    IMediaSeeking *seeking;
    IBasicVideo *video;
    LONGLONG duration = 0;
    LONG code = 0, w = 0, h = 0;
    DWORD start, timeout = argc > 2 ? _wtoi(argv[2]) : 15000;
    HRESULT hr;

    if (argc < 2) { fprintf(stderr, "usage: dshowtest <file> [timeout_ms]\n"); return 2; }
    CoInitialize(NULL);
    hr = CoCreateInstance(&CLSID_FilterGraph, NULL, CLSCTX_INPROC_SERVER, &IID_IGraphBuilder, (void **)&graph);
    if (FAILED(hr)) { printf("FilterGraph 0x%08lx\n", hr); return 3; }

    hr = IGraphBuilder_RenderFile(graph, argv[1], NULL);
    printf("RenderFile: 0x%08lx\n", hr);
    if (FAILED(hr)) return 4;

    IGraphBuilder_QueryInterface(graph, &IID_IMediaControl, (void **)&control);
    IGraphBuilder_QueryInterface(graph, &IID_IMediaEvent, (void **)&event);
    if (SUCCEEDED(IGraphBuilder_QueryInterface(graph, &IID_IMediaSeeking, (void **)&seeking))) {
        IMediaSeeking_GetDuration(seeking, &duration);
        IMediaSeeking_Release(seeking);
    }
    if (SUCCEEDED(IGraphBuilder_QueryInterface(graph, &IID_IBasicVideo, (void **)&video))) {
        IBasicVideo_GetVideoSize(video, &w, &h);
        IBasicVideo_Release(video);
    }
    printf("duration %.2f s, video %ldx%ld\n", duration / 1e7, w, h);

    start = GetTickCount();
    hr = IMediaControl_Run(control);
    printf("Run: 0x%08lx\n", hr);
    hr = IMediaEvent_WaitForCompletion(event, timeout, &code);
    printf("WaitForCompletion: 0x%08lx, event code %ld (1 = EC_COMPLETE), %.2f s wall\n",
           hr, code, (GetTickCount() - start) / 1000.0);

    IMediaControl_Stop(control);
    IMediaControl_Release(control);
    IMediaEvent_Release(event);
    IGraphBuilder_Release(graph);
    CoUninitialize();
    return (hr == S_OK && code == EC_COMPLETE) ? 0 : 1;
}
