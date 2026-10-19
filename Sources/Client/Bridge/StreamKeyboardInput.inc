- (BOOL)nocturneSendKeyPress:(UIPress *)press down:(BOOL)down {
    return [KeyboardSupport sendKeyEventForPress:press down:down];
}

- (void)nocturneReleaseKeyboard {
    for (UIPress *press in nocturnePressedKeys.allValues) [self nocturneSendKeyPress:press down:NO];
    [nocturnePressedKeys removeAllObjects];
    [self textFieldDidEndEditing:keyInputField];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        UIKeyModifierFlags modifiers = press.key.modifierFlags & (UIKeyModifierCommand | UIKeyModifierShift | UIKeyModifierControl | UIKeyModifierAlternate);
        if (press.key.keyCode == UIKeyboardHIDUsageKeyboardM && modifiers == (UIKeyModifierCommand | UIKeyModifierShift)) {
            nocturneControlsKeyDown = YES;
            [self nocturneReleaseKeyboard];
            [[NSNotificationCenter defaultCenter] postNotificationName:NocturneStreamControlsRequestedNotification object:self.window];
            return;
        }
    }
    if (!nocturnePressedKeys) nocturnePressedKeys = [NSMutableDictionary dictionary];
    NSMutableSet *unhandled = [NSMutableSet set];
    for (UIPress *press in presses) {
        if (press.key.keyCode == UIKeyboardHIDUsageKeyboardM) nocturneControlsKeyDown = NO;
        if ([self nocturneSendKeyPress:press down:YES]) {
            if (press.key) nocturnePressedKeys[@(press.key.keyCode)] = press;
        } else [unhandled addObject:press];
    }
    if (unhandled.count) [super pressesBegan:unhandled withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    NSMutableSet *unhandled = [NSMutableSet set];
    for (UIPress *press in presses) {
        if (press.key.keyCode == UIKeyboardHIDUsageKeyboardM && nocturneControlsKeyDown) {
            nocturneControlsKeyDown = NO;
            continue;
        }
        // A focus/lock transition already released these keys. Do not send an
        // orphan key-up or the release shortcut to the remote computer.
        if (press.key && !nocturnePressedKeys[@(press.key.keyCode)]) continue;
        if (![self nocturneSendKeyPress:press down:NO]) [unhandled addObject:press];
        if (press.key) [nocturnePressedKeys removeObjectForKey:@(press.key.keyCode)];
    }
    if (unhandled.count) [super pressesEnded:unhandled withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self pressesEnded:presses withEvent:event];
}
