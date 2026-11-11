#pragma once
#import "src/platform/macos/av_video.h"

// Cancellation must drain the sample delegate before C++ callback captures die.
@interface AVVideo (NocturneCaptureLifecycle)
- (void)nocturneStopCapture:(dispatch_semaphore_t)signal;
@end
