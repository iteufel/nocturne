#include <algorithm>
#include <chrono>
#include <iostream>
#include <string>
#include <vector>
#include <memory>
#include <set>
#include "CaptureWake.h"
using namespace std::literals;

namespace display_device {
    struct EnumeratedDevice { bool m_info; };
    using Device = EnumeratedDevice;
    static std::vector<Device> devices;
    static int wakes;
    static bool can_wake = true;
    static bool rendering_awake = true;
    static auto enumerate_devices() { return devices; }
    static bool wake_display(const std::string &, std::chrono::seconds) {
        ++wakes;
        if (can_wake) devices = {{true}};
        return can_wake;
    }
}
static bool local_wake_succeeds = true;
static int local_wake_requests, wake_releases;
static IOPMAssertionID next_assertion;
static std::set<IOPMAssertionID> assertions;
IOReturn IOPMAssertionDeclareUserActivity(CFStringRef, IOPMUserActiveType type, IOPMAssertionID *id) {
    if (type == kIOPMUserActiveLocal) ++local_wake_requests;
    if (!local_wake_succeeds) return -1;
    *id = ++next_assertion; assertions.insert(*id);
    if (type == kIOPMUserActiveLocal) display_device::rendering_awake = true;
    return kIOReturnSuccess;
}
IOReturn IOPMAssertionRelease(IOPMAssertionID id) {
    ++wake_releases;
    return assertions.erase(id) == 1 ? kIOReturnSuccess : -1;
}
#define BOOST_LOG(level) std::cerr
// Choose the policy after system includes so this portable replay does not
// change the compiler's actual platform headers or call any real OS APIs.
#ifdef NOCTURNE_TEST_WINDOWS
#define _WIN32 1
#else
#undef _WIN32
#endif
#include "probe-gate.inc"

static int start_video() {
#include "probe-entry.inc"
    const std::string display_name = "27";
#include "display-wake.inc"
    // Substitute only the hardware probe result, after the production wake path.
    const auto devices = display_device::enumerate_devices();
    return display_device::rendering_awake && std::any_of(devices.begin(), devices.end(), [](auto device) { return device.m_info; }) ? 0 : -1;
}

int main() {
    int failures = 0;
    auto check = [&](bool condition, const char *message) {
        std::cout << (condition ? "PASS: " : "FAIL: ") << message << '\n';
        if (!condition) ++failures;
    };
    display_device::devices = {{false}};
#ifdef NOCTURNE_TEST_WINDOWS
    check(start_video() != 0 && display_device::wakes == 0,
        "Windows preserves the upstream guard against probing inactive displays");
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
#ifndef NOCTURNE_TEST_WINDOWS
    display_device::devices = {{true}}; display_device::can_wake = true;
    display_device::rendering_awake = false; local_wake_requests = 0; wake_releases = 0;
    check(start_video() == 0 && local_wake_requests == 1,
        "an active virtual display still wakes sleeping WindowServer rendering before probing");
    check(assertions.empty() && wake_releases == 1,
        "encoder discovery releases its explicit wake assertion after the probe");
    display_device::rendering_awake = false; local_wake_succeeds = false;
    check(start_video() != 0 && assertions.empty() && wake_releases == 1,
        "a failed power request does not claim that a sleeping active display supplies frames");
    local_wake_succeeds = true; display_device::rendering_awake = true;
    struct Capture { std::shared_ptr<nocturne::CaptureWake> capture_wake; };
    auto display = std::make_shared<Capture>();
    auto capture_wake = std::make_shared<nocturne::CaptureWake>();
#include "capture-wake-handoff.inc"
    capture_wake.reset();
    check(wake_backend_count == 2 && !assertions.empty(), "both capture backends retain the wake assertion beyond factory return");
    display.reset();
    check(assertions.empty(), "capture teardown releases the wake assertion");
#endif
    return failures ? 1 : 0;
}
