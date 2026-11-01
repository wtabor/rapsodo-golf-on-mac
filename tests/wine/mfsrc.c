// Print what Wine's MP4 media source itself delivers (before any decoder):
// stream media types, then sample times and decode timestamps of the first samples.
// With an edit list (B-frame MP4s), the first sample time should be 0; Wine's default
// GStreamer reader ignores the edit list, its FFmpeg one (DisableGstByteStreamHandler=1)
// doesn't. Last line: "summary: samples N first_time T" (100 ns).
// Usage: mfsrc.exe <file.mp4>
#define COBJMACROS
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <stdio.h>

int wmain(int argc, wchar_t **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 2) { printf("usage: mfsrc <file>\n"); return 2; }
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION, MFSTARTUP_FULL);
    IMFSourceResolver *res = NULL;
    MFCreateSourceResolver(&res);
    MF_OBJECT_TYPE ot;
    IUnknown *unk = NULL;
    HRESULT hr = IMFSourceResolver_CreateObjectFromURL(res, argv[1], MF_RESOLUTION_MEDIASOURCE, NULL, &ot, &unk);
    printf("CreateObjectFromURL 0x%08lx\n", hr);
    if (FAILED(hr)) return 1;
    IMFMediaSource *src = NULL;
    IUnknown_QueryInterface(unk, &IID_IMFMediaSource, (void **)&src);
    IMFPresentationDescriptor *pd = NULL;
    IMFMediaSource_CreatePresentationDescriptor(src, &pd);
    DWORD n = 0;
    IMFPresentationDescriptor_GetStreamDescriptorCount(pd, &n);
    for (DWORD i = 0; i < n; i++) {
        BOOL sel; IMFStreamDescriptor *sd; IMFMediaTypeHandler *th; DWORD nt = 0;
        IMFPresentationDescriptor_GetStreamDescriptorByIndex(pd, i, &sel, &sd);
        IMFStreamDescriptor_GetMediaTypeHandler(sd, &th);
        IMFMediaTypeHandler_GetMediaTypeCount(th, &nt);
        for (DWORD t = 0; t < nt; t++) {
            IMFMediaType *mt; GUID g;
            IMFMediaTypeHandler_GetMediaTypeByIndex(th, t, &mt);
            IMFMediaType_GetGUID(mt, &MF_MT_SUBTYPE, &g);
            printf("stream %lu type %lu: subtype %08lx (%.4s)\n", i, t, g.Data1, (char *)&g.Data1);
        }
    }
    PROPVARIANT start; PropVariantInit(&start);
    IMFMediaEventGenerator *gen = (IMFMediaEventGenerator *)src;
    hr = IMFMediaSource_Start(src, pd, NULL, &start);
    printf("Start 0x%08lx\n", hr);
    IMFMediaStream *stream = NULL;
    int got = 0;
    LONGLONG first = -1;
    while (got < 8) {
        IMFMediaEvent *ev = NULL;
        if (!stream) {
            if (FAILED(IMFMediaEventGenerator_GetEvent(gen, 0, &ev))) break;
            MediaEventType type; IMFMediaEvent_GetType(ev, &type);
            if (type == MENewStream) {
                PROPVARIANT v; PropVariantInit(&v);
                IMFMediaEvent_GetValue(ev, &v);
                IUnknown_QueryInterface(v.punkVal, &IID_IMFMediaStream, (void **)&stream);
                for (int k = 0; k < 8; k++) IMFMediaStream_RequestSample(stream, NULL);
            }
            continue;
        }
        if (FAILED(IMFMediaEventGenerator_GetEvent((IMFMediaEventGenerator *)stream, 0, &ev))) break;
        MediaEventType type; IMFMediaEvent_GetType(ev, &type);
        if (type != MEMediaSample) continue;
        PROPVARIANT v; PropVariantInit(&v);
        IMFMediaEvent_GetValue(ev, &v);
        IMFSample *s = NULL;
        IUnknown_QueryInterface(v.punkVal, &IID_IMFSample, (void **)&s);
        LONGLONG t = 0; UINT64 dts = 0;
        IMFSample_GetSampleTime(s, &t);
        HRESULT hd = IMFSample_GetUINT64(s, &MFSampleExtension_DecodeTimestamp, &dts);
        if (first < 0) first = t;
        printf("sample %d: time %lld, decode timestamp %s%lld\n", got++, t, SUCCEEDED(hd) ? "" : "(none) ", (LONGLONG)dts);
    }
    printf("summary: samples %d first_time %lld\n", got, first);
    return got > 0 ? 0 : 1;
}
