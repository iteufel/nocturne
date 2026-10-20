#include "native.h"
#include <iostream>
#include <filesystem>
#include <fstream>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <mftransform.h>
#include <wmcodecdsp.h>
#include <algorithm>
#include <thread>
#include <future>
#include <dxgi.h>
#include <winrt/Windows.Graphics.Capture.h>

static void decode(nocturne::EncodedFrame const& frame) {
    using namespace winrt;
    com_ptr<IMFTransform> decoder;
    check_hresult(CoCreateInstance(CLSID_CMSH264DecoderMFT, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(decoder.put())));
    com_ptr<IMFMediaType> input; check_hresult(MFCreateMediaType(input.put()));
    check_hresult(input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
    check_hresult(input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264));
    check_hresult(MFSetAttributeSize(input.get(), MF_MT_FRAME_SIZE, 640, 480));
    check_hresult(input->SetBlob(MF_MT_MPEG_SEQUENCE_HEADER, frame.header.data(), static_cast<UINT32>(frame.header.size())));
    check_hresult(decoder->SetInputType(0, input.get(), 0));
    auto set_output = [&] {
        for (DWORD i = 0;; ++i) {
            com_ptr<IMFMediaType> type;
            check_hresult(decoder->GetOutputAvailableType(0, i, type.put()));
            GUID format{}; check_hresult(type->GetGUID(MF_MT_SUBTYPE, &format));
            if (format != MFVideoFormat_NV12) continue;
            check_hresult(decoder->SetOutputType(0, type.get(), 0)); break;
        }
    };
    set_output();
    check_hresult(decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0));
    check_hresult(decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0));
    com_ptr<IMFSample> sample; com_ptr<IMFMediaBuffer> buffer;
    check_hresult(MFCreateSample(sample.put()));
    check_hresult(MFCreateMemoryBuffer(static_cast<DWORD>(frame.data.size()), buffer.put()));
    BYTE* bytes = nullptr; check_hresult(buffer->Lock(&bytes, nullptr, nullptr));
    memcpy(bytes, frame.data.data(), frame.data.size()); check_hresult(buffer->Unlock());
    check_hresult(buffer->SetCurrentLength(static_cast<DWORD>(frame.data.size())));
    check_hresult(sample->AddBuffer(buffer.get())); check_hresult(sample->SetSampleTime(0)); check_hresult(sample->SetSampleDuration(333333));
    check_hresult(decoder->ProcessInput(0, sample.get(), 0));
    check_hresult(decoder->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0));
    for (int attempt = 0; attempt < 3; ++attempt) {
        MFT_OUTPUT_STREAM_INFO info{}; check_hresult(decoder->GetOutputStreamInfo(0, &info));
        com_ptr<IMFSample> output; com_ptr<IMFMediaBuffer> target;
        if (!(info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)) {
            check_hresult(MFCreateSample(output.put()));
            check_hresult(MFCreateMemoryBuffer(std::max<DWORD>(info.cbSize, 640 * 480 * 2), target.put()));
            check_hresult(output->AddBuffer(target.get()));
        }
        MFT_OUTPUT_DATA_BUFFER data{}; data.pSample = output.get(); DWORD flags = 0;
        auto hr = decoder->ProcessOutput(0, 1, &data, &flags);
        if (data.pEvents) data.pEvents->Release();
        if (!output && data.pSample) output.attach(data.pSample);
        if (hr == MF_E_TRANSFORM_STREAM_CHANGE) { set_output(); continue; }
        check_hresult(hr);
        nocturne::require(output != nullptr, L"The H.264 decoder returned no image.");
        com_ptr<IMFMediaBuffer> decoded; check_hresult(output->ConvertToContiguousBuffer(decoded.put()));
        DWORD length = 0; check_hresult(decoded->GetCurrentLength(&length));
        nocturne::require(length >= 640 * 480 * 3 / 2, L"The decoded image is incomplete.");
        BYTE* image = nullptr; check_hresult(decoded->Lock(&image, nullptr, nullptr));
        auto center = image[240 * 640 + 320];
        auto u = image[640 * 480 + 120 * 640 + 320], v = image[640 * 480 + 120 * 640 + 321];
        check_hresult(decoded->Unlock());
        nocturne::require(center >= 30 && center < 115 && u < 150 && v > 150, L"The decoded window pixel is not red; capture may include the occluding green window.");
        return;
    }
    nocturne::require(false, L"The H.264 decoder did not produce an image.");
}

class TestWindow {
    std::thread thread;
    HWND window = nullptr;
    static LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
        if (message == WM_NCCREATE) {
            SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams));
        }
        if (message == WM_PAINT) {
            PAINTSTRUCT paint{}; auto dc = BeginPaint(window, &paint);
            auto brush = CreateSolidBrush(static_cast<COLORREF>(GetWindowLongPtrW(window, GWLP_USERDATA)));
            FillRect(dc, &paint.rcPaint, brush); DeleteObject(brush); EndPaint(window, &paint); return 0;
        }
        if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
        return DefWindowProcW(window, message, wparam, lparam);
    }
public:
    explicit TestWindow(COLORREF color) {
        std::promise<HWND> ready; auto result = ready.get_future();
        thread = std::thread([color, &ready] {
            WNDCLASSW cls{}; cls.lpfnWndProc = procedure; cls.hInstance = GetModuleHandleW(nullptr); cls.lpszClassName = L"NocturneNativeCaptureTest";
            RegisterClassW(&cls);
            auto handle = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName, L"Nocturne capture verification", WS_OVERLAPPEDWINDOW,
                80, 80, 700, 540, nullptr, nullptr, cls.hInstance, reinterpret_cast<void*>(static_cast<uintptr_t>(color)));
            if (handle) { ShowWindow(handle, SW_SHOWNOACTIVATE); UpdateWindow(handle); }
            ready.set_value(handle);
            if (!handle) return;
            MSG message{}; while (GetMessageW(&message, nullptr, 0, 0) > 0) { TranslateMessage(&message); DispatchMessageW(&message); }
        });
        window = result.get();
        if (!window) { thread.join(); throw winrt::hresult_error(E_FAIL, L"The test window could not be created."); }
    }
    ~TestWindow() { if (window) PostMessageW(window, WM_CLOSE, 0, 0); if (thread.joinable()) thread.join(); }
    HWND handle() const { return window; }
};

static void capture_window() {
    DWORD session = 0; ProcessIdToSessionId(GetCurrentProcessId(), &session);
    if (session != WTSGetActiveConsoleSessionId() || !winrt::Windows::Graphics::Capture::GraphicsCaptureSession::IsSupported()) {
        std::cout << "Window capture skipped: the runner has no supported interactive console.\n"; return;
    }
    TestWindow red(RGB(220, 0, 0)), green(RGB(0, 220, 0));
    SetWindowPos(green.handle(), HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    void* capture = nocturne_capture_open(red.handle(), 640, 480, 30);
    if (!capture && (nocturne::last_hresult == DXGI_ERROR_UNSUPPORTED || nocturne::last_hresult == E_NOTIMPL)) {
        std::cout << "Window capture skipped: the runner's display driver does not support Graphics Capture.\n"; return;
    }
    nocturne::require(capture != nullptr, nocturne_host_error());
    try {
        std::vector<uint8_t> bytes(4194304), header(8192); bool received = false;
        for (int attempt = 0; attempt < 24; ++attempt) {
            int length = 0, header_length = 0; double timestamp = 0;
            nocturne::require(nocturne_capture_read(capture, bytes.data(), static_cast<int>(bytes.size()), &length,
                header.data(), static_cast<int>(header.size()), &header_length, &timestamp) > 0, nocturne_host_error());
            if (length == 0) continue;
            decode({ std::vector<uint8_t>(bytes.begin(), bytes.begin() + length), std::vector<uint8_t>(header.begin(), header.begin() + header_length), timestamp });
            received = true; break;
        }
        nocturne::require(received, L"The app-window capture did not produce a video frame.");
        std::cout << "An occluded window was captured and decoded without including the overlapping window.\n";
    }
    catch (...) { nocturne_capture_close(capture); throw; }
    nocturne_capture_close(capture);
}

int main() {
    try {
        nocturne::apartment();
        // Run the real BGRA -> NV12 -> H.264 path on both native architectures.
        // This does not depend on a GPU, a virtual driver, or screen contents.
        nocturne::Encoder encoder(640, 480, 30);
        std::vector<uint8_t> pixels(640 * 480 * 4, 0);
        for (size_t i = 0; i < pixels.size(); i += 4) { pixels[i + 2] = 220; pixels[i + 3] = 255; }
        bool encoded = false; int frames = 0;
        for (int index = 0; index < 30; ++index) {
            auto frame = encoder.encode(pixels.data(), 640, 480, 640 * 4, index * (10000000 / 30));
            if (frame.data.empty()) continue;
            nocturne::require(frame.data.size() <= 4194304 && !frame.header.empty() && frame.header.size() <= 8192, L"Invalid H.264 output.");
            if (!encoded) {
                decode(frame);
                std::ofstream fixture("native-h264-frame.bin", std::ios::binary | std::ios::trunc);
                auto header_size = static_cast<uint32_t>(frame.header.size());
                fixture.write(reinterpret_cast<char*>(&header_size), sizeof(header_size));
                fixture.write(reinterpret_cast<char*>(frame.header.data()), frame.header.size());
                fixture.write(reinterpret_cast<char*>(frame.data.data()), frame.data.size());
            }
            encoded = true; frames++;
        }
        nocturne::require(encoded, L"The H.264 encoder did not produce a frame.");
        nocturne::require(frames >= 15, L"The H.264 encoder stalled during sustained capture.");
        capture_window();
        // Hosted Windows runners may lack an interactive display/audio session.
        // Device availability is checked by the application when enabling a feature.
        std::cout << "Native H.264 encode/decode passed. Displays available: " << (nocturne_displays() != nullptr)
            << "; audio enumeration available: " << (nocturne_audio_devices() != nullptr) << '\n';
        return 0;
    }
    catch (winrt::hresult_error const& error) { std::wcerr << error.message().c_str() << L" (" << std::hex << error.code().value << L")\n"; }
    catch (std::exception const& error) { std::cerr << error.what() << '\n'; }
    return 1;
}
