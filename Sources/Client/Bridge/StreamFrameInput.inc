- (void)nocturneSetAbsoluteTouchMode:(BOOL)absolute {
    _settings.absoluteTouchMode = absolute;
    [_streamView nocturneSetAbsoluteTouchMode:absolute controllerSupport:_controllerSupport];
    _streamView.multipleTouchEnabled = YES;
    _streamView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (absolute && !_scrollView) {
        [_streamView removeFromSuperview];
        _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _scrollView.panGestureRecognizer.minimumNumberOfTouches = 2;
        _scrollView.panGestureRecognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
        _scrollView.panGestureRecognizer.allowedScrollTypesMask = 0;
        _scrollView.delaysContentTouches = NO;
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.showsVerticalScrollIndicator = NO;
        _scrollView.delegate = self;
        _scrollView.maximumZoomScale = 10;
        [_scrollView addSubview:_streamView];
        [self.view insertSubview:_scrollView atIndex:0];
    } else if (!absolute && _scrollView) {
        _scrollView.zoomScale = 1;
        [_streamView removeFromSuperview];
        [_scrollView removeFromSuperview];
        _scrollView = nil;
        [self.view insertSubview:_streamView atIndex:0];
    } else if (!_streamView.superview) {
        [self.view insertSubview:_streamView atIndex:0];
    }
    _streamView.frame = _streamView.superview.bounds;
    [self.view setNeedsLayout];
}

- (void)nocturneReleaseInput {
    [_streamView nocturneCancelInput];
    [_controllerSupport nocturneReleaseMouseButtons];
}

- (void)nocturneFocusInput { [_streamView becomeFirstResponder]; }

- (void)nocturneToggleKeyboard { [_streamView nocturneToggleKeyboard]; }
- (void)nocturneSetKeyboardVisible:(BOOL)visible { [_streamView nocturneSetKeyboardVisible:visible]; }
