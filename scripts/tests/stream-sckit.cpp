#include <CoreMedia/CoreMedia.h>
#include <atomic>
#include <chrono>
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <utility>
using namespace std::literals;

enum class capture_e { ok, reinit, capture_error };
struct img_t {};
struct display_t {
    using push_captured_image_cb_t = std::function<bool(std::shared_ptr<img_t>, bool)>;
    using pull_free_image_cb_t = std::function<bool(std::shared_ptr<img_t> &)>;
    virtual capture_e capture(const push_captured_image_cb_t &, const pull_free_image_cb_t &, bool *) = 0;
    virtual ~display_t() = default;
};
using push_captured_image_cb_t = display_t::push_captured_image_cb_t;
using pull_free_image_cb_t = display_t::pull_free_image_cb_t;
namespace platf { using ::capture_e; using ::img_t; using ::display_t; }
namespace util {
    template<class F> struct scope_exit_t { F action; ~scope_exit_t() { action(); } };
    template<class F> auto fail_guard(F action) { return scope_exit_t<F>{std::move(action)}; }
}
#include "sc-loop-header.inc"
#include "sc-loop.inc"
namespace sckit = platf::sckit;

static bool locked, startAllowed, stopped, keepStreaming;
static unsigned selected = 27, starts, stops, waits, samples;
static std::chrono::steady_clock::time_point testNow;
static std::function<void(unsigned)> beforeWait;
namespace nocturne {
    static bool captureSessionLocked() { return locked; }
    static unsigned captureDisplay(unsigned) { return selected; }
}
// Replace only the SCStream/OS frame boundary. The backend policy, capture loop,
// interruption checks and forwarding callback below are generated production code.
struct sc_frame_source_t: sckit::frame_source_t {
    explicit sc_frame_source_t(void *) {}
    bool start() override { ++starts; return startAllowed; }
    void wait_frame(std::chrono::nanoseconds duration) override {
        testNow += duration;
        if (++waits > 1024) throw std::runtime_error("ScreenCaptureKit never retires a silent stream");
        if (beforeWait) beforeWait(waits);
    }
    bool stopped() const override { return ::stopped; }
    CMSampleBufferRef copy_latest_sample_buffer() override {
        // A retained CF object models ownership without synthesizing pixel data.
        return waits <= samples ? reinterpret_cast<CMSampleBufferRef>(const_cast<void *>(CFRetain(CFSTR("sample")))) : nullptr;
    }
    void stop() override { ++stops; }
};
static bool process_frame(CMSampleBufferRef, img_t *) { return true; }
static constexpr auto SCKIT_FRAME_POLL_INTERVAL = std::chrono::nanoseconds{1s} / 60;
#define BOOST_LOG(level) std::cerr
struct Capture: display_t {
    unsigned display_id = 27, requested_display_id = 27;
    void *sc_capture = nullptr;
#include "sc-capture.inc"
};

static int failures;
static void check(bool value, const char *message) {
    std::cout << (value ? "PASS: " : "FAIL: ") << message << '\n';
    if (!value) ++failures;
}
static void reset() {
    locked = stopped = false; startAllowed = keepStreaming = true;
    selected = 27; starts = stops = waits = 0; samples = 1024;
    testNow = {}; beforeWait = nullptr;
}
static capture_e run(unsigned &frames) {
    Capture display; bool cursor = true;
    return display.capture([&](std::shared_ptr<img_t>, bool captured) {
        if (captured) ++frames;
        return keepStreaming && frames < 2;
    }, [](std::shared_ptr<img_t> &image) { image = std::make_shared<img_t>(); return true; }, &cursor);
}
int main() {
    auto scenario = [](const char *name, const std::function<void(unsigned &)> &test) {
        reset(); unsigned frames = 0;
        try { test(frames); }
        catch (const std::exception &error) { std::cerr << error.what() << '\n'; check(false, name); }
    };
    scenario("normal ScreenCaptureKit capture", [](unsigned &frames) {
        check(run(frames) == capture_e::ok && frames == 2 && starts == 1 && stops == 1,
            "an unlocked ScreenCaptureKit stream forwards frames and stops exactly once");
    });
    scenario("lock before capture starts", [](unsigned &frames) {
        locked = true;
        check(run(frames) == capture_e::reinit && starts == 0,
            "a lock racing ScreenCaptureKit startup rebuilds on AVFoundation before starting SCStream");
    });
    scenario("lock with no frames", [](unsigned &frames) {
        samples = 0; beforeWait = [](unsigned) { locked = true; };
        check(run(frames) == capture_e::reinit && frames == 0 && stops == 1,
            "a silent ScreenCaptureKit stream notices locking even when the display ID stays unchanged");
    });
    scenario("display changes with no frames", [](unsigned &frames) {
        samples = 0; beforeWait = [](unsigned) { selected = 28; };
        check(run(frames) == capture_e::reinit && frames == 0 && stops == 1,
            "a silent ScreenCaptureKit stream retires its old display before forwarding frames");
    });
    scenario("disconnect with no frames", [](unsigned &frames) {
        samples = 0; keepStreaming = false;
        check(run(frames) == capture_e::ok && waits == 1 && stops == 1,
            "ScreenCaptureKit disconnect does not require a video sample");
    });
    scenario("unchanged desktop", [](unsigned &frames) {
        samples = 1; beforeWait = [](unsigned count) { if (count == 601) keepStreaming = false; };
        check(run(frames) == capture_e::ok && frames == 1 && waits == 601 && stops == 1,
            "a static ScreenCaptureKit desktop remains connected beyond its initial-frame deadline");
    });
    scenario("unexpected stream stop", [](unsigned &frames) {
        beforeWait = [](unsigned) { stopped = true; };
        check(run(frames) == capture_e::reinit && stops == 1,
            "upstream ScreenCaptureKit failure still reinitializes and releases its source");
    });
    scenario("no initial frame", [](unsigned &frames) {
        samples = 0;
        check(run(frames) == capture_e::reinit && frames == 0 && stops == 1 && waits <= 302
            && sckit::backend_policy().stream_start_failed(),
            "ScreenCaptureKit with no initial frame falls back to AVFoundation within five seconds");
    });
    scenario("native start failure", [](unsigned &frames) {
        startAllowed = false;
        check(run(frames) == capture_e::reinit && starts == 1 && stops == 0
            && !sckit::backend_policy().prefer_sckit(true),
            "upstream native start failure preserves its AVFoundation fallback policy");
    });
    return failures ? 1 : 0;
}
