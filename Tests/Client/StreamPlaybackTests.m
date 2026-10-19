#import <XCTest/XCTest.h>
#import "VideoDecoderRenderer.h"
#import "StreamView.h"

// Exercise the renderer's real display-link registration without a live host.
@interface PlaybackTestRenderer : VideoDecoderRenderer
@property NSUInteger ticks;
@end
@implementation PlaybackTestRenderer
- (void)displayLinkCallback:(CADisplayLink *)sender { self.ticks++; }
@end

@interface StreamPlaybackTests : XCTestCase
@end
@implementation StreamPlaybackTests
- (void)testVideoContinuesWhileTrackingTouches {
    XCTAssertTrue(NSThread.isMainThread);
    StreamView *view = [[StreamView alloc] initWithFrame:CGRectMake(0, 0, 1280, 720)];
    PlaybackTestRenderer *renderer = [[PlaybackTestRenderer alloc] initWithView:view callbacks:nil
        streamAspectRatio:16.0 / 9.0 useFramePacing:YES];
    [renderer setupWithVideoFormat:VIDEO_FORMAT_H264 width:1280 height:720 frameRate:60];
    [renderer start];
    @try {
        // Establish that the simulator is delivering display callbacks at all.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
        while (renderer.ticks < 2 && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
        }
        XCTAssertGreaterThanOrEqual(renderer.ticks, 2u);
        renderer.ticks = 0;
        deadline = [NSDate dateWithTimeIntervalSinceNow:0.2];
        // A tracking-mode timer keeps the run loop alive even if the video source
        // is absent, matching a continuous touch/scroll interaction.
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *timer) {}];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:UITrackingRunLoopMode];
        while (deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop mainRunLoop] runMode:UITrackingRunLoopMode beforeDate:deadline];
        }
        [timer invalidate];
        XCTAssertGreaterThan(renderer.ticks, 0u, @"Video froze for the entire touch gesture");
        NSLog(@"Video callbacks during a 200 ms touch gesture: %lu", (unsigned long)renderer.ticks);
    } @finally {
        [renderer stop];
    }
    NSUInteger stoppedTicks = renderer.ticks;
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    XCTAssertEqual(renderer.ticks, stoppedTicks, @"Stopping must remove callbacks from every run-loop mode");
}
@end
