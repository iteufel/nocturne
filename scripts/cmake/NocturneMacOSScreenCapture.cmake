function(nocturne_macos_screen_capture source_root output)
    file(READ "${source_root}/src/platform/macos/sc_capture.mm" capture)
    set(before [=[
static SCShareableContent *copyShareableContent(void) {
  __block SCShareableContent *shareableContent = nil;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

  [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *content_error) {
    if (content_error) {
      BOOST_LOG(error) << "SCCapture failed to get shareable content: "sv << error_description(content_error);
    } else {
      shareableContent = [content retain];
    }

    dispatch_semaphore_signal(semaphore);
  }];

  dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
  dispatch_release(semaphore);

  return shareableContent;
}
]=])
    set(after [=[
static SCShareableContent *copyShareableContent(void) {
  auto reply = std::make_shared<nocturne::CaptureStartup>();
  [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *content_error) {
    if (content_error) {
      BOOST_LOG(error) << "SCCapture failed to get shareable content: "sv << error_description(content_error);
    }
    reply->finish(content_error ? nil : content);
  }];
  if (!reply->wait()) {
    BOOST_LOG(error) << "SCCapture timed out getting shareable content";
    return nil;
  }
  return (SCShareableContent *)reply->copyValue();
}
]=])
    string(FIND "${capture}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned ScreenCaptureKit content lookup changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" capture "${capture}")

    set(before [=[
  __block NSError *start_error = nil;
  dispatch_semaphore_t started = dispatch_semaphore_create(0);
  [stream startCaptureWithCompletionHandler:^(NSError *completion_error) {
    start_error = [completion_error retain];
    dispatch_semaphore_signal(started);
  }];
  dispatch_semaphore_wait(started, DISPATCH_TIME_FOREVER);
  dispatch_release(started);
]=])
    set(after [=[
  auto started = std::make_shared<nocturne::CaptureStartup>();
  [stream startCaptureWithCompletionHandler:^(NSError *completion_error) {
    if (!started->finish(completion_error)) {
      // A late successful start must not leave an abandoned stream capturing.
      [stream stopCaptureWithCompletionHandler:^(NSError *stop_error) {}];
    }
  }];
  if (!started->wait()) {
    BOOST_LOG(error) << "SCCapture timed out starting capture stream";
    [stream stopCaptureWithCompletionHandler:^(NSError *stop_error) {}];
    [stream release];
    return nil;
  }
  NSError *start_error = (NSError *)started->copyValue();
]=])
    string(FIND "${capture}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned ScreenCaptureKit stream startup changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" capture "${capture}")
    string(REPLACE "#import \"sc_capture.h\"" "#import \"${source_root}/src/platform/macos/sc_capture.h\"" capture "${capture}")
    file(CONFIGURE OUTPUT "${output}" CONTENT "#include \"CaptureStartup.h\"\n${capture}" @ONLY)
endfunction()
