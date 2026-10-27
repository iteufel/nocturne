#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Runtime-checked macOS virtual display support. No additional app or driver.
@interface NDVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
+ (BOOL)isSupported;
- (nullable instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height
                          refreshRate:(NSUInteger)refreshRate error:(NSError **)error;
- (BOOL)selectRequestedModeWithError:(NSError **)error;
@end

/// Captures the login session's current layout before Nocturne changes it.
@interface NDDisplayLayout : NSObject
- (instancetype)initExcludingDisplay:(CGDirectDisplayID)display;
+ (BOOL)isSessionAvailable;
+ (BOOL)isScreenLocked;
/// Evaluate a WindowServer session snapshot using the same policy as live checks.
+ (BOOL)isSessionAvailableForSession:(nullable NSDictionary *)session;
+ (BOOL)canDisableDisplays;
+ (BOOL)hasActiveDisplayOtherThan:(CGDirectDisplayID)excluded;
- (BOOL)makePrimary:(CGDirectDisplayID)display disableOthers:(BOOL)disableOthers error:(NSError **)error;
- (BOOL)restoreWithError:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
