#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <charconv>
#include <atomic>
#include <chrono>
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <string_view>
#include <stdexcept>
using namespace std::literals;

static NSDictionary *session;
static CGDirectDisplayID mainDisplay = 1;
static bool mainActive = true, mainPlaceholder = false, displayAsleep = false;
static uint32_t testDisplayActive(CGDirectDisplayID display) { return display == mainDisplay ? mainActive : true; }
static uint32_t testDisplayModel(CGDirectDisplayID display) { return display == mainDisplay && mainPlaceholder ? 0x76697274 : 1; }
[[maybe_unused]] static uint32_t testDisplayAsleep(CGDirectDisplayID) { return displayAsleep; }
static CFDictionaryRef testSessionSnapshot() { return (CFDictionaryRef)CFRetain((__bridge CFDictionaryRef)session); }
static CGDirectDisplayID testMainDisplay() { return mainDisplay; }
#define CGSessionCopyCurrentDictionary testSessionSnapshot
#define CGMainDisplayID testMainDisplay
#define CGDisplayIsActive testDisplayActive
#define CGDisplayModelNumber testDisplayModel
#define CGDisplayIsAsleep testDisplayAsleep
#include "CaptureDisplay.h"

static std::chrono::steady_clock::time_point testNow {};
static std::function<void(int)> beforeFrame;
static bool deliverFrames = true;
static int samplesBeforeSilence = 0;
static int waits, stops;
static std::function<void(int)> beforeWait;
// Replace the OS wait/clock boundary. An unsignalled infinite wait is precisely
// the connection hang; fail immediately instead of wedging the test process.
static long testWait(dispatch_semaphore_t signal, dispatch_time_t deadline) {
    if (dispatch_semaphore_wait(signal, DISPATCH_TIME_NOW) == 0) return 0;
    if (deadline == DISPATCH_TIME_FOREVER) throw std::runtime_error("capture waits forever when no screen samples arrive");
    if (++waits > 32) throw std::runtime_error("capture never finishes without screen samples");
    testNow += std::chrono::milliseconds(250);
    if (beforeWait) beforeWait(waits);
    return 1;
}
#define dispatch_semaphore_wait testWait
namespace platf { static bool is_screen_capture_allowed() { return true; } }
typedef bool (^FrameCallbackBlock)(CMSampleBufferRef);

// Represent sample delivery AND periods with no callbacks from AVFoundation.
@interface TestVideo : NSObject
- (dispatch_semaphore_t)capture:(FrameCallbackBlock)callback;
- (void)nocturneStopCapture:(dispatch_semaphore_t)signal;
@end
@implementation TestVideo
- (dispatch_semaphore_t)capture:(FrameCallbackBlock)callback {
    dispatch_semaphore_t signal = dispatch_semaphore_create(0);
    for (int frame = 0; frame < 4; frame++) {
        if (!deliverFrames && frame >= samplesBeforeSilence) return signal;
        testNow += std::chrono::milliseconds(300);
        if (beforeFrame) beforeFrame(frame);
        if (!callback(nullptr)) { dispatch_semaphore_signal(signal); return signal; }
    }
    std::abort(); // A test must provide a bounded stop/reinitialization condition.
}
- (void)nocturneStopCapture:(dispatch_semaphore_t)signal { stops++; dispatch_semaphore_signal(signal); }
@end

struct av_sample_buf_t {
    CMSampleBufferRef buf;
    explicit av_sample_buf_t(CMSampleBufferRef sample): buf(sample) {}
};
struct av_pixel_buf_t {
    CVPixelBufferRef buf = nullptr;
    explicit av_pixel_buf_t(CMSampleBufferRef) {}
    uint8_t *data() { return nullptr; }
};
struct img_t {
    uint8_t *data = nullptr;
    int width = 0, height = 0, row_pitch = 0, pixel_pitch = 0;
};
struct av_img_t: img_t {
    std::shared_ptr<av_sample_buf_t> sample_buffer;
    std::shared_ptr<av_pixel_buf_t> pixel_buffer;
};
struct temp_retain_av_img_t {
    temp_retain_av_img_t(std::shared_ptr<av_sample_buf_t>, std::shared_ptr<av_pixel_buf_t>, uint8_t *) {}
};
#define CVPixelBufferGetWidth(buffer) 1920
#define CVPixelBufferGetHeight(buffer) 1080
#define CVPixelBufferGetBytesPerRow(buffer) (1920 * 4)
#define BOOST_LOG(level) std::cerr
enum class capture_e { ok, reinit, capture_error };
using push_captured_image_cb_t = std::function<bool(std::shared_ptr<img_t>, bool)>;
using pull_free_image_cb_t = std::function<bool(std::shared_ptr<img_t> &)>;
struct display_t {
    virtual capture_e capture(const push_captured_image_cb_t &, const pull_free_image_cb_t &, bool *) = 0;
    virtual int dummy_img(img_t *) = 0;
    virtual ~display_t() = default;
};
struct Capture: display_t {
    TestVideo *av_capture = [TestVideo new];
    CGDirectDisplayID display_id = 0, requested_display_id = 0;
#include "capture.inc"
#include "probe.inc"
};
#include "parser.inc"

static std::shared_ptr<Capture> configure(const std::string &display_name) {
    auto display = std::make_shared<Capture>();
#include "selection.inc"
    return display;
}
static void setLocked(bool locked, bool onConsole = true, bool loginDone = true) {
    session = @{
        (__bridge NSString *)kCGSessionOnConsoleKey: @(onConsole),
        (__bridge NSString *)kCGSessionLoginDoneKey: @(loginDone),
        @"CGSSessionScreenIsLocked": @(locked)
    };
}
static int failures;
static void check(bool condition, const char *message) {
    std::cout << (condition ? "PASS: " : "FAIL: ") << message << '\n';
    if (!condition) failures++;
}
static capture_e run(const std::shared_ptr<Capture> &display, int &frames, int stopAfter = 2) {
    bool cursor = true;
    return display->capture([&](std::shared_ptr<img_t>, bool captured) {
        return !captured || ++frames < stopAfter;
    }, [](std::shared_ptr<img_t> &image) {
        image = std::make_shared<av_img_t>(); return true;
    }, &cursor);
}
int main() { @autoreleasepool {
    setLocked(false);
    auto display = configure("27");
    check(display->display_id == 27, "an unlocked stream captures its selected virtual display");
    int frames = 0;
    beforeFrame = [](int frame) { if (frame == 1) setLocked(true); };
    auto status = run(display, frames);
    check(status == capture_e::reinit && frames == 1,
        "locking an active stream requests capture reinitialization before forwarding another frame");

    beforeFrame = nullptr;
    display = configure("27");
    check(display->display_id == mainDisplay, "a connection made while locked captures the password screen");
    frames = 0;
    check(run(display, frames) == capture_e::ok && frames == 2,
        "a static lock screen keeps streaming without repeatedly reinitializing");

    frames = 0;
    beforeFrame = [](int frame) { if (frame == 1) setLocked(false); };
    status = run(display, frames);
    check(status == capture_e::reinit && frames == 1,
        "unlocking returns through capture reinitialization without ending the client session");
    display = configure("27");
    check(display->display_id == 27, "unlock restores the original virtual display selection");

    setLocked(true);
    display = configure("33"); // An explicitly selected secondary physical display.
    check(display->display_id == mainDisplay, "secondary physical displays also show the main login screen");
    frames = 0;
    beforeFrame = [](int frame) { if (frame == 1) mainDisplay = 2; };
    status = run(display, frames);
    check(status == capture_e::reinit && frames == 1, "a main-display change while locked refreshes capture and input geometry");

    beforeFrame = nullptr;
    mainDisplay = 27;
    display = configure("27");
    frames = 0;
    check(run(display, frames) == capture_e::ok && frames == 2,
        "a headless Mac whose virtual display is already main does not restart capture");
    mainDisplay = 0;
    check(configure("27")->display_id == 27, "a missing main display never replaces a usable capture target with zero");
    mainDisplay = 1;
    mainActive = false;
    check(configure("27")->display_id == 27, "an inactive main display left by an unplugged monitor cannot replace the virtual framebuffer");
    mainActive = true; mainPlaceholder = true;
    check(configure("27")->display_id == 27, "WindowServer's headless placeholder cannot replace the virtual framebuffer");
    mainPlaceholder = false;
    setLocked(true, false);
    check(configure("27")->display_id == 27, "an inactive user session cannot redirect capture to another user's main display");
    setLocked(true, true, false);
    check(configure("27")->display_id == 27, "the pre-login screen is outside locked-desktop support");

    setLocked(true);
    mainDisplay = 27;
    display = configure("27");
    deliverFrames = false;
    waits = stops = 0;
    av_img_t image;
    try {
        check(display->dummy_img(&image) != 0 && stops == 1,
            "a locked headless display producing no samples fails encoder probing and retires its output");
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        check(false, "a locked headless display producing no samples must not hang encoder probing");
    }

    auto withoutSamples = [&](const char *message, const std::function<void()> &test) {
        waits = stops = 0; beforeWait = nullptr; testNow = {};
        try { test(); } catch (const std::exception &error) { std::cerr << error.what() << '\n'; check(false, message); }
    };
    withoutSamples("capture must notice lock changes without frame callbacks", [&] {
        setLocked(false); display = configure("27");
        beforeWait = [](int) { setLocked(true); };
        frames = 0;
        check(run(display, frames) == capture_e::reinit && frames == 0 && stops == 1,
            "locking a headless stream reinitializes even when main and virtual display IDs stay equal and no frames arrive");
    });
    withoutSamples("capture must notice display changes without frame callbacks", [&] {
        setLocked(true); mainDisplay = 1; display = configure("27");
        beforeWait = [](int) { mainDisplay = 2; };
        frames = 0;
        check(run(display, frames) == capture_e::reinit && frames == 0 && stops == 1,
            "a changed login display reinitializes without waiting for a sample from the old display");
    });
    withoutSamples("capture must recover from display sleep without frame callbacks", [&] {
        display = configure("27"); displayAsleep = true;
        beforeWait = [](int count) { if (count == 2) displayAsleep = false; };
        frames = 0;
        check(run(display, frames) == capture_e::reinit && stops == 1,
            "a display that wakes without resuming samples reinitializes capture");
    });
    withoutSamples("a display that stays asleep must not wedge reconnects", [&] {
        displayAsleep = true; display = configure("27"); frames = 0;
        check(run(display, frames) == capture_e::capture_error && stops == 1,
            "a display that stays asleep retires capture instead of hanging or repeatedly waking the monitor");
        displayAsleep = false;
    });
    withoutSamples("a blank capture must have a bounded startup", [&] {
        display = configure("27"); frames = 0;
        check(run(display, frames) == capture_e::capture_error && stops == 1,
            "a capture that never delivers its first sample fails within a bounded startup interval");
    });
    withoutSamples("stream shutdown must not require a video sample", [&] {
        display = configure("27"); bool cursor = true;
        auto status = display->capture([](std::shared_ptr<img_t>, bool) { return false; },
            [](std::shared_ptr<img_t> &) { return true; }, &cursor);
        check(status == capture_e::ok && stops == 1, "disconnecting a stream with no samples retires capture promptly");
    });
    withoutSamples("a static desktop must not be mistaken for a stalled capture", [&] {
        samplesBeforeSilence = 1;
        display = configure("27"); bool cursor = true, disconnect = false;
        beforeWait = [&](int count) { if (count == 24) disconnect = true; };
        frames = 0;
        auto status = display->capture([&](std::shared_ptr<img_t>, bool captured) {
            if (captured) ++frames;
            return !disconnect;
        }, [](std::shared_ptr<img_t> &image) { image = std::make_shared<av_img_t>(); return true; }, &cursor);
        check(status == capture_e::ok && frames == 1 && waits == 24 && stops == 1,
            "after its first sample, an unchanged desktop survives silence beyond the startup timeout and still disconnects");
    });
    return failures ? 1 : 0;
} }
