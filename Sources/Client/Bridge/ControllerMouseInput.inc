- (BOOL)nocturneUsesRelativeMouse {
    return [_delegate isKindOfClass:UIViewController.class] && NocturneUsesRelativeMouse(((UIViewController *)_delegate).view);
}

- (void)nocturneSendMouseButton:(int)action button:(int)button {
    LiSendMouseButtonEvent(action, button);
}

- (void)nocturneHandleMouseButton:(int)action button:(int)button {
    if (![self nocturneUsesRelativeMouse]) {
        [self nocturneReleaseMouseButtons];
        return;
    }
    NSUInteger flag = 1 << button;
    if (action == BUTTON_ACTION_PRESS) nocturneMouseButtons |= flag;
    else nocturneMouseButtons &= ~flag;
    [self nocturneSendMouseButton:action button:button];
}

- (void)nocturneReleaseMouseButtons {
    for (int button = BUTTON_LEFT; button <= BUTTON_X2; button++) {
        if (nocturneMouseButtons & (1 << button)) [self nocturneSendMouseButton:BUTTON_ACTION_RELEASE button:button];
    }
    nocturneMouseButtons = 0;
    accumulatedDeltaX = accumulatedDeltaY = 0;
}
