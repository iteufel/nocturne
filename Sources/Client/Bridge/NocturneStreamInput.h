#import "StreamView.h"
#import "StreamFrameViewController.h"

// UIKit remains the input source in Split View and whenever the system declines
// pointer lock. Merely detecting a GCMouse does not mean raw input owns the scene.
static inline BOOL NocturneUsesRelativeMouse(UIView *view) {
    return view.window.windowScene.pointerLockState.isLocked && GCMouse.mice.count > 0;
}

@interface StreamView (NocturneInput)
- (void)nocturneSetAbsoluteTouchMode:(BOOL)absolute controllerSupport:(ControllerSupport *)support;
- (void)nocturneCancelInput;
- (void)nocturneReleaseMouseButtons;
- (void)nocturneSendMouseButton:(int)action button:(int)button;
@end

@interface ControllerSupport (NocturneInput)
- (BOOL)nocturneUsesRelativeMouse;
- (void)nocturneHandleMouseButton:(int)action button:(int)button;
- (void)nocturneReleaseMouseButtons;
- (void)nocturneSendMouseButton:(int)action button:(int)button;
@end

@interface StreamFrameViewController (NocturneInput)
- (void)nocturneSetAbsoluteTouchMode:(BOOL)absolute;
- (void)nocturneReleaseInput;
@end
