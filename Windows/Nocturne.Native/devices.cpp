#include "native.h"
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <propsys.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <filesystem>
#include <fstream>
#include <map>
#include <algorithm>
#include <array>

using namespace winrt;
using namespace winrt::Windows::Data::Json;
using namespace nocturne;

namespace {
struct Topology {
    std::vector<DISPLAYCONFIG_PATH_INFO> paths;
    std::vector<DISPLAYCONFIG_MODE_INFO> modes;
};
Topology topology(UINT32 flags) {
    for (int attempt = 0; attempt < 5; ++attempt) {
        UINT32 count = 0, modes = 0;
        check_win32(GetDisplayConfigBufferSizes(flags, &count, &modes));
        require(count <= 512 && modes <= 4096, L"Too many display paths.");
        Topology result{ std::vector<DISPLAYCONFIG_PATH_INFO>(count), std::vector<DISPLAYCONFIG_MODE_INFO>(modes) };
        auto status = QueryDisplayConfig(flags, &count, result.paths.data(), &modes, result.modes.data(), nullptr);
        if (status == ERROR_INSUFFICIENT_BUFFER) continue;
        check_win32(status); result.paths.resize(count); result.modes.resize(modes); return result;
    }
    throw hresult_error(E_FAIL, L"The display configuration is changing. Try again.");
}
struct Monitor { std::wstring id, name; bool virtual_display = false; };
std::vector<Monitor> monitors() {
    std::map<std::wstring, Monitor> found;
    for (auto const& path : topology(QDC_ALL_PATHS).paths) {
        DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};
        source.header = { DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, sizeof(source), path.sourceInfo.adapterId, path.sourceInfo.id };
        if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS) continue;
        DISPLAYCONFIG_TARGET_DEVICE_NAME target{};
        target.header = { DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, sizeof(target), path.targetInfo.adapterId, path.targetInfo.id };
        if (DisplayConfigGetDeviceInfo(&target.header) != ERROR_SUCCESS || !path.targetInfo.targetAvailable) continue;
        auto technology = path.targetInfo.outputTechnology;
        Monitor entry{ source.viewGdiDeviceName, target.monitorFriendlyDeviceName,
            technology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INDIRECT_WIRED || technology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INDIRECT_VIRTUAL };
        if (entry.name.empty()) entry.name = entry.id;
        found.insert_or_assign(entry.id, entry);
    }
    std::vector<Monitor> result; for (auto const& [_, item] : found) result.push_back(item); return result;
}
struct SavedHeader { uint32_t magic = 0x4E434432, paths = 0, modes = 0, path_size = sizeof(DISPLAYCONFIG_PATH_INFO), mode_size = sizeof(DISPLAYCONFIG_MODE_INFO); };
using DevicePath = std::array<wchar_t, 128>;
DevicePath target_path(DISPLAYCONFIG_PATH_INFO const& path) {
    DISPLAYCONFIG_TARGET_DEVICE_NAME name{};
    name.header = { DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, sizeof(name), path.targetInfo.adapterId, path.targetInfo.id };
    check_win32(DisplayConfigGetDeviceInfo(&name.header));
    DevicePath result{}; memcpy(result.data(), name.monitorDevicePath, sizeof(result)); return result;
}
DEVMODEW current_mode(std::wstring const& device) {
    DEVMODEW mode{}; mode.dmSize = sizeof(mode);
    if (!EnumDisplaySettingsExW(device.c_str(), ENUM_CURRENT_SETTINGS, &mode, 0)) {
        mode = {}; mode.dmSize = sizeof(mode);
        require(EnumDisplaySettingsExW(device.c_str(), 0, &mode, 0) != FALSE, L"This display has no supported video modes.");
    }
    return mode;
}
void display_result(LONG value) {
    if (value == DISP_CHANGE_BADMODE) throw hresult_error(E_FAIL, L"This display does not support the requested size. Add the device resolution in Virtual Driver Control, or choose a supported fixed resolution.");
    require(value == DISP_CHANGE_SUCCESSFUL, L"Windows could not apply the display settings. Reconnect the monitor and try again.");
}
struct Audio {
    com_ptr<IAudioClient> client;
    com_ptr<IAudioRenderClient> render;
    UINT32 capacity = 0;
    Audio(wchar_t const* id) {
        com_ptr<IMMDeviceEnumerator> enumerator; com_ptr<IMMDevice> device;
        check_hresult(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(enumerator.put())));
        check_hresult(enumerator->GetDevice(id, device.put()));
        check_hresult(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, client.put_void()));
        WAVEFORMATEX format{};
        format.wFormatTag = WAVE_FORMAT_PCM; format.nChannels = 1; format.nSamplesPerSec = 48000;
        format.wBitsPerSample = 16; format.nBlockAlign = 2; format.nAvgBytesPerSec = 96000;
        check_hresult(client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            600000, 0, &format, nullptr));
        check_hresult(client->GetBufferSize(&capacity)); check_hresult(client->GetService(IID_PPV_ARGS(render.put())));
        check_hresult(client->Start());
    }
    ~Audio() { if (client) { client->Stop(); client->Reset(); } }
    void write(uint8_t const* bytes, int length) {
        require(length == 1920, L"Invalid microphone PCM frame.");
        UINT32 padding = 0; check_hresult(client->GetCurrentPadding(&padding));
        if (padding > capacity || capacity - padding < 960) return; // Bound audio latency; never queue a growing backlog.
        BYTE* target = nullptr; check_hresult(render->GetBuffer(960, &target));
        memcpy(target, bytes, 1920); check_hresult(render->ReleaseBuffer(960, 0));
    }
};
}

NC_EXPORT wchar_t const* nocturne_displays() {
    auto success = checked([] {
        JsonArray result;
        for (auto const& item : monitors()) {
            JsonObject row; row.SetNamedValue(L"id", JsonValue::CreateStringValue(item.id));
            row.SetNamedValue(L"name", JsonValue::CreateStringValue(item.name));
            row.SetNamedValue(L"isVirtual", JsonValue::CreateBooleanValue(item.virtual_display));
            DISPLAY_DEVICEW device{}; device.cb = sizeof(device); bool primary = false;
            for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &device, 0); ++i)
                if (item.id == device.DeviceName) { primary = (device.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) != 0; break; }
            row.SetNamedValue(L"isPrimary", JsonValue::CreateBooleanValue(primary));
            result.Append(row);
        }
        result_text = result.Stringify();
    });
    return success > 0 ? result_text.c_str() : nullptr;
}
NC_EXPORT int nocturne_display_save(wchar_t const* path) {
    return checked([&] {
        auto value = topology(QDC_ONLY_ACTIVE_PATHS);
        require(!value.paths.empty(), L"No active display configuration could be saved.");
        SavedHeader header; header.paths = static_cast<uint32_t>(value.paths.size()); header.modes = static_cast<uint32_t>(value.modes.size());
        std::vector<DevicePath> identities; for (auto const& item : value.paths) identities.push_back(target_path(item));
        auto temporary = std::filesystem::path(path); temporary += L".tmp";
        {
            std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
            file.write(reinterpret_cast<char*>(&header), sizeof(header));
            file.write(reinterpret_cast<char*>(value.paths.data()), value.paths.size() * sizeof(DISPLAYCONFIG_PATH_INFO));
            file.write(reinterpret_cast<char*>(value.modes.data()), value.modes.size() * sizeof(DISPLAYCONFIG_MODE_INFO));
            file.write(reinterpret_cast<char*>(identities.data()), identities.size() * sizeof(DevicePath));
            file.flush(); require(file.good(), L"The display recovery file could not be saved.");
        }
        if (!MoveFileExW(temporary.c_str(), path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) throw_last_error();
    });
}
NC_EXPORT int nocturne_display_prepare(wchar_t const* device, int width, int height, int fps, int disable_others) {
    return checked([&] {
        auto displays = monitors();
        auto selected = std::find_if(displays.begin(), displays.end(), [&](auto const& item) { return item.id == device; });
        require(selected != displays.end(), L"The selected monitor is unavailable. Refresh Displays in Nocturne Server.");
        require(!disable_others || selected->virtual_display, L"Physical monitors can only be disabled while a virtual monitor is active.");
        require(width >= 320 && width <= 4096 && height >= 320 && height <= 4096 && width % 2 == 0 && height % 2 == 0 && (fps == 30 || fps == 60 || fps == 120), L"Invalid display size.");
        auto target = current_mode(selected->id); auto previous = target.dmPosition;
        target.dmPelsWidth = width; target.dmPelsHeight = height; target.dmDisplayFrequency = fps;
        target.dmPosition = { 0, 0 }; target.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | DM_BITSPERPEL;
        display_result(ChangeDisplaySettingsExW(device, &target, nullptr, CDS_TEST, nullptr));
        display_result(ChangeDisplaySettingsExW(device, &target, nullptr, CDS_UPDATEREGISTRY | CDS_NORESET | CDS_SET_PRIMARY, nullptr));
        for (auto const& other : displays) {
            if (other.id == selected->id) continue;
            DISPLAY_DEVICEW info{}; info.cb = sizeof(info);
            bool active = false;
            for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &info, 0); ++i)
                if (other.id == info.DeviceName) { active = (info.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0; break; }
            if (!active) continue;
            auto mode = current_mode(other.id);
            if (disable_others && !other.virtual_display) { mode.dmPelsWidth = 0; mode.dmPelsHeight = 0; }
            else { mode.dmPosition.x -= previous.x; mode.dmPosition.y -= previous.y; }
            mode.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
            display_result(ChangeDisplaySettingsExW(other.id.c_str(), &mode, nullptr, CDS_UPDATEREGISTRY | CDS_NORESET, nullptr));
        }
        display_result(ChangeDisplaySettingsExW(nullptr, nullptr, nullptr, 0, nullptr));
    });
}
NC_EXPORT int nocturne_display_restore(wchar_t const* path) {
    return checked([&] {
        std::ifstream file(std::filesystem::path(path), std::ios::binary);
        require(file.good(), L"The display recovery file is missing.");
        SavedHeader header; file.read(reinterpret_cast<char*>(&header), sizeof(header));
        require(file.good() && header.magic == 0x4E434432 && header.paths > 0 && header.paths <= 512 && header.modes <= 4096 &&
            header.path_size == sizeof(DISPLAYCONFIG_PATH_INFO) && header.mode_size == sizeof(DISPLAYCONFIG_MODE_INFO), L"The display recovery file is invalid.");
        Topology value{ std::vector<DISPLAYCONFIG_PATH_INFO>(header.paths), std::vector<DISPLAYCONFIG_MODE_INFO>(header.modes) };
        file.read(reinterpret_cast<char*>(value.paths.data()), value.paths.size() * sizeof(DISPLAYCONFIG_PATH_INFO));
        file.read(reinterpret_cast<char*>(value.modes.data()), value.modes.size() * sizeof(DISPLAYCONFIG_MODE_INFO));
        std::vector<DevicePath> identities(header.paths);
        file.read(reinterpret_cast<char*>(identities.data()), identities.size() * sizeof(DevicePath));
        require(file.good() && file.peek() == EOF, L"The display recovery file is incomplete.");
        auto available = topology(QDC_ALL_PATHS);
        for (size_t index = 0; index < value.paths.size(); ++index) {
            auto& saved = value.paths[index];
            require(identities[index].back() == 0, L"The saved monitor identity is invalid.");
            for (auto const& current : available.paths) {
                if (!current.targetInfo.targetAvailable) continue;
                DevicePath current_identity{};
                try { current_identity = target_path(current); } catch (hresult_error const&) { continue; }
                if (_wcsicmp(identities[index].data(), current_identity.data()) != 0) continue;
                saved.sourceInfo.adapterId = current.sourceInfo.adapterId; saved.sourceInfo.id = current.sourceInfo.id;
                saved.targetInfo.adapterId = current.targetInfo.adapterId; saved.targetInfo.id = current.targetInfo.id;
                if (saved.sourceInfo.modeInfoIdx < value.modes.size()) {
                    auto& mode = value.modes[saved.sourceInfo.modeInfoIdx]; mode.adapterId = current.sourceInfo.adapterId; mode.id = current.sourceInfo.id;
                }
                if (saved.targetInfo.modeInfoIdx < value.modes.size()) {
                    auto& mode = value.modes[saved.targetInfo.modeInfoIdx]; mode.adapterId = current.targetInfo.adapterId; mode.id = current.targetInfo.id;
                }
                break;
            }
        }
        auto status = SetDisplayConfig(header.paths, value.paths.data(), header.modes, value.modes.data(), SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE);
        // Hardware may have been replaced while the app was stopped. Let Windows
        // recover the currently present monitors rather than retaining a black screen.
        if (status != ERROR_SUCCESS) status = SetDisplayConfig(0, nullptr, 0, nullptr, SDC_APPLY | SDC_TOPOLOGY_EXTEND);
        check_win32(status);
    });
}
NC_EXPORT wchar_t const* nocturne_audio_devices() {
    auto success = checked([] {
        com_ptr<IMMDeviceEnumerator> enumerator; com_ptr<IMMDeviceCollection> collection;
        check_hresult(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(enumerator.put())));
        check_hresult(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, collection.put()));
        UINT count = 0; check_hresult(collection->GetCount(&count)); JsonArray result;
        for (UINT i = 0; i < count; ++i) {
            com_ptr<IMMDevice> device; com_ptr<IPropertyStore> properties;
            check_hresult(collection->Item(i, device.put()));
            LPWSTR id = nullptr; check_hresult(device->GetId(&id));
            std::wstring identifier = id; CoTaskMemFree(id);
            check_hresult(device->OpenPropertyStore(STGM_READ, properties.put()));
            PROPVARIANT name{}; PropVariantInit(&name); check_hresult(properties->GetValue(PKEY_Device_FriendlyName, &name));
            JsonObject item; item.SetNamedValue(L"id", JsonValue::CreateStringValue(identifier));
            item.SetNamedValue(L"name", JsonValue::CreateStringValue(name.vt == VT_LPWSTR ? name.pwszVal : identifier.c_str()));
            PropVariantClear(&name); result.Append(item);
        }
        result_text = result.Stringify();
    });
    return success > 0 ? result_text.c_str() : nullptr;
}
NC_EXPORT void* nocturne_audio_open(wchar_t const* device) { Audio* result = nullptr; checked([&] { result = new Audio(device); }); return result; }
NC_EXPORT int nocturne_audio_write(void* handle, uint8_t const* bytes, int length) { return checked([&] { static_cast<Audio*>(handle)->write(bytes, length); }); }
NC_EXPORT void nocturne_audio_close(void* handle) { checked([&] { delete static_cast<Audio*>(handle); }); }
