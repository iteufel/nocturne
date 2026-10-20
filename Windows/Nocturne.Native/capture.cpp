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
com_ptr<IMFSample> output(IMFTransform* transform, DWORD capacity) {
    MFT_OUTPUT_STREAM_INFO info{}; check_hresult(transform->GetOutputStreamInfo(0, &info));
    com_ptr<IMFSample> owned;
    if (!(info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)) owned = sample_buffer(std::max(capacity, info.cbSize));
    MFT_OUTPUT_DATA_BUFFER data{}; data.pSample = owned.get();
    DWORD status = 0;
    auto hr = transform->ProcessOutput(0, 1, &data, &status);
    if (data.pEvents) data.pEvents->Release();
    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return {};
    if (!owned && data.pSample) owned.attach(data.pSample);
    check_hresult(hr);
    return owned;
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
        auto type = media_type(MFVideoFormat_H264, width, height, fps);
        check_hresult(type->SetUINT32(MF_MT_AVG_BITRATE, static_cast<UINT32>(std::clamp<int64_t>(int64_t(width) * height * fps / 8, 2000000, 30000000))));
        check_hresult(type->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High));
        check_hresult(encoder->SetOutputType(0, type.get(), 0));
        auto input = media_type(MFVideoFormat_NV12, width, height, fps);
        check_hresult(encoder->SetInputType(0, input.get(), 0));
        auto codec = encoder.try_as<ICodecAPI>();
        if (codec) {
            VARIANT value{}; value.vt = VT_BOOL; value.boolVal = VARIANT_TRUE;
            check_hresult(codec->SetValue(&CODECAPI_AVLowLatencyMode, &value));
            value.vt = VT_UI4; value.ulVal = 0;
            check_hresult(codec->SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &value));
            value.ulVal = fps * 2; codec->SetValue(&CODECAPI_AVEncMPVGOPSize, &value);
        }
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
EncodedFrame Encoder::encode(uint8_t const* bgra, int width, int height, int stride, int64_t time) {
    auto& s = *state;
    require(width > 0 && height > 0 && width <= 16384 && height <= 16384 && stride >= width * 4, L"Invalid capture frame.");
    if (s.source_width != width || s.source_height != height) {
        s.converter = {};
        check_hresult(CoCreateInstance(CLSID_VideoProcessorMFT, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(s.converter.put())));
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
    check_hresult(s.converter->ProcessInput(0, input.get(), 0));
    auto converted = output(s.converter.get(), s.width * s.height * 3 / 2);
    if (!converted) return {};
    check_hresult(converted->SetSampleTime(time)); check_hresult(converted->SetSampleDuration(10000000 / s.fps));
    check_hresult(s.encoder->ProcessInput(0, converted.get(), 0));
    auto encoded = output(s.encoder.get(), 4 * 1024 * 1024);
    if (!encoded) return {};
    if (s.header.empty()) {
        com_ptr<IMFMediaType> type; UINT32 length = 0;
        check_hresult(s.encoder->GetOutputCurrentType(0, type.put()));
        if (SUCCEEDED(type->GetBlobSize(MF_MT_MPEG_SEQUENCE_HEADER, &length)) && length <= 8192) {
            s.header.resize(length); check_hresult(type->GetBlob(MF_MT_MPEG_SEQUENCE_HEADER, s.header.data(), length, nullptr));
        }
    }
    LONGLONG actual_time = time; encoded->GetSampleTime(&actual_time);
    return { sample_bytes(encoded.get()), s.header, actual_time / 10000000.0 };
}

namespace {
struct Signal {
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    ~Signal() { if (event) CloseHandle(event); }
};
struct Capture {
    HWND window;
    com_ptr<ID3D11Device> device;
    com_ptr<ID3D11DeviceContext> context;
    IDirect3DDevice projected{ nullptr };
    GraphicsCaptureItem item{ nullptr };
    Direct3D11CaptureFramePool pool{ nullptr };
    GraphicsCaptureSession session{ nullptr };
    event_token arrived{};
    std::shared_ptr<Signal> signal = std::make_shared<Signal>();
    Encoder encoder;
    Capture(HWND window, int width, int height, int fps) : window(window), encoder(width, height, fps) {
        require(IsWindow(window) && GraphicsCaptureSession::IsSupported(), L"Windows Graphics Capture is unavailable for this window.");
        auto hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            nullptr, 0, D3D11_SDK_VERSION, device.put(), nullptr, context.put());
        if (FAILED(hr)) check_hresult(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            nullptr, 0, D3D11_SDK_VERSION, device.put(), nullptr, context.put()));
        auto dxgi = device.as<IDXGIDevice>(); com_ptr<IInspectable> inspectable;
        check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), inspectable.put()));
        projected = inspectable.as<IDirect3DDevice>();
        auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        check_hresult(interop->CreateForWindow(window, guid_of<GraphicsCaptureItem>(), put_abi(item)));
        pool = Direct3D11CaptureFramePool::CreateFreeThreaded(projected, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, item.Size());
        arrived = pool.FrameArrived([signal = signal](auto const&, auto const&) { SetEvent(signal->event); });
        session = pool.CreateCaptureSession(item); session.IsCursorCaptureEnabled(true); session.StartCapture();
    }
    ~Capture() {
        if (pool) pool.FrameArrived(arrived);
        if (session) session.Close();
        if (pool) pool.Close();
    }
    EncodedFrame read() {
        require(IsWindow(window), L"This app window closed. Choose another window in Apps.");
        if (WaitForSingleObject(signal->event, 250) != WAIT_OBJECT_0) return {};
        auto frame = pool.TryGetNextFrame(); if (!frame) return {};
        while (auto next = pool.TryGetNextFrame()) { frame.Close(); frame = next; }
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
        EncodedFrame result;
        try { result = encoder.encode(static_cast<uint8_t*>(mapped.pData), size.Width, size.Height,
            static_cast<int>(mapped.RowPitch), frame.SystemRelativeTime().count()); }
        catch (...) { context->Unmap(staging.get(), 0); throw; }
        context->Unmap(staging.get(), 0); return result;
    }
};
}
NC_EXPORT void* nocturne_capture_open(HWND window, int width, int height, int fps) {
    Capture* result = nullptr; checked([&] { result = new Capture(window, width, height, fps); }); return result;
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
