#include "native.h"
#include <iostream>
#include <filesystem>
#include <fstream>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <mftransform.h>
#include <wmcodecdsp.h>

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
        return;
    }
    nocturne::require(false, L"The H.264 decoder did not produce an image.");
}

int main() {
    try {
        nocturne::apartment();
        // Run the real BGRA -> NV12 -> H.264 path on both native architectures.
        // This does not depend on a GPU, a virtual driver, or screen contents.
        nocturne::Encoder encoder(640, 480, 30);
        std::vector<uint8_t> pixels(640 * 480 * 4, 0);
        for (size_t i = 0; i < pixels.size(); i += 4) { pixels[i + 2] = 220; pixels[i + 3] = 255; }
        bool encoded = false;
        for (int index = 0; index < 20; ++index) {
            auto frame = encoder.encode(pixels.data(), 640, 480, 640 * 4, index * (10000000 / 30));
            if (frame.data.empty()) continue;
            nocturne::require(frame.data.size() <= 4194304 && !frame.header.empty() && frame.header.size() <= 8192, L"Invalid H.264 output.");
            decode(frame);
            std::ofstream fixture("native-h264-frame.bin", std::ios::binary | std::ios::trunc);
            auto header_size = static_cast<uint32_t>(frame.header.size());
            fixture.write(reinterpret_cast<char*>(&header_size), sizeof(header_size));
            fixture.write(reinterpret_cast<char*>(frame.header.data()), frame.header.size());
            fixture.write(reinterpret_cast<char*>(frame.data.data()), frame.data.size());
            encoded = true; break;
        }
        nocturne::require(encoded, L"The H.264 encoder did not produce a frame.");
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
