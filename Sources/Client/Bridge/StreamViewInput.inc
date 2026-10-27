- (BOOL)nocturneFillEntireScreen {
    return [objc_getAssociatedObject(self, @selector(nocturneFillEntireScreen)) boolValue];
}
- (void)setNocturneFillEntireScreen:(BOOL)fill {
    objc_setAssociatedObject(self, @selector(nocturneFillEntireScreen), @(fill), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)nocturneSendMouseButton:(int)action button:(int)button {
    LiSendMouseButtonEvent(action, button);
}

- (UIEventButtonMask)nocturneFlagForButton:(int)button {
    // UIKit numbers right/middle as 2/3; GameStream numbers them as 3/2.
    return UIEventButtonMaskForButtonNumber(button == BUTTON_RIGHT ? 2 : button == BUTTON_MIDDLE ? 3 : button);
}

- (void)nocturneReleaseMouseButtons {
    for (int button = BUTTON_LEFT; button <= BUTTON_X2; button++) {
        if (lastMouseButtonMask & [self nocturneFlagForButton:button]) {
            [self nocturneSendMouseButton:BUTTON_ACTION_RELEASE button:button];
        }
    }
    lastMouseButtonMask = 0;
    [nocturneMouseTouches removeAllObjects];
    lastMouseX = lastMouseY = 0;
    lastScrollTranslation = CGPointZero;
}

- (BOOL)handleMouseButtonEvent:(int)action forTouches:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    if (!touch || touch.type != UITouchTypeIndirectPointer) return NO;
    if (NocturneUsesRelativeMouse(self)) return YES;

    if (!nocturneMouseTouches) nocturneMouseTouches = [NSMapTable weakToStrongObjectsMapTable];
    UIEventButtonMask updated = lastMouseButtonMask;
    if (action == BUTTON_ACTION_PRESS) {
        UIEventButtonMask pressed = event.buttonMask & ~lastMouseButtonMask;
        updated |= pressed;
        [nocturneMouseTouches setObject:@(pressed) forKey:touch];
        // A click must also position the cursor, including the first mouse event.
        [self updateCursorLocation:[touch locationInView:self] isMouse:NO];
    } else {
        // Associate the released buttons with their touch, supporting both UIKit
        // release-mask conventions and chords without leaving a button held.
        for (UITouch *ended in touches) {
            NSNumber *pressed = [nocturneMouseTouches objectForKey:ended];
            UIEventButtonMask released = pressed ? pressed.unsignedIntegerValue : (event.buttonMask ?: lastMouseButtonMask);
            updated &= ~released;
            [nocturneMouseTouches removeObjectForKey:ended];
        }
    }
    UIEventButtonMask changed = lastMouseButtonMask ^ updated;
    lastMouseButtonMask = updated;
    for (int button = BUTTON_LEFT; button <= BUTTON_X2; button++) {
        UIEventButtonMask flag = [self nocturneFlagForButton:button];
        if (changed & flag) {
            [self nocturneSendMouseButton:(updated & flag) ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE button:button];
        }
    }
    return YES;
}

- (void)nocturneSetAbsoluteTouchMode:(BOOL)absolute controllerSupport:(ControllerSupport *)support {
    if ((absolute && [touchHandler isKindOfClass:AbsoluteTouchHandler.class]) ||
        (!absolute && [touchHandler isKindOfClass:RelativeTouchHandler.class])) return;
    [self nocturneCancelInput];
    touchHandler = absolute ? [[AbsoluteTouchHandler alloc] initWithView:self] : [[RelativeTouchHandler alloc] initWithView:self];
    OnScreenControlsLevel level = (OnScreenControlsLevel)[[DataManager new] getSettings].onscreenControls.integerValue;
    if (absolute) [onScreenControls setLevel:OnScreenControlsLevelOff];
    else if (level == OnScreenControlsLevelAuto) [support initAutoOnScreenControlMode:onScreenControls];
    else [onScreenControls setLevel:level];
}

- (void)nocturneCancelInput {
    [self nocturneReleaseKeyboard];
    NSSet *touches = [nocturneActiveTouches copy] ?: NSSet.set;
    if (!nocturneIgnoredTouches) nocturneIgnoredTouches = [NSHashTable weakObjectsHashTable];
    for (UITouch *touch in touches) [nocturneIgnoredTouches addObject:touch];
    [onScreenControls handleTouchUpEvent:touches];
    [touchHandler touchesCancelled:touches withEvent:nil];
    [nocturneActiveTouches removeAllObjects];
    [self nocturneReleaseMouseButtons];
    [interactionTimer invalidate]; interactionTimer = nil;
}

// Explicit show/hide actions are idempotent, including repeated edge swipes.
- (void)nocturneSetKeyboardVisible:(BOOL)visible {
    isInputingText = keyInputField.isFirstResponder;
    if (isInputingText != visible) [self nocturneToggleKeyboard];
}

// Retained for the upstream three-finger toggle gesture.
- (void)nocturneToggleKeyboard {
    if (isInputingText) {
        Log(LOG_D, @"Closing the keyboard");
        [keyInputField resignFirstResponder];
        isInputingText = false;
    } else {
        Log(LOG_D, @"Opening the keyboard");
        // Prepare the textbox used to capture keyboard events.
        keyInputField.delegate = self;
        keyInputField.text = @"0";
    #if !TARGET_OS_TV
        // Prepare the toolbar above the keyboard for more options
        UIToolbar *customToolbarView = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 44)];

        UIBarButtonItem *doneBarButton = [self createButtonWithImageNamed:@"DoneIcon.png" backgroundColor:[UIColor clearColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0x00 isToggleable:NO];
        UIBarButtonItem *windowsBarButton = [self createButtonWithImageNamed:@"WindowsIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0x5B isToggleable:YES];
        UIBarButtonItem *tabBarButton = [self createButtonWithImageNamed:@"TabIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0x09 isToggleable:NO];
        UIBarButtonItem *shiftBarButton = [self createButtonWithImageNamed:@"ShiftIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0xA0 isToggleable:YES];
        UIBarButtonItem *escapeBarButton = [self createButtonWithImageNamed:@"EscapeIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0x1B isToggleable:NO];
        UIBarButtonItem *controlBarButton = [self createButtonWithImageNamed:@"ControlIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0xA2 isToggleable:YES];
        UIBarButtonItem *altBarButton = [self createButtonWithImageNamed:@"AltIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0xA4 isToggleable:YES];
        UIBarButtonItem *deleteBarButton = [self createButtonWithImageNamed:@"DeleteIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0x2E isToggleable:NO];
        UIBarButtonItem *flexibleSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];

        [customToolbarView setItems:[NSArray arrayWithObjects:doneBarButton, windowsBarButton, escapeBarButton, tabBarButton, shiftBarButton, controlBarButton, altBarButton, deleteBarButton, flexibleSpace, nil]];
        keyInputField.inputAccessoryView = customToolbarView;
    #endif
        [keyInputField becomeFirstResponder];
        [keyInputField removeTarget:self action:@selector(onKeyboardPressed:) forControlEvents:UIControlEventEditingChanged];
        [keyInputField addTarget:self action:@selector(onKeyboardPressed:) forControlEvents:UIControlEventEditingChanged];

        // Undo causes issues for our state management, so turn it off
        [keyInputField.undoManager disableUndoRegistration];

        isInputingText = true;
    }
}
