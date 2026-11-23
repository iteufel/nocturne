# Generate the macOS capture overlay separately so the regression harness can
# compile the same capture method used by the packaged engine.
function(nocturne_macos_capture source_root output)
    set(original "${source_root}/src/platform/macos/display.mm")
    file(READ "${original}" capture)
    set(before "    CGDirectDisplayID display_id {};  ///< Display ID.")
    set(after "${before}\n    CGDirectDisplayID requested_display_id {};  ///< Selected desktop after unlock.")
    string(FIND "${capture}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS capture fields changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" capture "${capture}")

    set(before "    // Print all displays available with their names and ids")
    set(after "    const auto requested_display_id = display_id;\n    display_id = nocturne::captureDisplay(requested_display_id);\n\n${before}")
    string(FIND "${capture}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS display selection changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" capture "${capture}")

    set(before "display->display_id = display_id;")
    set(after "${before}\n    display->requested_display_id = requested_display_id;")
    string(FIND "${capture}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS capture construction changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" capture "${capture}")

    # loginwindow's password screen requires AVFoundation. Rebuild on lock and
    # unlock so an ordinary desktop still uses upstream's ScreenCaptureKit path.
    set(before "policy.prefer_sckit([SCCapture isAvailable])")
    set(after "!nocturne::captureSessionLocked() && ${before}")
    string(FIND "${capture}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS backend selection changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" capture "${capture}")

    # Use the engine's capture reinitialization path so video encoding and input
    # coordinates both follow the new display, without dropping the connection.
    # Check before forwarding a frame, including the first frame after startup.
    set(before "      auto signal = [av_capture capture:^(CMSampleBufferRef sampleBuffer) {")
    set(after [=[
      const auto started = std::chrono::steady_clock::now();
      const bool started_locked = nocturne::captureSessionLocked();
      auto received_sample = std::make_shared<std::atomic_bool>(false);
      auto callback_lock = std::make_shared<std::mutex>();
      __block bool display_changed = false;
      __block std::chrono::steady_clock::time_point next_display_check {};
      auto signal = [av_capture capture:^(CMSampleBufferRef sampleBuffer) {
        received_sample->store(true);
        const auto now = std::chrono::steady_clock::now();
        if (now >= next_display_check) {
          next_display_check = now + std::chrono::milliseconds(250);
          if (nocturne::captureDisplay(requested_display_id) != display_id ||
              nocturne::captureSessionLocked() != started_locked) {
            display_changed = true;
            return false;
          }
        }
]=])
    # Only the streaming capture method gets this check; the encoder's one-frame
    # startup probe must finish normally, even if the lock state changes.
    set(method_start "    capture_e capture(")
    string(FIND "${capture}" "${method_start}" method_position)
    string(FIND "${capture}" "    /**\n     * @brief Allocate an image" method_end)
    if(method_position EQUAL -1 OR method_end EQUAL -1)
        message(FATAL_ERROR "The pinned macOS capture method changed; review the Nocturne overlay")
    endif()
    math(EXPR method_length "${method_end} - ${method_position}")
    string(SUBSTRING "${capture}" ${method_position} ${method_length} method)
    string(FIND "${method}" "${before}" position)
    string(FIND "${method}" "return capture_e::ok;" return_position)
    if(position EQUAL -1 OR return_position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS capture callback changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" replacement "${method}")
    set(before "        if (!push_captured_image_cb(std::move(img_out), true)) {")
    set(after "        std::lock_guard<std::mutex> lock(*callback_lock);\n${before}")
    string(FIND "${replacement}" "${before}" push_position)
    if(push_position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS frame forwarding changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" replacement "${replacement}")
    # A rejected output returns nil, which is not a valid dispatch semaphore.
    set(before "      // FIXME: We should time out if an image isn't returned for a while")
    set(after "      if (!signal) {\n        return capture_e::capture_error;\n      }\n\n${before}")
    string(FIND "${replacement}" "${before}" wait_position)
    if(wait_position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS capture wait changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" replacement "${replacement}")
    set(before [=[
      // FIXME: We should time out if an image isn't returned for a while
      dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);

      return capture_e::ok;
]=])
    set(after [=[
      std::optional<std::chrono::steady_clock::time_point> asleep_since;
      while (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)) != 0) {
        const auto now = std::chrono::steady_clock::now();
        // These checks must also run when AVFoundation delivers NO frames.
        if (nocturne::captureDisplay(requested_display_id) != display_id ||
            nocturne::captureSessionLocked() != started_locked) {
          [av_capture nocturneStopCapture:signal];
          return capture_e::reinit;
        }
        if (CGDisplayIsAsleep(display_id)) {
          if (!asleep_since) asleep_since = now;
          if (now - *asleep_since >= std::chrono::seconds(3)) {
            [av_capture nocturneStopCapture:signal];
            return capture_e::capture_error;
          }
        } else if (asleep_since) {
          [av_capture nocturneStopCapture:signal];
          return capture_e::reinit;
        }
        if (!received_sample->load() && now - started >= std::chrono::seconds(5)) {
          [av_capture nocturneStopCapture:signal];
          return capture_e::capture_error;
        }
        // Poll shutdown even on an unchanged desktop. Serialize with frame
        // delivery because Sunshine's callbacks own shared session state.
        bool keep_capturing;
        {
          std::lock_guard<std::mutex> lock(*callback_lock);
          keep_capturing = push_captured_image_cb(nullptr, false);
        }
        if (!keep_capturing) {
          [av_capture nocturneStopCapture:signal];
          return capture_e::ok;
        }
      }
      return display_changed ? capture_e::reinit : capture_e::ok;
]=])
    string(FIND "${replacement}" "${before}" wait_position)
    if(wait_position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS capture wait changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" replacement "${replacement}")
    string(REPLACE "${method}" "${replacement}" capture "${capture}")
    set(before "      dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);\n\n      return 0;")
    set(after [=[
      if (!signal) {
        return 1;
      }
      // Encoder discovery must not wedge engine startup on a sleeping screen.
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
      while (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)) != 0) {
        if (std::chrono::steady_clock::now() >= deadline) {
          [av_capture nocturneStopCapture:signal];
          return 1;
        }
      }
      return 0;
]=])
    string(FIND "${capture}" "${before}" probe_position)
    if(probe_position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS encoder probe changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" capture "${capture}")

    # The ScreenCaptureKit loop polls its output callback even without frames.
    # Use that same boundary for display/session changes and a first-frame
    # deadline; upstream remains responsible for stopping and draining SCStream.
    set(before "      sc_frame_source_t source {sc_capture};")
    set(after [=[
      if (nocturne::captureSessionLocked()) return capture_e::reinit;
      const auto started = std::chrono::steady_clock::now();
      bool received_sample = false, display_changed = false, startup_timed_out = false;
      auto forward_frame = [&](std::shared_ptr<img_t> image, bool captured) {
        if (nocturne::captureSessionLocked() || nocturne::captureDisplay(requested_display_id) != display_id) {
          display_changed = true;
          return false;
        }
        received_sample = received_sample || captured;
        if (!received_sample && std::chrono::steady_clock::now() - started >= std::chrono::seconds(5)) {
          startup_timed_out = true;
          return false;
        }
        return push_captured_image_cb(std::move(image), captured);
      };
      sc_frame_source_t source {sc_capture};
]=])
    string(FIND "${capture}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned ScreenCaptureKit source changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" capture "${capture}")
    set(before "      const auto status = sckit::run_capture_loop(source, policy, push_captured_image_cb, pull_free_image_cb, process_frame, SCKIT_FRAME_POLL_INTERVAL);")
    set(after [=[
      const auto status = sckit::run_capture_loop(source, policy, forward_frame, pull_free_image_cb, process_frame, SCKIT_FRAME_POLL_INTERVAL);
      if (display_changed) return capture_e::reinit;
      if (startup_timed_out) {
        BOOST_LOG(warning) << "ScreenCaptureKit delivered no initial frame; falling back to AVFoundation";
        policy.note_stream_start_failure();
        return capture_e::reinit;
      }
]=])
    string(FIND "${capture}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned ScreenCaptureKit loop changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" capture "${capture}")
    file(CONFIGURE OUTPUT "${output}" CONTENT "#include <atomic>\n#include <mutex>\n#include \"CaptureDisplay.h\"\n#import \"NocturneAVVideo.h\"\n${capture}" @ONLY)
endfunction()
