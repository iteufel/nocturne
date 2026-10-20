#pragma once
#include <windows.h>
#include <objbase.h>
#include <winrt/base.h>
#include <cstdint>
#include <string>
#include <vector>
#include <mutex>
#include <memory>
#include <cstring>

#define NC_EXPORT extern "C" __declspec(dllexport)
namespace nocturne {
inline thread_local std::wstring last_error;
inline thread_local HRESULT last_hresult = S_OK;
inline thread_local std::wstring result_text;
inline void apartment() {
    struct Apartment {
        HRESULT status = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        ~Apartment() { if (SUCCEEDED(status)) CoUninitialize(); }
    };
    static thread_local Apartment initialized;
    if (FAILED(initialized.status) && initialized.status != RPC_E_CHANGED_MODE) winrt::check_hresult(initialized.status);
}
template<typename F> int checked(F action) noexcept {
    try { apartment(); action(); return 1; }
    catch (winrt::hresult_error const& error) { last_error = error.message(); last_hresult = error.code(); }
    catch (std::exception const& error) { auto text = error.what(); last_error.assign(text, text + strlen(text)); last_hresult = E_FAIL; }
    catch (...) { last_error = L"The Windows media operation failed."; last_hresult = E_FAIL; }
    return -1;
}
inline void require(bool condition, wchar_t const* message) {
    if (!condition) throw winrt::hresult_error(E_FAIL, message);
}
inline void check_win32(LONG error) { if (error != ERROR_SUCCESS) winrt::throw_hresult(HRESULT_FROM_WIN32(error)); }
struct EncodedFrame { std::vector<uint8_t> data, header; double timestamp = 0; };
class Encoder {
    struct State;
    std::unique_ptr<State> state;
public:
    Encoder(int width, int height, int fps);
    ~Encoder();
    EncodedFrame encode(uint8_t const* bgra, int width, int height, int stride, int64_t time);
};
}

NC_EXPORT wchar_t const* nocturne_host_error();
NC_EXPORT void* nocturne_capture_open(HWND window, int width, int height, int fps);
NC_EXPORT int nocturne_capture_read(void* handle, uint8_t* bytes, int capacity, int* length,
    uint8_t* header, int header_capacity, int* header_length, double* timestamp);
NC_EXPORT void nocturne_capture_close(void* handle);
NC_EXPORT wchar_t const* nocturne_displays();
NC_EXPORT int nocturne_display_save(wchar_t const* path);
NC_EXPORT int nocturne_display_prepare(wchar_t const* device, int width, int height, int fps, int disable_others);
NC_EXPORT int nocturne_display_restore(wchar_t const* path);
NC_EXPORT wchar_t const* nocturne_audio_devices();
NC_EXPORT void* nocturne_audio_open(wchar_t const* device);
NC_EXPORT int nocturne_audio_write(void* handle, uint8_t const* bytes, int length);
NC_EXPORT void nocturne_audio_close(void* handle);
