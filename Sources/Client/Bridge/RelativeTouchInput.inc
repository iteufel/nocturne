- (void)nocturneCancelTap {
    nocturneTapGeneration++;
    if (nocturneTapButton) {
        [(StreamView *)view nocturneSendMouseButton:BUTTON_ACTION_RELEASE button:nocturneTapButton];
        nocturneTapButton = 0;
    }
}

- (void)nocturneTapButton:(int)button {
    [self nocturneCancelTap];
    nocturneTapButton = button;
    NSUInteger generation = nocturneTapGeneration;
    [(StreamView *)view nocturneSendMouseButton:BUTTON_ACTION_PRESS button:button];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self && self->nocturneTapGeneration == generation) [self nocturneCancelTap];
    });
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [dragTimer invalidate]; dragTimer = nil;
    if (isDragging) {
        isDragging = NO;
        [(StreamView *)view nocturneSendMouseButton:BUTTON_ACTION_RELEASE button:BUTTON_LEFT];
    } else if (!touchMoved) {
        if (peakTouchCount == 2) [self nocturneTapButton:BUTTON_RIGHT];
        else if (peakTouchCount == 1) [self nocturneTapButton:BUTTON_LEFT];
    }
    if (event.allTouches.count - touches.count == 1) {
        NSMutableSet *active = [event.allTouches mutableCopy];
        [active minusSet:touches];
        touchLocation = [active.anyObject locationInView:view];
        touchMoved = YES;
    }
    if (event.allTouches.count == touches.count) peakTouchCount = 0;
}
