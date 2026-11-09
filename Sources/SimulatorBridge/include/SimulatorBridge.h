#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runtime-checked host connection to Xcode 27's simulator services. All methods
/// must be called on one serial worker queue, never the main thread.
@interface NCSimulatorBridge : NSObject
- (nullable instancetype)initWithDevice:(NSString *)device developerDirectory:(NSString *)directory error:(NSError **)error;
- (nullable NSDictionary *)displayInfoWithError:(NSError **)error;
- (nullable NSData *)framebufferPNGForDisplay:(NSString *)display rotation:(NSUInteger)rotation error:(NSError **)error;
- (nullable NSDictionary *)touchscreensWithError:(NSError **)error;
- (BOOL)sendTouchPhase:(NSUInteger)phase x:(double)x y:(double)y target:(NSUInteger)target edge:(NSUInteger)edge error:(NSError **)error;
- (void)cancelTouch;
- (void)close;
@end

NS_ASSUME_NONNULL_END
