#include <cassert>
#include <chrono>
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
using CMSampleBufferRef = void *;
using namespace std::literals;
static unsigned waits;
static bool allowed = true;
static unsigned selected = 27;
static std::chrono::steady_clock::time_point testNow {};
namespace platf { bool is_screen_capture_allowed() { return allowed; } }
namespace nocturne { unsigned captureDisplay(unsigned) { return selected; } }
struct av_sample_buf_t { void *buf; explicit av_sample_buf_t(void *value): buf(value) {} };
struct av_pixel_buf_t {
    void *buf = nullptr;
    explicit av_pixel_buf_t(void *) {}
    unsigned char *data() { return nullptr; }
};
struct img_t { unsigned char *data = nullptr; int width = 0, height = 0, row_pitch = 0, pixel_pitch = 0; };
struct av_img_t: img_t {
    std::shared_ptr<av_sample_buf_t> sample_buffer;
    std::shared_ptr<av_pixel_buf_t> pixel_buffer;
};
struct temp_retain_av_img_t {
    temp_retain_av_img_t(std::shared_ptr<av_sample_buf_t>, std::shared_ptr<av_pixel_buf_t>, unsigned char *) {}
};
#define CVPixelBufferGetWidth(buffer) 1920
#define CVPixelBufferGetHeight(buffer) 1080
#define CVPixelBufferGetBytesPerRow(buffer) (1920 * 4)
#define DISPATCH_TIME_FOREVER 0
static void dispatch_semaphore_wait(int *signal, int) {
    if (!signal) throw std::runtime_error("AVFoundation rejection reached dispatch_semaphore_wait(nil)");
    assert(*signal == 1); ++waits;
}
struct TestVideo {
    bool reject = false;
    int signal = 0;
    std::function<void(int)> beforeFrame;
    template<class Callback> int *capture(Callback callback) {
        if (reject) return nullptr;
        signal = 0;
        for (int frame = 0; frame < 4; ++frame) {
            testNow += std::chrono::milliseconds(300);
            if (beforeFrame) beforeFrame(frame);
            if (!callback(nullptr)) { signal = 1; return &signal; }
        }
        throw std::runtime_error("Capture did not stop within the test's frame budget");
    }
};
enum class capture_e { ok, reinit, capture_error };
using push_captured_image_cb_t = std::function<bool(std::shared_ptr<img_t>, bool)>;
using pull_free_image_cb_t = std::function<bool(std::shared_ptr<img_t> &)>;
struct Display {
    virtual capture_e capture(const push_captured_image_cb_t &, const pull_free_image_cb_t &, bool *) = 0;
    virtual int dummy_img(img_t *) = 0;
    virtual ~Display() = default;
};
struct Capture: Display {
    TestVideo *av_capture;
    unsigned requested_display_id = 27, display_id = 27;
#include "capture.inc"
#include "probe.inc"
};
int main() {
    TestVideo video;
    Capture display; display.av_capture = &video;
    unsigned frames = 0;
    auto push = [&](std::shared_ptr<img_t>, bool) { return ++frames < 2; };
    auto pull = [](std::shared_ptr<img_t> &image) { image = std::make_shared<av_img_t>(); return true; };
    av_img_t image;
    bool cursor = true;
    video.reject = true;
    assert(display.capture(push, pull, &cursor) == capture_e::capture_error);
    assert(display.dummy_img(&image) != 0);
    assert(waits == 0);
    std::cout << "PASS: rejected capture and encoder probe never wait on a nil semaphore\n";
    video.reject = false;
    for (unsigned attempt = 0; attempt < 64; ++attempt) {
        frames = 0;
        assert(display.capture(push, pull, &cursor) == capture_e::ok && frames == 2);
        assert(display.dummy_img(&image) == 0);
    }
    assert(waits == 128);
    std::cout << "PASS: capture and encoder probing recover across 64 reconnects\n";
    frames = 0;
    video.beforeFrame = [](int frame) { if (frame == 1) selected = 1; };
    assert(display.capture(push, pull, &cursor) == capture_e::reinit && frames == 1);
    allowed = false;
    const auto before = waits;
    assert(display.dummy_img(&image) != 0 && waits == before);
    std::cout << "PASS: display transitions reinitialize capture and denied permission fails promptly\n";
}
