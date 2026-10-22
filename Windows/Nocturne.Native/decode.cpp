#include "native.h"
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <mftransform.h>
#include <codecapi.h>
#include <wmcodecdsp.h>
#include <algorithm>
#include <cmath>
using namespace nocturne;
using namespace winrt;
namespace {
struct Decoder {
    com_ptr<IMFTransform> decoder;
    int width = 0, height = 0, stride = 0;
    Decoder(int w, int h) {
        require(w >= 2 && w <= 4096 && h >= 2 && h <= 4096, L"Invalid video dimensions.");
        check_hresult(MFStartup(MF_VERSION, MFSTARTUP_LITE));
        check_hresult(CoCreateInstance(CLSID_CMSH264DecoderMFT, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(decoder.put())));
        if (auto codec = decoder.try_as<ICodecAPI>()) {
            VARIANT value{}; value.vt = VT_UI4; value.ulVal = TRUE;
            check_stage(codec->SetValue(&CODECAPI_AVLowLatencyMode, &value), L"Configure low-latency decoder");
        }
        com_ptr<IMFMediaType> input; check_hresult(MFCreateMediaType(input.put()));
        check_hresult(input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
        check_hresult(input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264));
        check_hresult(MFSetAttributeSize(input.get(), MF_MT_FRAME_SIZE, w, h));
        check_hresult(decoder->SetInputType(0, input.get(), 0)); set_output();
        check_hresult(decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0));
        check_hresult(decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0));
    }
    ~Decoder() { decoder = {}; MFShutdown(); }
    void set_output() {
        for (DWORD index = 0; index < 64; ++index) {
            com_ptr<IMFMediaType> type;
            check_hresult(decoder->GetOutputAvailableType(0, index, type.put()));
            GUID format{}; check_hresult(type->GetGUID(MF_MT_SUBTYPE, &format));
            if (format != MFVideoFormat_NV12) continue;
            check_hresult(decoder->SetOutputType(0, type.get(), 0));
            UINT32 w = 0, h = 0, pitch = 0;
            check_hresult(MFGetAttributeSize(type.get(), MF_MT_FRAME_SIZE, &w, &h));
            require(w >= 2 && w <= 4096 && h >= 2 && h <= 4096 && w % 2 == 0 && h % 2 == 0, L"Invalid decoded video size.");
            if (FAILED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &pitch))) pitch = w;
            require(pitch >= w && pitch <= 16384, L"Invalid decoder stride.");
            width = static_cast<int>(w); height = static_cast<int>(h); stride = static_cast<int>(pitch); return;
        }
        require(false, L"The decoder does not support NV12 video.");
    }
    bool receive(std::vector<uint8_t>& image) {
        for (int attempt = 0; attempt < 4; ++attempt) {
            MFT_OUTPUT_STREAM_INFO info{}; check_hresult(decoder->GetOutputStreamInfo(0, &info));
            com_ptr<IMFSample> sample;
            if (!(info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)) {
                com_ptr<IMFMediaBuffer> buffer;
                check_hresult(MFCreateMemoryBuffer(std::max<DWORD>(info.cbSize, stride * height * 2), buffer.put()));
                check_hresult(MFCreateSample(sample.put())); check_hresult(sample->AddBuffer(buffer.get()));
            }
            MFT_OUTPUT_DATA_BUFFER output{}; output.pSample = sample.get(); DWORD flags = 0;
            auto status = decoder->ProcessOutput(0, 1, &output, &flags);
            if (output.pEvents) output.pEvents->Release();
            if (!sample && output.pSample) sample.attach(output.pSample);
            if (status == MF_E_TRANSFORM_NEED_MORE_INPUT) return false;
            if (status == MF_E_TRANSFORM_STREAM_CHANGE) { set_output(); continue; }
            check_stage(status, L"Decode desktop video");
            require(sample != nullptr, L"The decoder returned no frame.");
            com_ptr<IMFMediaBuffer> buffer; check_hresult(sample->ConvertToContiguousBuffer(buffer.put()));
            BYTE* bytes = nullptr; DWORD size = 0; check_hresult(buffer->Lock(&bytes, nullptr, &size));
            if (size < static_cast<DWORD>(stride * height * 3 / 2)) { buffer->Unlock(); require(false, L"Incomplete decoded image."); }
            image.resize(static_cast<size_t>(width) * height * 4);
            for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
                int c = int(bytes[y * stride + x]) - 16;
                auto uv = stride * height + (y / 2) * stride + (x / 2) * 2;
                int d = int(bytes[uv]) - 128, e = int(bytes[uv + 1]) - 128;
                auto target = (static_cast<size_t>(y) * width + x) * 4;
                image[target] = static_cast<uint8_t>(std::clamp((298 * c + 516 * d + 128) >> 8, 0, 255));
                image[target + 1] = static_cast<uint8_t>(std::clamp((298 * c - 100 * d - 208 * e + 128) >> 8, 0, 255));
                image[target + 2] = static_cast<uint8_t>(std::clamp((298 * c + 409 * e + 128) >> 8, 0, 255));
                image[target + 3] = 255;
            }
            check_hresult(buffer->Unlock()); return true;
        }
        require(false, L"The decoder changed format too many times."); return false;
    }
    void frame(uint8_t const* bytes, int length, double timestamp, std::vector<uint8_t>& image) {
        require(length > 0 && length <= 4202512 && std::isfinite(timestamp) && timestamp >= 0 && timestamp <= 1e10, L"Invalid video frame.");
        com_ptr<IMFMediaBuffer> buffer; com_ptr<IMFSample> input;
        check_hresult(MFCreateMemoryBuffer(length, buffer.put()));
        BYTE* data = nullptr; check_hresult(buffer->Lock(&data, nullptr, nullptr));
        memcpy(data, bytes, length); check_hresult(buffer->Unlock()); check_hresult(buffer->SetCurrentLength(length));
        check_hresult(MFCreateSample(input.put())); check_hresult(input->AddBuffer(buffer.get()));
        check_hresult(input->SetSampleTime(static_cast<LONGLONG>(timestamp * 10000000))); check_hresult(input->SetSampleDuration(166666));
        auto status = decoder->ProcessInput(0, input.get(), 0);
        if (status == MF_E_NOTACCEPTING) { while (receive(image)) {} status = decoder->ProcessInput(0, input.get(), 0); }
        check_stage(status, L"Submit desktop video");
        int pending = 0; while (receive(image)) require(++pending <= 8, L"Too many decoded frames.");
    }
};
}
NC_EXPORT void* nocturne_decoder_open(int width, int height) {
    Decoder* result = nullptr; checked([&] { result = new Decoder(width, height); }); return result;
}
NC_EXPORT int nocturne_decoder_frame(void* handle, uint8_t const* bytes, int length, double timestamp,
    uint8_t* bgra, int capacity, int* width, int* height, int* size) {
    *size = 0;
    return checked([&] {
        auto decoder = static_cast<Decoder*>(handle); std::vector<uint8_t> image;
        decoder->frame(bytes, length, timestamp, image);
        require(image.size() <= static_cast<size_t>(capacity), L"The video image is too large.");
        memcpy(bgra, image.data(), image.size()); *width = decoder->width; *height = decoder->height; *size = static_cast<int>(image.size());
    });
}
NC_EXPORT void nocturne_decoder_close(void* handle) { checked([&] { delete static_cast<Decoder*>(handle); }); }
