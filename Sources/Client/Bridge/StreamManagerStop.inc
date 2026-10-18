- (void)stopStream { [self nocturneStopWithCompletion:nil]; }

- (void)nocturneStopWithCompletion:(void (^)(void))completion {
    @synchronized (self) {
        if (_nocturneStopped) { if (completion) dispatch_async(dispatch_get_main_queue(), completion); return; }
        if (!_nocturneStopCallbacks) _nocturneStopCallbacks = [NSMutableArray array];
        if (completion) [_nocturneStopCallbacks addObject:[completion copy]];
        if (_nocturneStopping) return;
        _nocturneStopping = YES;
        [self cancel];
    }
    // A cancelled launch must finish before another launch negotiates a size.
    // Its queued renderer block checks cancellation before creating Connection.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self waitUntilFinished];
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^finished)(void) = ^{
                NSArray *callbacks;
                @synchronized (self) {
                    self->_nocturneStopped = YES;
                    callbacks = [self->_nocturneStopCallbacks copy];
                    [self->_nocturneStopCallbacks removeAllObjects];
                }
                for (void (^callback)(void) in callbacks) callback();
            };
            if (self->_connection) [self->_connection nocturneTerminateWithCompletion:finished];
            else finished();
        });
    });
}
