#include "native.h"
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <algorithm>
#include <thread>
#include <chrono>
using namespace nocturne;
using namespace winrt;
namespace {
WAVEFORMATEX format() {
    WAVEFORMATEX value{}; value.wFormatTag = WAVE_FORMAT_IEEE_FLOAT; value.nChannels = 2;
    value.nSamplesPerSec = 48000; value.wBitsPerSample = 32; value.nBlockAlign = 8; value.nAvgBytesPerSec = 384000; return value;
}
com_ptr<IAudioClient> default_client() {
    com_ptr<IMMDeviceEnumerator> enumerator; com_ptr<IMMDevice> device; com_ptr<IAudioClient> client;
    check_hresult(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(enumerator.put())));
    check_hresult(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, device.put()));
    check_hresult(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, client.put_void())); return client;
}
struct Activation : implements<Activation, IActivateAudioInterfaceCompletionHandler> {
    HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HRESULT result = E_PENDING;
    com_ptr<IAudioClient> client;
    ~Activation() { if (ready) CloseHandle(ready); }
    HRESULT __stdcall ActivateCompleted(IActivateAudioInterfaceAsyncOperation* operation) noexcept override {
        com_ptr<IUnknown> activated;
        auto status = operation->GetActivateResult(&result, activated.put());
        if (FAILED(status)) result = status;
        if (SUCCEEDED(result)) result = activated->QueryInterface(__uuidof(IAudioClient), client.put_void());
        SetEvent(ready); return S_OK;
    }
};
com_ptr<IAudioClient> process_client() {
    AUDIOCLIENT_ACTIVATION_PARAMS parameters{};
    parameters.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    parameters.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
    parameters.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT value{}; value.vt = VT_BLOB; value.blob.cbSize = sizeof(parameters); value.blob.pBlobData = reinterpret_cast<BYTE*>(&parameters);
    auto callback = make_self<Activation>(); com_ptr<IActivateAudioInterfaceAsyncOperation> operation;
    check_hresult(ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &value, callback.get(), operation.put()));
    require(WaitForSingleObject(callback->ready, 5000) == WAIT_OBJECT_0, L"System audio capture did not start.");
    check_hresult(callback->result); return callback->client;
}
struct Loopback {
    com_ptr<IAudioClient> client;
    com_ptr<IAudioCaptureClient> capture;
    bool isolated = false;
    Loopback() {
        // Windows 11 supports process exclusion, preventing a viewing host from
        // sending received Nocturne audio back to its peer. Older Windows uses
        // endpoint loopback; the app mutes that path while it is also a viewer.
        try { client = process_client(); isolated = true; } catch (hresult_error const&) { client = default_client(); }
        auto wave = format();
        check_hresult(client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK |
            AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, 1000000, 0, &wave, nullptr));
        check_hresult(client->GetService(IID_PPV_ARGS(capture.put()))); check_hresult(client->Start());
    }
    ~Loopback() { if (client) client->Stop(); }
    void read(uint8_t* output, int capacity, int* count) {
        *count = 0; UINT32 available = 0; check_hresult(capture->GetNextPacketSize(&available));
        if (available == 0) { std::this_thread::sleep_for(std::chrono::milliseconds(5)); return; }
        BYTE* bytes = nullptr; UINT32 frames = 0; DWORD flags = 0;
        check_hresult(capture->GetBuffer(&bytes, &frames, &flags, nullptr, nullptr));
        // Never grow a queue when the peer is slow: consume the capture packet
        // and retain only a single bounded, recent chunk.
        auto keep = std::min<UINT32>(frames, std::min<UINT32>(4800, std::max(0, capacity) / 8));
        if (flags & AUDCLNT_BUFFERFLAGS_SILENT) memset(output, 0, keep * 8);
        else memcpy(output, bytes + (frames - keep) * 8, keep * 8);
        check_hresult(capture->ReleaseBuffer(frames)); *count = static_cast<int>(keep);
    }
};
struct Playback {
    com_ptr<IAudioClient> client;
    com_ptr<IAudioRenderClient> render;
    UINT32 capacity = 0;
    Playback() {
        client = default_client(); auto wave = format();
        check_hresult(client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
            AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, 1500000, 0, &wave, nullptr));
        check_hresult(client->GetBufferSize(&capacity)); check_hresult(client->GetService(IID_PPV_ARGS(render.put())));
        check_hresult(client->Start());
    }
    ~Playback() { if (client) { client->Stop(); client->Reset(); } }
    void write(uint8_t const* bytes, int frames) {
        require(frames > 0 && frames <= 4800, L"Invalid desktop audio.");
        UINT32 padding = 0; check_hresult(client->GetCurrentPadding(&padding));
        if (padding > 4800 || padding > capacity || capacity - padding < static_cast<UINT32>(frames)) return;
        BYTE* target = nullptr; check_hresult(render->GetBuffer(frames, &target));
        memcpy(target, bytes, static_cast<size_t>(frames) * 8); check_hresult(render->ReleaseBuffer(frames, 0));
    }
};
}
NC_EXPORT void* nocturne_loopback_open() { Loopback* result = nullptr; checked([&] { result = new Loopback(); }); return result; }
NC_EXPORT int nocturne_loopback_read(void* handle, uint8_t* bytes, int capacity, int* frames) {
    return checked([&] { static_cast<Loopback*>(handle)->read(bytes, capacity, frames); });
}
NC_EXPORT int nocturne_loopback_isolated(void* handle) { return static_cast<Loopback*>(handle)->isolated ? 1 : 0; }
NC_EXPORT void nocturne_loopback_close(void* handle) { checked([&] { delete static_cast<Loopback*>(handle); }); }
NC_EXPORT void* nocturne_playback_open() { Playback* result = nullptr; checked([&] { result = new Playback(); }); return result; }
NC_EXPORT int nocturne_playback_write(void* handle, uint8_t const* bytes, int frames) { return checked([&] { static_cast<Playback*>(handle)->write(bytes, frames); }); }
NC_EXPORT void nocturne_playback_close(void* handle) { checked([&] { delete static_cast<Playback*>(handle); }); }
