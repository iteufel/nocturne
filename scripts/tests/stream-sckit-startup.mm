#import <Foundation/Foundation.h>
#include <iostream>
#include <stdexcept>
#if __has_include("CaptureStartup.h")
#include "CaptureStartup.h"
#endif
using namespace std::literals;
#define BOOST_LOG(level) std::cerr
[[maybe_unused]] static const char *error_description(NSError *error) { return error.localizedDescription.UTF8String; }
[[maybe_unused]] static long testWait(dispatch_semaphore_t signal, dispatch_time_t deadline) {
    if (dispatch_semaphore_wait(signal, DISPATCH_TIME_NOW) == 0) return 0;
    if (deadline == DISPATCH_TIME_FOREVER) throw std::runtime_error("ScreenCaptureKit startup waits forever without its completion callback");
    return dispatch_semaphore_wait(signal, deadline);
}
#define dispatch_semaphore_wait testWait

enum class ReplyMode { success, failure, delayed };
static ReplyMode contentMode, streamMode;
static int contents, streams, stops;
@interface SCShareableContent: NSObject
+ (void)getShareableContentWithCompletionHandler:(void (^)(SCShareableContent *, NSError *))reply;
@end
static void (^contentReply)(SCShareableContent *, NSError *);
@implementation SCShareableContent
- (instancetype)init { if ((self = [super init])) ++contents; return self; }
- (void)dealloc { --contents; [super dealloc]; }
+ (void)getShareableContentWithCompletionHandler:(void (^)(SCShareableContent *, NSError *))reply {
    if (contentMode == ReplyMode::delayed) { contentReply = [reply copy]; return; }
    SCShareableContent *value = contentMode == ReplyMode::success ? [SCShareableContent new] : nil;
    reply(value, contentMode == ReplyMode::failure ? [NSError errorWithDomain:@"test" code:1 userInfo:nil] : nil);
    [value release];
}
@end

static constexpr int SCStreamOutputTypeScreen = 0;
@interface SCStream: NSObject
- (instancetype)initWithFilter:(id)filter configuration:(id)configuration delegate:(id)delegate;
- (BOOL)addStreamOutput:(id)output type:(int)type sampleHandlerQueue:(id)queue error:(NSError **)error;
- (void)startCaptureWithCompletionHandler:(void (^)(NSError *))reply;
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))reply;
@end
static void (^streamReply)(NSError *);
@implementation SCStream
- (instancetype)initWithFilter:(id)filter configuration:(id)configuration delegate:(id)delegate {
    if ((self = [super init])) ++streams;
    return self;
}
- (void)dealloc { --streams; [super dealloc]; }
- (BOOL)addStreamOutput:(id)output type:(int)type sampleHandlerQueue:(id)queue error:(NSError **)error { return YES; }
- (void)startCaptureWithCompletionHandler:(void (^)(NSError *))reply {
    if (streamMode == ReplyMode::delayed) { streamReply = [reply copy]; return; }
    reply(streamMode == ReplyMode::failure ? [NSError errorWithDomain:@"test" code:2 userInfo:nil] : nil);
}
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))reply { ++stops; reply(nil); }
@end

#include "content.inc"
@interface Capture: NSObject
@property(nonatomic, readonly) id contentFilter;
@property(nonatomic, readonly) id streamConfiguration;
- (SCStream *)startConfiguredStream;
@end
@implementation Capture
- (id)contentFilter { return nil; }
- (id)streamConfiguration { return nil; }
#include "start.inc"
@end

static int failures;
static void check(bool value, const char *message) {
    std::cout << (value ? "PASS: " : "FAIL: ") << message << '\n';
    if (!value) ++failures;
}
int main() { @autoreleasepool {
    Capture *capture = [Capture new];
    contentMode = streamMode = ReplyMode::success;
    SCShareableContent *content = copyShareableContent();
    check(content != nil && contents == 1, "shareable content retains its returned result exactly once");
    [content release];
    check(contents == 0, "shareable content is released after its caller finishes");
    contentMode = ReplyMode::failure;
    check(copyShareableContent() == nil, "shareable-content errors fail startup promptly");
    contentMode = ReplyMode::delayed;
    try { check(copyShareableContent() == nil, "missing shareable-content completion has a bounded deadline"); }
    catch (const std::exception &error) { std::cerr << error.what() << '\n'; check(false, "missing shareable-content completion must not wait forever"); }
    if (!failures) {
        content = [SCShareableContent new];
        contentReply(content, nil); [content release];
    }
    [contentReply release]; contentReply = nil;
    check(contents == 0, "a late content callback neither leaks nor publishes an abandoned result");

    SCStream *stream = [capture startConfiguredStream];
    check(stream != nil && streams == 1, "capture startup returns its retained stream on success");
    [stream release];
    streamMode = ReplyMode::failure;
    check([capture startConfiguredStream] == nil && streams == 0, "native capture-start errors release their stream");
    streamMode = ReplyMode::delayed;
    const int previousFailures = failures;
    try { check([capture startConfiguredStream] == nil && stops == 1, "missing capture-start completion cancels within a bounded deadline"); }
    catch (const std::exception &error) { std::cerr << error.what() << '\n'; check(false, "missing capture-start completion must not wait forever"); }
    if (failures == previousFailures) streamReply(nil);
    [streamReply release]; streamReply = nil;
    check(streams == 0 && stops == 2, "a late successful start is stopped and releases all retained startup state");
    [capture release];
    return failures ? 1 : 0;
} }
