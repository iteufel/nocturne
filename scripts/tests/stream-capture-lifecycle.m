// Compile the generated registration/callback methods under the engine's MRC
// ownership model, replacing only AVFoundation with a deterministic queue drain.
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
typedef NSObject AVCaptureOutput;
typedef NSObject AVCaptureConnection;
typedef const void *CMSampleBufferRef;
typedef bool (^FrameCallbackBlock)(CMSampleBufferRef);

static char deliveryKey;
static int liveTokens;
@interface CaptureToken : NSObject
@end
@implementation CaptureToken
- (id)init { if ((self = [super init])) ++liveTokens; return self; }
- (void)dealloc { --liveTokens; [super dealloc]; }
@end

@interface TestSession : NSObject
@property (nonatomic, assign) dispatch_queue_t delivery;
@property (nonatomic, assign) unsigned stops;
@property (nonatomic, assign) unsigned starts;
@property (nonatomic, assign) unsigned removals;
- (void)stopRunning;
- (void)startRunning;
- (void)removeOutput:(NSObject *)output;
@end
@implementation TestSession
- (void)stopRunning {
    // Real stopRunning may wait for AVFoundation's sample delegate queue. A
    // synchronous stop on that queue, or while holding its map lock, is unsafe.
    assert(dispatch_get_specific(&deliveryKey) == NULL);
    dispatch_sync(self.delivery, ^{});
    self.stops++;
}
- (void)startRunning { self.starts++; }
- (void)removeOutput:(NSObject *)output { assert(output != nil); self.removals++; }
@end

@interface AVVideo : NSObject
@property (nonatomic, retain) TestSession *session;
@property (nonatomic, retain) NSMapTable *videoOutputs;
@property (nonatomic, retain) NSMapTable *captureCallbacks;
@property (nonatomic, retain) NSMapTable *captureSignals;
- (void)registerCallback:(FrameCallbackBlock)frameCallback connection:(NSObject *)videoConnection signal:(dispatch_semaphore_t)signal;
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection;
@end
@implementation AVVideo
- (id)init {
    if ((self = [super init])) {
        self.videoOutputs = [NSMapTable strongToStrongObjectsMapTable];
        self.captureCallbacks = [NSMapTable strongToStrongObjectsMapTable];
        self.captureSignals = [NSMapTable strongToStrongObjectsMapTable];
    }
    return self;
}
- (void)dealloc {
    [_session release]; [_videoOutputs release]; [_captureCallbacks release]; [_captureSignals release];
    [super dealloc];
}
- (void)registerCallback:(FrameCallbackBlock)frameCallback connection:(NSObject *)videoConnection signal:(dispatch_semaphore_t)signal {
    NSObject *videoOutput = [NSObject new];
#include "registration.inc"
    [videoOutput release];
}
#include "callback.inc"
@end

// Returning from a separate stack frame and draining the autorelease pool is
// essential: retaining an MRC stack block cannot keep its captured token alive.
__attribute__((noinline)) static void registerFromStack(AVVideo *video, NSObject *connection,
                                                      dispatch_semaphore_t signal, unsigned *frames) {
    @autoreleasepool {
        CaptureToken *token = [CaptureToken new];
        [video registerCallback:^bool(CMSampleBufferRef sample) {
            assert(liveTokens == 1); assert([token isKindOfClass:CaptureToken.class]);
            ++*frames;
            return false;
        } connection:connection signal:signal];
        [token release];
    }
}

int main(void) { @autoreleasepool {
    for (unsigned attempt = 0; attempt < 64; ++attempt) {
        AVVideo *video = [AVVideo new];
        TestSession *session = [TestSession new]; video.session = session;
        dispatch_queue_t queue = dispatch_queue_create("capture-test.delivery", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue, &deliveryKey, &deliveryKey, NULL);
        session.delivery = queue;
        NSObject *connection = [NSObject new];
        dispatch_semaphore_t signal = dispatch_semaphore_create(0);
        unsigned frames = 0;
        registerFromStack(video, connection, signal, &frames);
        assert(liveTokens == 1);
        dispatch_async(queue, ^{
            @autoreleasepool {
                [video captureOutput:nil didOutputSampleBuffer:NULL fromConnection:connection];
                // Already queued frames must not invoke or retire this callback again.
                [video captureOutput:nil didOutputSampleBuffer:NULL fromConnection:connection];
            }
        });
        assert(dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
        assert(frames == 1 && liveTokens == 0);
        assert(session.stops == 1 && session.starts == 1 && session.removals == 1);
        // Wait until the callback map cleanup after the semaphore signal finishes.
        @synchronized(session) {}
        assert(video.captureCallbacks.count == 0 && video.captureSignals.count == 0);
        [video release]; [connection release]; [session release];
        dispatch_release(signal); dispatch_release(queue);
    }
    puts("PASS: copied MRC callbacks survive their stack scope across 64 reconnects");
    puts("PASS: teardown drains the delivery queue without a lock inversion or duplicate stop");
    return 0;
} }
