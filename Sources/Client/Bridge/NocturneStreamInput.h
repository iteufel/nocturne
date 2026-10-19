#import "StreamView.h"
#import "StreamFrameViewController.h"
#import "NocturneStreamingService.h"

static inline CGSize NocturneVideoAreaSize(CGSize bounds, CGFloat ratio, BOOL fill) {
    if (ratio <= 0 || bounds.width <= 0 || bounds.height <= 0) return CGSizeZero;
    CGFloat height = fill ? MAX(bounds.width / ratio, bounds.height) : MIN(bounds.width / ratio, bounds.height);
    return CGSizeMake(height * ratio, height);
}

// UIKit remains the input source in Split View and whenever the system declines
// pointer lock. Merely detecting a GCMouse does not mean raw input owns the scene.
static inline BOOL NocturneUsesRelativeMouse(UIView *view) {
    return view.window.windowScene.pointerLockState.isLocked && GCMouse.mice.count > 0;
}

@interface StreamView (NocturneInput)
@property (nonatomic) BOOL nocturneFillEntireScreen;
- (CGSize)getVideoAreaSize;
- (void)nocturneSetAbsoluteTouchMode:(BOOL)absolute controllerSupport:(ControllerSupport *)support;
- (void)nocturneCancelInput;
- (void)nocturneReleaseMouseButtons;
- (void)nocturneSendMouseButton:(int)action button:(int)button;
- (BOOL)nocturneSendKeyPress:(UIPress *)press down:(BOOL)down;
@end

@interface ControllerSupport (NocturneInput)
- (BOOL)nocturneUsesRelativeMouse;
- (void)nocturneHandleMouseButton:(int)action button:(int)button;
- (void)nocturneReleaseMouseButtons;
- (void)nocturneSendMouseButton:(int)action button:(int)button;
- (void)nocturneSendMouseMoveX:(short)x y:(short)y;
@end

@interface StreamFrameViewController (NocturneInput)
- (void)nocturneSetAbsoluteTouchMode:(BOOL)absolute;
- (void)nocturneReleaseInput;
- (void)nocturneFocusInput;
@end
