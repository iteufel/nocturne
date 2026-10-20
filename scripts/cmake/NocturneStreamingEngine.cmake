include("${CMAKE_CURRENT_LIST_DIR}/NocturneMacOSCapture.cmake")

# Apply source overlays to the pinned engine without editing its checkout.
function(nocturne_streaming_engine)
    if(NOT TARGET sunshine)
        message(FATAL_ERROR "The pinned Sunshine target was not created")
    endif()
    get_filename_component(nocturne_root "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../.." ABSOLUTE)
    set(original "${CMAKE_SOURCE_DIR}/src/video.cpp")
    file(READ "${original}" video)
    set(before "ctx->flags |= AV_CODEC_FLAG_CLOSED_GOP | AV_CODEC_FLAG_LOW_DELAY;")
    string(FIND "${video}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned engine encoder setup changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "ctx->flags |= nocturne::encoderFlags(encoder.name);" video "${video}")
    # Preserve the original file's relative includes without adding src/ to the
    # global search path (its config.h would shadow FFmpeg's internal config.h).
    string(REGEX REPLACE "#include \"([^\"]+)\"" "#include \"${CMAKE_SOURCE_DIR}/src/\\1\"" video "${video}")
    set(generated "${CMAKE_BINARY_DIR}/NocturneVideo.cpp")
    file(CONFIGURE OUTPUT "${generated}" CONTENT "#include \"EncoderFlags.h\"\n${video}" @ONLY)
    get_target_property(sources sunshine SOURCES)
    list(REMOVE_ITEM sources "${original}")
    list(APPEND sources "${generated}")
    set(macos_capture "${CMAKE_BINARY_DIR}/NocturneMacOSDisplay.mm")
    nocturne_macos_capture("${CMAKE_SOURCE_DIR}" "${macos_capture}")
    list(REMOVE_ITEM sources "${CMAKE_SOURCE_DIR}/src/platform/macos/display.mm")
    list(APPEND sources "${macos_capture}")
    set_property(TARGET sunshine PROPERTY SOURCES "${sources}")
    target_include_directories(sunshine PRIVATE "${nocturne_root}/Sources/StreamingEngine" "${nocturne_root}/Sources/DisplayBridge/include")

    # Reuse the verified runtime libraries, which retain the release's macOS
    # compatibility. Homebrew supplies headers only, not runtime dependencies.
    set(nocturne_miniupnpc "${nocturne_root}/Vendor/StreamingRuntime/Contents/Frameworks/libminiupnpc.21.dylib")
    if(NOT EXISTS "${nocturne_miniupnpc}")
        message(FATAL_ERROR "Run scripts/fetch-sunshine.sh to prepare the runtime libraries")
    endif()
    get_target_property(libraries sunshine LINK_LIBRARIES)
    list(TRANSFORM libraries REPLACE "^miniupnpc$" "${nocturne_miniupnpc}")
    set_property(TARGET sunshine PROPERTY LINK_LIBRARIES "${libraries}")
endfunction()

# This project hook runs before the target is declared. Defer until its sources
# and platform options are complete, and do not apply to dependency projects.
if(CMAKE_SOURCE_DIR STREQUAL PROJECT_SOURCE_DIR)
    cmake_language(DEFER CALL nocturne_streaming_engine)
endif()
