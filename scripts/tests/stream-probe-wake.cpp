#include <algorithm>
#include <chrono>
#include <iostream>
#include <string>
#include <vector>
using namespace std::literals;

namespace display_device {
    struct Device { bool m_info; };
    static std::vector<Device> devices;
    static int wakes;
    static bool can_wake = true;
    static auto enumerate_devices() { return devices; }
    static bool wake_display(const std::string &, std::chrono::seconds) {
        ++wakes;
        if (can_wake) devices = {{true}};
        return can_wake;
    }
}
#define BOOST_LOG(level) std::cerr
// Choose the policy after system includes so this portable replay does not
// change the compiler's actual platform headers or call any real OS APIs.
#ifdef NOCTURNE_TEST_OTHER_PLATFORM
#undef __APPLE__
#elif !defined(__APPLE__)
#define __APPLE__ 1
#endif
#include "probe-gate.inc"

static int start_video() {
#include "probe-entry.inc"
    const std::string display_name = "27";
#include "display-wake.inc"
    // Substitute only the hardware probe result, after the production wake path.
    const auto devices = display_device::enumerate_devices();
    return std::any_of(devices.begin(), devices.end(), [](auto device) { return device.m_info; }) ? 0 : -1;
}

int main() {
    int failures = 0;
    auto check = [&](bool condition, const char *message) {
        std::cout << (condition ? "PASS: " : "FAIL: ") << message << '\n';
        if (!condition) ++failures;
    };
    display_device::devices = {{false}};
#ifdef NOCTURNE_TEST_OTHER_PLATFORM
    check(start_video() != 0 && display_device::wakes == 0,
        "other platforms preserve the upstream guard against probing inactive displays");
#else
    check(start_video() == 0 && display_device::wakes == 1,
        "an online Mac with only an inactive sleeping display reaches wake-up before encoder probing");
#endif
    display_device::devices = {{true}}; display_device::wakes = 0;
    check(start_video() == 0 && display_device::wakes == 1,
        "an awake display continues through normal video startup");
    display_device::devices.clear(); display_device::wakes = 0;
    check(start_video() == 0 && display_device::wakes == 1,
        "an empty display catalog still reaches the platform wake path");
    display_device::devices = {{false}}; display_device::wakes = 0; display_device::can_wake = false;
    check(start_video() != 0,
        "allowing a wake attempt does not pretend an unavailable display passed its hardware probe");
    return failures ? 1 : 0;
}
