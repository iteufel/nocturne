#include "native.h"
#include <d3d11.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <codecapi.h>
#include <wmcodecdsp.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <algorithm>
#include <memory>
#include <deque>
#include <chrono>
#include <thread>
#include <atomic>

using namespace winrt;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;
using ::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess;
using namespace nocturne;

NC_EXPORT wchar_t const* nocturne_host_error() { return last_error.c_str(); }

namespace {
void foundation() {
    static std::once_flag once;
    std::call_once(once, [] { check_hresult(MFStartup(MF_VERSION, MFSTARTUP_LITE)); });
}
com_ptr<IMFMediaType> media_type(GUID format, int width, int height, int fps) {
    com_ptr<IMFMediaType> type;
    check_hresult(MFCreateMediaType(type.put()));
    check_hresult(type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
    check_hresult(type->SetGUID(MF_MT_SUBTYPE, format));
    check_hresult(MFSetAttributeSize(type.get(), MF_MT_FRAME_SIZE, width, height));
    check_hresult(MFSetAttributeRatio(type.get(), MF_MT_FRAME_RATE, fps, 1));
    check_hresult(MFSetAttributeRatio(type.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1));
    check_hresult(type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
    return type;
}
com_ptr<IMFSample> sample_buffer(DWORD capacity) {
    com_ptr<IMFMediaBuffer> buffer; com_ptr<IMFSample> sample;
    check_hresult(MFCreateMemoryBuffer(capacity, buffer.put()));
    check_hresult(MFCreateSample(sample.put()));
    check_hresult(sample->AddBuffer(buffer.get()));
    return sample;
}
com_ptr<IMFSample> output(IMFTransform* transform, DWORD capacity, wchar_t const* stage) {
    MFT_OUTPUT_STREAM_INFO info{}; check_stage(transform->GetOutputStreamInfo(0, &info), stage);
    com_ptr<IMFSample> owned;
    if (!(info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)) owned = sample_buffer(std::max(capacity, info.cbSize));
    MFT_OUTPUT_DATA_BUFFER data{}; data.pSample = owned.get();
    DWORD status = 0;
    auto hr = transform->ProcessOutput(0, 1, &data, &status);
    if (data.pEvents) data.pEvents->Release();
    if (!owned && data.pSample) owned.attach(data.pSample);
    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return {};
    check_stage(hr, stage);
    require(owned != nullptr, L"The media transform returned no output sample.");
    return owned;
}
template<typename Accept> void drain(IMFTransform* transform, DWORD capacity, wchar_t const* stage, Accept accept) {
    int samples = 0;
    while (auto sample = output(transform, capacity, stage)) {
        require(++samples <= 8, L"The media transform produced too many pending frames.");
        accept(sample);
    }
}
template<typename Accept> void process(IMFTransform* transform, IMFSample* input, DWORD capacity, wchar_t const* stage, Accept accept) {
    auto status = transform->ProcessInput(0, input, 0);
    if (status == MF_E_NOTACCEPTING) {
        drain(transform, capacity, stage, accept);
        status = transform->ProcessInput(0, input, 0);
    }
    check_stage(status, stage);
    // A single input can yield several samples. Retrieve all of them before
    // submitting another frame; otherwise synchronous MFTs can reject input.
    drain(transform, capacity, stage, accept);
}
std::vector<uint8_t> sample_bytes(IMFSample* sample) {
    com_ptr<IMFMediaBuffer> buffer; check_hresult(sample->ConvertToContiguousBuffer(buffer.put()));
    BYTE* pointer = nullptr; DWORD length = 0; check_hresult(buffer->Lock(&pointer, nullptr, &length));
    std::vector<uint8_t> data(pointer, pointer + length); check_hresult(buffer->Unlock()); return data;
}
void begin(IMFTransform* transform) {
    check_hresult(transform->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0));
    check_hresult(transform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0));
}
}

struct Encoder::State {
    int width, height, fps, source_width = 0, source_height = 0;
    com_ptr<IMFTransform> encoder, converter;
    std::vector<uint8_t> header;
    State(int width, int height, int fps) : width(width), height(height), fps(fps) {
        apartment(); foundation();
        require(width >= 2 && height >= 2 && width <= 4096 && height <= 4096 && width % 2 == 0 && height % 2 == 0 && (fps == 30 || fps == 60), L"Invalid app video size.");
        check_hresult(CoCreateInstance(CLSID_CMSH264EncoderMFT, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(encoder.put())));
        // B-frame configuration becomes immutable when the output type is set.
        // Apply codec properties before negotiating either media type.
        auto codec = encoder.try_as<ICodecAPI>();
        if (codec) {
            VARIANT value{}; value.vt = VT_BOOL; value.boolVal = VARIANT_TRUE;
            check_stage(codec->SetValue(&CODECAPI_AVLowLatencyMode, &value), L"Configure low-latency H.264 encoding");
            value.vt = VT_UI4; value.ulVal = 0;
            check_stage(codec->SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &value), L"Disable H.264 B frames");
            value.ulVal = fps * 2; codec->SetValue(&CODECAPI_AVEncMPVGOPSize, &value);
        }
        auto type = media_type(MFVideoFormat_H264, width, height, fps);
        check_hresult(type->SetUINT32(MF_MT_AVG_BITRATE, static_cast<UINT32>(std::clamp<int64_t>(int64_t(width) * height * fps / 8, 2000000, 30000000))));
        check_hresult(type->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High));
        check_stage(encoder->SetOutputType(0, type.get(), 0), L"Set H.264 output type");
        auto input = media_type(MFVideoFormat_NV12, width, height, fps);
        check_stage(encoder->SetInputType(0, input.get(), 0), L"Set H.264 input type");
        UINT32 length = 0;
        type = {}; check_hresult(encoder->GetOutputCurrentType(0, type.put()));
        if (SUCCEEDED(type->GetBlobSize(MF_MT_MPEG_SEQUENCE_HEADER, &length)) && length <= 8192) {
            header.resize(length); check_hresult(type->GetBlob(MF_MT_MPEG_SEQUENCE_HEADER, header.data(), length, nullptr));
        }
        begin(encoder.get());
    }
};
Encoder::Encoder(int width, int height, int fps) : state(std::make_unique<State>(width, height, fps)) { }
Encoder::~Encoder() = default;
std::vector<EncodedFrame> Encoder::encode(uint8_t const* bgra, int width, int height, int stride, int64_t time) {
    auto& s = *state;
    require(width > 0 && height > 0 && width <= 16384 && height <= 16384 && stride >= width * 4, L"Invalid capture frame.");
    if (s.source_width != width || s.source_height != height) {
        s.converter = {};
        check_hresult(CoCreateInstance(CLSID_VideoProcessorMFT, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(s.converter.put())));
        com_ptr<IMFAttributes> attributes; check_hresult(s.converter->GetAttributes(attributes.put()));
        // Capture can skip frames under backpressure. Convert pixels without
        // synthesizing replacement frames for the resulting timestamp gaps.
        check_hresult(attributes->SetUINT32(MF_XVP_DISABLE_FRC, TRUE));
        auto input = media_type(MFVideoFormat_ARGB32, width, height, s.fps);
        check_hresult(input->SetUINT32(MF_MT_DEFAULT_STRIDE, width * 4));
        check_hresult(s.converter->SetInputType(0, input.get(), 0));
        auto target = media_type(MFVideoFormat_NV12, s.width, s.height, s.fps);
        check_hresult(s.converter->SetOutputType(0, target.get(), 0));
        begin(s.converter.get()); s.source_width = width; s.source_height = height;
    }
    auto input = sample_buffer(width * height * 4);
    com_ptr<IMFMediaBuffer> buffer; check_hresult(input->GetBufferByIndex(0, buffer.put()));
    BYTE* pointer = nullptr; check_hresult(buffer->Lock(&pointer, nullptr, nullptr));
    for (int row = 0; row < height; ++row) memcpy(pointer + row * width * 4, bgra + row * stride, width * 4);
    check_hresult(buffer->Unlock()); check_hresult(buffer->SetCurrentLength(width * height * 4));
    check_hresult(input->SetSampleTime(time)); check_hresult(input->SetSampleDuration(10000000 / s.fps));
    std::vector<EncodedFrame> frames;
    process(s.converter.get(), input.get(), s.width * s.height * 3 / 2, L"BGRA to NV12 conversion", [&](auto const& converted) {
        LONGLONG converted_time = time, duration = 10000000 / s.fps;
        if (FAILED(converted->GetSampleTime(&converted_time))) {
            converted_time = time; check_hresult(converted->SetSampleTime(time));
        }
        if (FAILED(converted->GetSampleDuration(&duration))) check_hresult(converted->SetSampleDuration(10000000 / s.fps));
        process(s.encoder.get(), converted.get(), 4 * 1024 * 1024, L"H.264 encoding", [&](auto const& encoded) {
            if (s.header.empty()) {
                com_ptr<IMFMediaType> type; UINT32 length = 0;
                check_hresult(s.encoder->GetOutputCurrentType(0, type.put()));
                if (SUCCEEDED(type->GetBlobSize(MF_MT_MPEG_SEQUENCE_HEADER, &length)) && length <= 8192) {
                    s.header.resize(length); check_hresult(type->GetBlob(MF_MT_MPEG_SEQUENCE_HEADER, s.header.data(), length, nullptr));
                }
            }
            LONGLONG actual_time = converted_time; encoded->GetSampleTime(&actual_time);
            require(frames.size() < 8, L"The encoder produced too many pending frames.");
            frames.push_back({ sample_bytes(encoded.get()), s.header, actual_time / 10000000.0 });
        });
    });
    return frames;
}

namespace {
struct Signal {
    std::atomic<bool> closed = false;
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    ~Signal() { if (event) CloseHandle(event); }
};
struct Capture {
    HWND window;
    HMONITOR monitor;
    com_ptr<ID3D11Device> device;
    com_ptr<ID3D11DeviceContext> context;
    IDirect3DDevice projected{ nullptr };
    GraphicsCaptureItem item{ nullptr };
    Direct3D11CaptureFramePool pool{ nullptr };
    GraphicsCaptureSession session{ nullptr };
    event_token arrived{}, closed{};
    std::shared_ptr<Signal> signal = std::make_shared<Signal>();
    Encoder encoder;
    std::deque<EncodedFrame> pending;
    std::chrono::nanoseconds interval;
    std::chrono::steady_clock::time_point next_capture{};
    Capture(HWND window, HMONITOR monitor, int width, int height, int fps) : window(window), monitor(monitor), encoder(width, height, fps), interval(1000000000 / fps) {
        require((monitor != nullptr || IsWindow(window)) && GraphicsCaptureSession::IsSupported(), L"Windows Graphics Capture is unavailable for this desktop.");
        auto hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            nullptr, 0, D3D11_SDK_VERSION, device.put(), nullptr, context.put());
        if (FAILED(hr)) check_hresult(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            nullptr, 0, D3D11_SDK_VERSION, device.put(), nullptr, context.put()));
        auto dxgi = device.as<IDXGIDevice>(); com_ptr<IInspectable> inspectable;
        check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), inspectable.put()));
        projected = inspectable.as<IDirect3DDevice>();
        auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        if (monitor) check_stage(interop->CreateForMonitor(monitor, guid_of<GraphicsCaptureItem>(), put_abi(item)), L"Create monitor capture item");
        else check_stage(interop->CreateForWindow(window, guid_of<GraphicsCaptureItem>(), put_abi(item)), L"Create window capture item");
        closed = item.Closed([signal = signal](auto const&, auto const&) { signal->closed = true; SetEvent(signal->event); });
        pool = Direct3D11CaptureFramePool::CreateFreeThreaded(projected, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, item.Size());
        arrived = pool.FrameArrived([signal = signal](auto const&, auto const&) { SetEvent(signal->event); });
        session = pool.CreateCaptureSession(item); session.IsCursorCaptureEnabled(true); session.StartCapture();
    }
    ~Capture() noexcept {
        try { if (item) item.Closed(closed); } catch (...) { }
        try { if (pool) pool.FrameArrived(arrived); } catch (...) { }
        try { if (session) session.Close(); } catch (...) { }
        try { if (pool) pool.Close(); } catch (...) { }
    }
    EncodedFrame read() {
        require(!signal->closed.load(), L"The captured display or window disconnected. Reconnect to continue.");
        require(monitor != nullptr || IsWindow(window), L"This app window closed. Choose another window in Apps.");
        auto take = [&] { auto frame = std::move(pending.front()); pending.pop_front(); return frame; };
        if (!pending.empty()) return take();
        if (WaitForSingleObject(signal->event, 250) != WAIT_OBJECT_0) return {};
        // Limit capture cadence before choosing the newest unencoded frame.
        // Encoded frames in pending must all be delivered in reference order.
        std::this_thread::sleep_until(next_capture);
        auto frame = pool.TryGetNextFrame(); if (!frame) return {};
        while (auto next = pool.TryGetNextFrame()) { frame.Close(); frame = next; }
        next_capture = std::chrono::steady_clock::now() + interval;
        auto size = frame.ContentSize(); if (size.Width <= 0 || size.Height <= 0) return {};
        auto surface = frame.Surface().as<IDirect3DDxgiInterfaceAccess>(); com_ptr<ID3D11Texture2D> texture;
        check_hresult(surface->GetInterface(__uuidof(ID3D11Texture2D), texture.put_void()));
        D3D11_TEXTURE2D_DESC desc{}; texture->GetDesc(&desc);
        if (size.Width > static_cast<int>(desc.Width) || size.Height > static_cast<int>(desc.Height)) {
            frame.Close(); pool.Recreate(projected, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size); return {};
        }
        desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = 0; desc.MiscFlags = 0; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        com_ptr<ID3D11Texture2D> staging; check_hresult(device->CreateTexture2D(&desc, nullptr, staging.put()));
        context->CopyResource(staging.get(), texture.get());
        D3D11_MAPPED_SUBRESOURCE mapped{}; check_hresult(context->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped));
        std::vector<EncodedFrame> frames;
        try { frames = encoder.encode(static_cast<uint8_t*>(mapped.pData), size.Width, size.Height,
            static_cast<int>(mapped.RowPitch), frame.SystemRelativeTime().count()); }
        catch (...) { context->Unmap(staging.get(), 0); throw; }
        context->Unmap(staging.get(), 0);
        for (auto& encoded : frames) pending.push_back(std::move(encoded));
        return pending.empty() ? EncodedFrame{} : take();
    }
};
}
NC_EXPORT void* nocturne_capture_open(HWND window, int width, int height, int fps) {
    Capture* result = nullptr; checked([&] { result = new Capture(window, nullptr, width, height, fps); }); return result;
}
NC_EXPORT int nocturne_capture_read(void* handle, uint8_t* bytes, int capacity, int* length,
    uint8_t* header, int header_capacity, int* header_length, double* timestamp) {
    *length = 0; *header_length = 0;
    return checked([&] {
        auto frame = static_cast<Capture*>(handle)->read();
        require(frame.data.size() <= static_cast<size_t>(capacity) && frame.header.size() <= static_cast<size_t>(header_capacity), L"The app video frame is too large.");
        memcpy(bytes, frame.data.data(), frame.data.size()); memcpy(header, frame.header.data(), frame.header.size());
        *length = static_cast<int>(frame.data.size()); *header_length = static_cast<int>(frame.header.size()); *timestamp = frame.timestamp;
    });
}
NC_EXPORT void nocturne_capture_close(void* handle) { checked([&] { delete static_cast<Capture*>(handle); }); }

NC_EXPORT void* nocturne_desktop_open(HMONITOR monitor, int width, int height, int fps) {
    Capture* result = nullptr; checked([&] { require(monitor != nullptr, L"The monitor is unavailable."); result = new Capture(nullptr, monitor, width, height, fps); }); return result;
}
