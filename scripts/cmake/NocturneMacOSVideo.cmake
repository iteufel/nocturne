# AVVideo uses manual reference counting in the pinned engine. Retain asynchronous
# blocks correctly and avoid stopping AVCaptureSession on its delivery queue.
function(nocturne_macos_video source_root output)
    file(READ "${source_root}/src/platform/macos/av_video.m" video)
    set(before "    [self.captureCallbacks setObject:frameCallback forKey:videoConnection];")
    set(after "    [self.captureCallbacks setObject:[[frameCallback copy] autorelease] forKey:videoConnection];")
    string(FIND "${video}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS callback ownership changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" video "${video}")

    set(before "    [self.session addInput:screenInput];")
    set(after "    [self.session addInput:screenInput];\n    [screenInput release];")
    string(FIND "${video}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS input ownership changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" video "${video}")

    # Session configuration and callback lookup need different locks: stopping
    # capture must never hold the map lock needed by an in-flight frame callback.
    set(before "  @synchronized(self) {\n    AVCaptureVideoDataOutput *videoOutput")
    set(after "  @synchronized(self.session) {\n    AVCaptureVideoDataOutput *videoOutput")
    string(FIND "${video}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS output setup changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" video "${video}")

    set(before [=[
    [self.videoOutputs setObject:videoOutput forKey:videoConnection];
    [self.captureCallbacks setObject:[[frameCallback copy] autorelease] forKey:videoConnection];
    [self.captureSignals setObject:signal forKey:videoConnection];
]=])
    set(after [=[
    @synchronized(self) {
      [self.videoOutputs setObject:videoOutput forKey:videoConnection];
      FrameCallbackBlock copiedCallback = [frameCallback copy];
      [self.captureCallbacks setObject:copiedCallback forKey:videoConnection];
      [copiedCallback release];
      [self.captureSignals setObject:signal forKey:videoConnection];
    }
    [videoOutput release];
]=])
    string(FIND "${video}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS output maps changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" video "${video}")

    set(before [=[
  [self.videoOutputs release];
  [self.captureCallbacks release];
  [self.captureSignals release];
  [self.session stopRunning];
]=])
    set(after [=[
  [self.session stopRunning];
  [self.videoOutputs release];
  [self.captureCallbacks release];
  [self.captureSignals release];
  [self.session release];
]=])
    string(FIND "${video}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS capture teardown changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" video "${video}")

    set(before [=[
  FrameCallbackBlock callback = [self.captureCallbacks objectForKey:connection];

  if (callback != nil) {
    if (!callback(sampleBuffer)) {
      @synchronized(self) {
        [self.session stopRunning];
        [self.captureCallbacks removeObjectForKey:connection];
        [self.session removeOutput:[self.videoOutputs objectForKey:connection]];
        [self.videoOutputs removeObjectForKey:connection];
        dispatch_semaphore_signal([self.captureSignals objectForKey:connection]);
        [self.captureSignals removeObjectForKey:connection];
        [self.session startRunning];
      }
    }
  }
]=])
    set(after [=[
  FrameCallbackBlock callback;
  @synchronized(self) {
    callback = [[self.captureCallbacks objectForKey:connection] copy];
  }
  if (callback == nil) return;
  bool keepCapturing = callback(sampleBuffer);
  [callback release];
  if (keepCapturing) return;

  // Retire before queuing teardown so later frames cannot stop this output twice.
  @synchronized(self) {
    [self.captureCallbacks removeObjectForKey:connection];
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @synchronized(self.session) {
      dispatch_semaphore_t signal;
      @synchronized(self) {
        signal = [self.captureSignals objectForKey:connection];
      }
      if (!signal) return;
      [self.session stopRunning];
      @synchronized(self) {
        [self.session removeOutput:[self.videoOutputs objectForKey:connection]];
        [self.videoOutputs removeObjectForKey:connection];
      }
      [self.session startRunning];
      // This block retains self until cleanup completes. The waiting C++ owner
      // may release its AVVideo reference as soon as this signal is delivered.
      dispatch_semaphore_signal(signal);
      @synchronized(self) {
        [self.captureSignals removeObjectForKey:connection];
      }
    }
  });
]=])
    string(FIND "${video}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS sample callback changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" video "${video}")
    string(REPLACE "#import \"av_video.h\"" "#import \"${source_root}/src/platform/macos/av_video.h\"" video "${video}")
    file(CONFIGURE OUTPUT "${output}" CONTENT "${video}" @ONLY)
endfunction()
