#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "NocturneAVVideo.h"
#include "CaptureDisplay.h"
#include "CaptureWake.h"
#include <atomic>
#include <algorithm>
#include <memory>
#include <cstdio>
#include <cstring>

static std::atomic<int> samples {0};
static std::atomic<int> width {0}, height {0};
static std::atomic<int> lumaMin {255}, lumaMax {0};
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) return 64;
    if (strcmp(argv[1], "--require-locked") == 0) {
      const bool locked = nocturne::captureSessionLocked();
      const bool authorized = CGPreflightScreenCaptureAccess();
      printf("Mac session locked: %d; screen capture authorized: %d\n", locked, authorized);
      return locked && authorized ? 0 : 77;
    }
    const CGDirectDisplayID requested = static_cast<CGDirectDisplayID>(strtoul(argv[1], nullptr, 10));
    const bool raw = argc > 3 && strcmp(argv[3], "raw") == 0;
    const bool bgra = argc > 2 && strcmp(argv[2], "bgra") == 0;
    auto capture_wake = argc > 4 && strcmp(argv[4], "wake") == 0 ? std::make_shared<nocturne::CaptureWake>() : nullptr;
    const auto selected = raw ? requested : nocturne::captureDisplay(requested);
    const bool authorized = CGPreflightScreenCaptureAccess();
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(selected);
    printf("CAPTURE authorized=%d locked=%d requested=%u main=%u selected=%u active=%d asleep=%d mode=%zux%zu format=%s\n",
      authorized, nocturne::captureSessionLocked(), requested, CGMainDisplayID(), selected,
      CGDisplayIsActive(selected), CGDisplayIsAsleep(selected),
      mode ? CGDisplayModeGetPixelWidth(mode) : 0, mode ? CGDisplayModeGetPixelHeight(mode) : 0,
      bgra ? "BGRA" : "NV12");
    if (mode) CGDisplayModeRelease(mode);
    fflush(stdout);
    printf("MAIN vendor=%u model=%u builtin=%d\n", CGDisplayVendorNumber(CGMainDisplayID()), CGDisplayModelNumber(CGMainDisplayID()), CGDisplayIsBuiltin(CGMainDisplayID()));
    if (!authorized) { puts("FAIL: capture permission unavailable for the native probe"); return 77; }
    AVVideo *capture = [[AVVideo alloc] initWithDisplay:selected frameRate:60];
    if (!capture) { puts("FAIL: AVFoundation capture initialization returned nil"); return 1; }
    [capture setFrameWidth:1280 frameHeight:720];
    capture.pixelFormat = bgra ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    auto signal = [capture capture:^bool(CMSampleBufferRef sample) {
      auto pixel = CMSampleBufferGetImageBuffer(sample);
      if (!CMSampleBufferIsValid(sample) || !pixel) return true;
      width.store(static_cast<int>(CVPixelBufferGetWidth(pixel)));
      height.store(static_cast<int>(CVPixelBufferGetHeight(pixel)));
      if (CVPixelBufferLockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
        const bool planar = CVPixelBufferIsPlanar(pixel);
        const auto *base = static_cast<const unsigned char *>(planar ? CVPixelBufferGetBaseAddressOfPlane(pixel, 0) : CVPixelBufferGetBaseAddress(pixel));
        const auto stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) : CVPixelBufferGetBytesPerRow(pixel);
        int low = 255, high = 0;
        for (int y = 0; base && y < height.load(); y += std::max(1, height.load() / 32)) {
          for (int x = 0; x < width.load(); x += std::max(1, width.load() / 64)) {
            const auto *p = base + y * stride + (planar ? x : 4 * x);
            const int value = planar ? p[0] : (int(p[0]) + p[1] + p[2]) / 3;
            low = std::min(low, value); high = std::max(high, value);
          }
        }
        lumaMin.store(low); lumaMax.store(high);
        CVPixelBufferUnlockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
      }
      return samples.fetch_add(1) + 1 < 3;
    }];
    if (!signal) { puts("FAIL: AVFoundation rejected the configured video output"); [capture release]; return 1; }
    const bool stopped = dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC)) == 0;
    if (!stopped) [capture nocturneStopCapture:signal];
    printf("%s: native capture produced %d real frames (%dx%d), luma range=%d..%d\n", samples.load() >= 3 ? "PASS" : "FAIL", samples.load(), width.load(), height.load(), lumaMin.load(), lumaMax.load());
    [capture release];
    return samples.load() >= 3 ? 0 : 1;
  }
}
