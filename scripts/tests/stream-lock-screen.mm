#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <charconv>
#include <chrono>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <string_view>
using namespace std::literals;

static NSDictionary *session;
static CGDirectDisplayID mainDisplay = 1;
static CFDictionaryRef testSessionSnapshot() { return (CFDictionaryRef)CFRetain((__bridge CFDictionaryRef)session); }
static CGDirectDisplayID testMainDisplay() { return mainDisplay; }
#define CGSessionCopyCurrentDictionary testSessionSnapshot
#define CGMainDisplayID testMainDisplay
#include "CaptureDisplay.h"

static std::chrono::steady_clock::time_point testNow {};
static std::function<void(int)> beforeFrame;
typedef bool (^FrameCallbackBlock)(CMSampleBufferRef);

// The real AVCaptureScreenInput supplies frames even on an unchanged desktop.
// Its asynchronous completion is represented by the same semaphore contract.
@interface TestVideo : NSObject
- (dispatch_semaphore_t)capture:(FrameCallbackBlock)callback;
@end
@implementation TestVideo
- (dispatch_semaphore_t)capture:(FrameCallbackBlock)callback {
    dispatch_semaphore_t signal = dispatch_semaphore_create(0);
    for (int frame = 0; frame < 4; frame++) {
        testNow += std::chrono::milliseconds(300);
        if (beforeFrame) beforeFrame(frame);
        if (!callback(nullptr)) { dispatch_semaphore_signal(signal); return signal; }
    }
    std::abort(); // A test must provide a bounded stop/reinitialization condition.
}
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
    virtual ~display_t() = default;
};
struct Capture: display_t {
    TestVideo *av_capture = [TestVideo new];
    CGDirectDisplayID display_id = 0, requested_display_id = 0;
#include "capture.inc"
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
    return display->capture([&](std::shared_ptr<img_t>, bool) {
        return ++frames < stopAfter;
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
    setLocked(true, false);
    check(configure("27")->display_id == 27, "an inactive user session cannot redirect capture to another user's main display");
    setLocked(true, true, false);
    check(configure("27")->display_id == 27, "the pre-login screen is outside locked-desktop support");
    return failures ? 1 : 0;
} }
