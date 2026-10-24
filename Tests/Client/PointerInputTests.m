#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "StreamView.h"
#import "AbsoluteTouchHandler.h"
#import "RelativeTouchHandler.h"
#import "NocturneStreamInput.h"
#import <Limelight.h>

@interface StreamView (PointerInputTests)
- (BOOL)handleMouseButtonEvent:(int)action forTouches:(NSSet *)touches withEvent:(UIEvent *)event;
@end

@interface PointerTestTouch : UITouch
@property UITouchType inputType;
@property NSTimeInterval inputTimestamp;
@end
@implementation PointerTestTouch
- (UITouchType)type { return self.inputType; }
- (NSTimeInterval)timestamp { return self.inputTimestamp; }
- (CGPoint)locationInView:(UIView *)view { return CGPointMake(400, 300); }
@end

@interface PointerTestEvent : UIEvent
@property UIEventButtonMask inputButtons;
@property NSSet *inputTouches;
@end
@implementation PointerTestEvent
- (UIEventButtonMask)buttonMask { return self.inputButtons; }
- (NSSet *)allTouches { return self.inputTouches; }
@end

// Observe the actual handlers at their transport boundary without a live host.
@interface RecordingStreamView : StreamView
@property NSMutableArray<NSArray<NSNumber *> *> *buttonEvents;
@property NSMutableArray<NSArray<NSNumber *> *> *keyEvents;
@property CGPoint cursorLocation;
@end
@implementation RecordingStreamView
- (void)nocturneSendMouseButton:(int)action button:(int)button {
    if (!self.buttonEvents) self.buttonEvents = [NSMutableArray array];
    [self.buttonEvents addObject:@[@(action), @(button)]];
}
- (void)updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse { self.cursorLocation = location; }
- (BOOL)nocturneSendKeyPress:(UIPress *)press down:(BOOL)down {
    if (!self.keyEvents) self.keyEvents = [NSMutableArray array];
    [self.keyEvents addObject:@[@(press.key.keyCode), @(down)]];
    return YES;
}
@end

@interface PointerTestKey : NSObject
@property UIKeyboardHIDUsage keyCode;
@property UIKeyModifierFlags modifierFlags;
@end
@implementation PointerTestKey
@end
@interface PointerTestPress : NSObject
@property PointerTestKey *key;
@end
@implementation PointerTestPress
@end

@interface PointerTestButton : NSObject
@property (copy) void (^pressedChangedHandler)(GCControllerButtonInput *, float, BOOL);
@end
@implementation PointerTestButton
@end
@interface PointerTestMouseInput : NSObject
@property (copy) void (^mouseMovedHandler)(GCMouseInput *, float, float);
@property PointerTestButton *leftButton, *rightButton, *middleButton;
@property NSArray<PointerTestButton *> *auxiliaryButtons;
@end
@implementation PointerTestMouseInput
@end
@interface PointerTestMouse : NSObject
@property PointerTestMouseInput *mouseInput;
@end
@implementation PointerTestMouse
@end
@interface ControllerSupport (PointerInputTests)
- (void)registerMouseCallbacks:(GCMouse *)mouse;
@end
@interface RecordingControllerSupport : ControllerSupport
@property BOOL rawEnabled;
@property NSMutableArray<NSArray<NSNumber *> *> *buttonEvents;
@property NSMutableArray<NSArray<NSNumber *> *> *moveEvents;
@end
@implementation RecordingControllerSupport
- (BOOL)nocturneUsesRelativeMouse { return self.rawEnabled; }
- (void)nocturneSendMouseMoveX:(short)x y:(short)y {
    if (!self.moveEvents) self.moveEvents = [NSMutableArray array];
    [self.moveEvents addObject:@[@(x), @(y)]];
}
- (void)nocturneSendMouseButton:(int)action button:(int)button {
    if (!self.buttonEvents) self.buttonEvents = [NSMutableArray array];
    [self.buttonEvents addObject:@[@(action), @(button)]];
}
@end

@interface PointerTestFrameController : StreamFrameViewController
@end
@implementation PointerTestFrameController
// Exercise the real mode/container transition without launching a network stream.
- (void)viewDidLoad {}
@end

@interface PointerInputTests : XCTestCase
@end
@implementation PointerInputTests
- (RecordingStreamView *)viewWithAbsoluteTouch:(BOOL)absolute {
    RecordingStreamView *view = [[RecordingStreamView alloc] initWithFrame:CGRectMake(0, 0, 1024, 768)];
    StreamConfiguration *config = [StreamConfiguration new]; config.width = 1024; config.height = 768;
    [view setupStreamView:nil interactionDelegate:nil config:config];
    [view nocturneSetAbsoluteTouchMode:absolute controllerSupport:nil];
    [view setValue:nil forKey:@"onScreenControls"];
    [view.buttonEvents removeAllObjects];
    return view;
}
- (void)waitForTapRelease {
    XCTestExpectation *released = [self expectationWithDescription:@"Tap released"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [released fulfill]; });
    [self waitForExpectations:@[released] timeout:2];
}
- (void)testKeyboardButtonUsesTheStreamTextFieldAndCanToggleRepeatedly {
    RecordingStreamView *view = [self viewWithAbsoluteTouch:YES];
    UITextField *field = [view valueForKey:@"keyInputField"];
    for (int attempt = 0; attempt < 3; attempt++) {
        [view nocturneToggleKeyboard];
        XCTAssertTrue([[view valueForKey:@"isInputingText"] boolValue]);
        XCTAssertEqualObjects(field.text, @"0");
        XCTAssertNotNil(field.inputAccessoryView);
        XCTAssertEqual([field actionsForTarget:view forControlEvent:UIControlEventEditingChanged].count, 1u);
        [view nocturneToggleKeyboard];
        XCTAssertFalse([[view valueForKey:@"isInputingText"] boolValue]);
    }
}
- (void)testDirectTapPositionsCursorAndClicks {
    RecordingStreamView *view = [self viewWithAbsoluteTouch:YES];
    PointerTestTouch *touch = [PointerTestTouch new]; touch.inputTimestamp = 1;
    PointerTestEvent *event = [PointerTestEvent new]; event.inputTouches = [NSSet setWithObject:touch];
    [view touchesBegan:event.inputTouches withEvent:event];
    [view touchesEnded:event.inputTouches withEvent:event];
    XCTAssertTrue(CGPointEqualToPoint(view.cursorLocation, CGPointMake(400, 300)));
    XCTAssertEqualObjects(view.buttonEvents[0], (@[@(BUTTON_ACTION_PRESS), @(BUTTON_LEFT)]));
    XCTAssertEqualObjects(view.buttonEvents[1], (@[@(BUTTON_ACTION_RELEASE), @(BUTTON_LEFT)]));
    [view nocturneCancelInput];
}
- (void)testRapidTrackpadTapsProduceTwoCompleteClicks {
    RecordingStreamView *view = [self viewWithAbsoluteTouch:NO];
    PointerTestTouch *touch = [PointerTestTouch new];
    PointerTestEvent *event = [PointerTestEvent new]; event.inputTouches = [NSSet setWithObject:touch];
    for (int tap = 0; tap < 2; tap++) {
        [view touchesBegan:event.inputTouches withEvent:event];
        [view touchesEnded:event.inputTouches withEvent:event];
    }
    [self waitForTapRelease];
    XCTAssertEqualObjects(view.buttonEvents, (@[@[@(BUTTON_ACTION_PRESS), @(BUTTON_LEFT)], @[@(BUTTON_ACTION_RELEASE), @(BUTTON_LEFT)],
        @[@(BUTTON_ACTION_PRESS), @(BUTTON_LEFT)], @[@(BUTTON_ACTION_RELEASE), @(BUTTON_LEFT)]]));
    [view nocturneCancelInput];
}
- (void)testTwoFingerTapRightClicksThenSingleFingerTapLeftClicks {
    RecordingStreamView *view = [self viewWithAbsoluteTouch:NO];
    PointerTestTouch *first = [PointerTestTouch new], *second = [PointerTestTouch new];
    PointerTestEvent *event = [PointerTestEvent new]; event.inputTouches = [NSSet setWithObjects:first, second, nil];
    [view touchesBegan:event.inputTouches withEvent:event];
    [view touchesEnded:event.inputTouches withEvent:event];
    event.inputTouches = [NSSet setWithObject:first];
    [view touchesBegan:event.inputTouches withEvent:event];
    [view touchesEnded:event.inputTouches withEvent:event];
    [self waitForTapRelease];
    XCTAssertEqualObjects(view.buttonEvents, (@[@[@(BUTTON_ACTION_PRESS), @(BUTTON_RIGHT)], @[@(BUTTON_ACTION_RELEASE), @(BUTTON_RIGHT)],
        @[@(BUTTON_ACTION_PRESS), @(BUTTON_LEFT)], @[@(BUTTON_ACTION_RELEASE), @(BUTTON_LEFT)]]));
    [view nocturneCancelInput];
}
- (void)testModeSwitchReleasesTapAndSuppressesItsDelayedCallback {
    RecordingStreamView *view = [self viewWithAbsoluteTouch:NO];
    PointerTestTouch *touch = [PointerTestTouch new];
    PointerTestEvent *event = [PointerTestEvent new]; event.inputTouches = [NSSet setWithObject:touch];
    [view touchesBegan:event.inputTouches withEvent:event];
    [view touchesEnded:event.inputTouches withEvent:event];
    [view nocturneSetAbsoluteTouchMode:YES controllerSupport:nil];
    XCTAssertTrue([[view valueForKey:@"touchHandler"] isKindOfClass:AbsoluteTouchHandler.class]);
    XCTAssertEqualObjects(view.buttonEvents, (@[@[@(BUTTON_ACTION_PRESS), @(BUTTON_LEFT)], @[@(BUTTON_ACTION_RELEASE), @(BUTTON_LEFT)]]));
    [self waitForTapRelease];
    XCTAssertEqual(view.buttonEvents.count, 2);
    [view nocturneCancelInput];
}
- (void)testModeSwitchIgnoresThePreviousFingerUntilItIsLifted {
    RecordingStreamView *view = [self viewWithAbsoluteTouch:NO];
    PointerTestTouch *touch = [PointerTestTouch new];
    PointerTestEvent *event = [PointerTestEvent new]; event.inputTouches = [NSSet setWithObject:touch];
    [view touchesBegan:event.inputTouches withEvent:event];
    [view nocturneSetAbsoluteTouchMode:YES controllerSupport:nil];
    view.cursorLocation = CGPointZero;
    [view touchesMoved:event.inputTouches withEvent:event];
    XCTAssertTrue(CGPointEqualToPoint(view.cursorLocation, CGPointZero), @"A cancelled gesture cannot move the new mode's pointer");
    [view touchesEnded:event.inputTouches withEvent:event];
    [view.buttonEvents removeAllObjects];
    touch.inputTimestamp = 1;
    [view touchesBegan:event.inputTouches withEvent:event];
    [view touchesEnded:event.inputTouches withEvent:event];
    XCTAssertEqualObjects(view.buttonEvents[0], (@[@(BUTTON_ACTION_PRESS), @(BUTTON_LEFT)]));
    [view nocturneCancelInput];
}
- (void)testModeSwitchReparentsTheSameVideoSurfaceAndKeepsMouseScrollOutOfZoom {
    RecordingStreamView *view = [self viewWithAbsoluteTouch:NO];
    PointerTestFrameController *frame = [PointerTestFrameController new];
    frame.view.frame = CGRectMake(0, 0, 1024, 768);
    [frame setValue:view forKey:@"streamView"];
    [frame.view addSubview:view];
    [frame nocturneSetAbsoluteTouchMode:YES];
    XCTAssertTrue([view.superview isKindOfClass:UIScrollView.class]);
    UIScrollView *zoom = (UIScrollView *)view.superview;
    XCTAssertFalse(zoom.delaysContentTouches, @"A direct tap must reach the stream immediately");
    XCTAssertEqual(zoom.panGestureRecognizer.allowedScrollTypesMask, 0);
    XCTAssertTrue([[view valueForKey:@"touchHandler"] isKindOfClass:AbsoluteTouchHandler.class]);
    [frame nocturneSetAbsoluteTouchMode:NO];
    XCTAssertEqual(view.superview, frame.view);
    XCTAssertTrue([[view valueForKey:@"touchHandler"] isKindOfClass:RelativeTouchHandler.class]);
    XCTAssertNil(zoom.superview);
    [view nocturneCancelInput];
}
- (void)testUIKitMouseChordsReleaseOnlyTheEndedButton {
    RecordingStreamView *view = [self viewWithAbsoluteTouch:NO];
    PointerTestTouch *left = [PointerTestTouch new], *right = [PointerTestTouch new];
    left.inputType = right.inputType = UITouchTypeIndirectPointer;
    PointerTestEvent *event = [PointerTestEvent new]; event.inputButtons = UIEventButtonMaskPrimary;
    [view touchesBegan:[NSSet setWithObject:left] withEvent:event];
    event.inputButtons |= UIEventButtonMaskSecondary;
    [view touchesBegan:[NSSet setWithObject:right] withEvent:event];
    // UIKit may report the remaining buttons or the released buttons on release.
    event.inputButtons = UIEventButtonMaskPrimary;
    [view touchesEnded:[NSSet setWithObject:right] withEvent:event];
    XCTAssertEqual([[view valueForKey:@"lastMouseButtonMask"] integerValue], UIEventButtonMaskPrimary);
    event.inputButtons = 0;
    [view touchesEnded:[NSSet setWithObject:left] withEvent:event];
    XCTAssertEqualObjects(view.buttonEvents, (@[@[@(BUTTON_ACTION_PRESS), @(BUTTON_LEFT)], @[@(BUTTON_ACTION_PRESS), @(BUTTON_RIGHT)],
        @[@(BUTTON_ACTION_RELEASE), @(BUTTON_RIGHT)], @[@(BUTTON_ACTION_RELEASE), @(BUTTON_LEFT)]]));
    [view nocturneCancelInput];
}
- (void)testRawMouseCallbacksRequirePointerLockAndReleaseWhenItIsLost {
    RecordingControllerSupport *support = [[RecordingControllerSupport alloc] initWithConfig:[StreamConfiguration new] delegate:nil];
    PointerTestMouse *mouse = [PointerTestMouse new]; mouse.mouseInput = [PointerTestMouseInput new];
    mouse.mouseInput.leftButton = [PointerTestButton new]; mouse.mouseInput.middleButton = [PointerTestButton new];
    mouse.mouseInput.rightButton = [PointerTestButton new];
    [support registerMouseCallbacks:(id)mouse];
    mouse.mouseInput.mouseMovedHandler(nil, 50, -25);
    XCTAssertEqual(support.moveEvents.count, 0);
    mouse.mouseInput.leftButton.pressedChangedHandler(nil, 1, YES);
    XCTAssertEqual(support.buttonEvents.count, 0, @"UIKit owns unlocked input; raw callbacks must not double-click");
    support.rawEnabled = YES;
    mouse.mouseInput.mouseMovedHandler(nil, 50, -25);
    XCTAssertEqual(support.moveEvents.count, 1, @"Locked input must forward relative movement without screen coordinates");
    XCTAssertGreaterThan(support.moveEvents.firstObject.firstObject.intValue, 0);
    XCTAssertGreaterThan(support.moveEvents.firstObject.lastObject.intValue, 0);
    mouse.mouseInput.leftButton.pressedChangedHandler(nil, 1, YES);
    support.rawEnabled = NO;
    mouse.mouseInput.mouseMovedHandler(nil, 50, -25);
    XCTAssertEqual(support.moveEvents.count, 1);
    mouse.mouseInput.leftButton.pressedChangedHandler(nil, 0, NO);
    XCTAssertEqualObjects(support.buttonEvents, (@[@[@(BUTTON_ACTION_PRESS), @(BUTTON_LEFT)], @[@(BUTTON_ACTION_RELEASE), @(BUTTON_LEFT)]]));
    [support cleanup];
}
- (PointerTestPress *)press:(UIKeyboardHIDUsage)key modifiers:(UIKeyModifierFlags)modifiers {
    PointerTestPress *press = [PointerTestPress new]; press.key = [PointerTestKey new];
    press.key.keyCode = key; press.key.modifierFlags = modifiers; return press;
}
- (void)testPointerReleaseShortcutStaysLocalAndReleasesHeldKeys {
    RecordingStreamView *view = [RecordingStreamView new];
    PointerTestPress *modifier = [self press:UIKeyboardHIDUsageKeyboardLeftGUI modifiers:UIKeyModifierCommand];
    [view pressesBegan:(id)[NSSet setWithObject:modifier] withEvent:nil];
    PointerTestPress *shortcut = [self press:UIKeyboardHIDUsageKeyboardM modifiers:UIKeyModifierCommand | UIKeyModifierShift];
    XCTestExpectation *controls = [self expectationForNotification:NocturneStreamControlsRequestedNotification object:nil handler:nil];
    [view pressesBegan:(id)[NSSet setWithObject:shortcut] withEvent:nil];
    shortcut.key.modifierFlags = 0;
    [view pressesEnded:(id)[NSSet setWithObject:shortcut] withEvent:nil];
    [view pressesEnded:(id)[NSSet setWithObject:modifier] withEvent:nil];
    [self waitForExpectations:@[controls] timeout:1];
    XCTAssertEqualObjects(view.keyEvents, (@[@[@(UIKeyboardHIDUsageKeyboardLeftGUI), @YES], @[@(UIKeyboardHIDUsageKeyboardLeftGUI), @NO]]));
    // Plain M must still work after returning to the stream.
    [view pressesBegan:(id)[NSSet setWithObject:shortcut] withEvent:nil];
    [view pressesEnded:(id)[NSSet setWithObject:shortcut] withEvent:nil];
    XCTAssertEqualObjects(view.keyEvents.lastObject, (@[@(UIKeyboardHIDUsageKeyboardM), @NO]));
    XCTAssertEqual(view.keyEvents.count, 4);
}
- (void)testCancellingInputReleasesHardwareKeysExactlyOnce {
    RecordingStreamView *view = [RecordingStreamView new];
    PointerTestPress *press = [self press:UIKeyboardHIDUsageKeyboardW modifiers:0];
    [view pressesBegan:(id)[NSSet setWithObject:press] withEvent:nil];
    [view nocturneCancelInput];
    [view nocturneCancelInput];
    [view pressesEnded:(id)[NSSet setWithObject:press] withEvent:nil];
    XCTAssertEqualObjects(view.keyEvents, (@[@[@(UIKeyboardHIDUsageKeyboardW), @YES], @[@(UIKeyboardHIDUsageKeyboardW), @NO]]));
}
- (void)testCancellingDirectTouchReleasesEvenWhenAnotherFingerIsDown {
    StreamView *view = [[StreamView alloc] initWithFrame:CGRectMake(0, 0, 1024, 768)];
    AbsoluteTouchHandler *handler = [[AbsoluteTouchHandler alloc] initWithView:view];
    PointerTestTouch *first = [PointerTestTouch new], *second = [PointerTestTouch new];
    PointerTestEvent *event = [PointerTestEvent new]; event.inputTouches = [NSSet setWithObject:first];
    [handler touchesBegan:event.inputTouches withEvent:event];
    XCTAssertNotNil([handler valueForKey:@"longPressTimer"]);
    event.inputTouches = [NSSet setWithObjects:first, second, nil];
    [handler touchesCancelled:[NSSet setWithObject:first] withEvent:event];
    XCTAssertNil([handler valueForKey:@"longPressTimer"], @"A cancelled finger must not keep holding or right-click later");
    [handler touchesCancelled:NSSet.set withEvent:nil];
}
- (void)testStreamViewEnablesMultipleFingers {
    StreamView *view = [[StreamView alloc] initWithFrame:CGRectMake(0, 0, 1024, 768)];
    StreamConfiguration *config = [StreamConfiguration new]; config.width = 1024; config.height = 768;
    [view setupStreamView:nil interactionDelegate:nil config:config];
    XCTAssertTrue(view.multipleTouchEnabled, @"Two-finger right click/scroll and the keyboard gesture require multitouch");
}
- (void)testUIKitMouseStillWorksWhenAnUnlockedGCMouseIsPresent {
    Method current = class_getClassMethod(GCMouse.class, @selector(current));
    IMP original = method_getImplementation(current);
    IMP replacement = imp_implementationWithBlock(^id(id receiver) { return [NSObject new]; });
    method_setImplementation(current, replacement);
    @try {
        StreamView *view = [StreamView new];
        PointerTestTouch *touch = [PointerTestTouch new]; touch.inputType = UITouchTypeIndirectPointer;
        PointerTestEvent *event = [PointerTestEvent new]; event.inputButtons = UIEventButtonMaskPrimary;
        XCTAssertTrue([view handleMouseButtonEvent:BUTTON_ACTION_PRESS forTouches:[NSSet setWithObject:touch] withEvent:event]);
        XCTAssertEqual([[view valueForKey:@"lastMouseButtonMask"] integerValue], UIEventButtonMaskPrimary,
            @"A detected GCMouse must not swallow UIKit clicks when pointer lock is unavailable");
    } @finally {
        method_setImplementation(current, original);
        imp_removeBlock(replacement);
    }
}
- (void)testUIKitReleaseWithNoPressedButtonsDoesNotLeaveMouseDown {
    StreamView *view = [StreamView new];
    PointerTestTouch *touch = [PointerTestTouch new]; touch.inputType = UITouchTypeIndirectPointer;
    PointerTestEvent *event = [PointerTestEvent new]; event.inputButtons = UIEventButtonMaskPrimary;
    NSSet *touches = [NSSet setWithObject:touch];
    [view handleMouseButtonEvent:BUTTON_ACTION_PRESS forTouches:touches withEvent:event];
    event.inputButtons = 0;
    [view handleMouseButtonEvent:BUTTON_ACTION_RELEASE forTouches:touches withEvent:event];
    XCTAssertEqual([[view valueForKey:@"lastMouseButtonMask"] integerValue], 0,
        @"Releasing the last physical mouse button must release it on the host");
}
@end
