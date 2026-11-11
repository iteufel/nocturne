include("${CMAKE_CURRENT_LIST_DIR}/NocturneMacOSCapture.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/NocturneMacOSVideo.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/NocturneVideo.cmake")

# Apply source overlays to the pinned engine without editing its checkout.
function(nocturne_streaming_engine)
    if(NOT TARGET sunshine)
        message(FATAL_ERROR "The pinned Sunshine target was not created")
    endif()
    get_filename_component(nocturne_root "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../.." ABSOLUTE)
    set(original "${CMAKE_SOURCE_DIR}/src/video.cpp")
    set(generated "${CMAKE_BINARY_DIR}/NocturneVideo.cpp")
    nocturne_video("${CMAKE_SOURCE_DIR}" "${generated}")
    get_target_property(sources sunshine SOURCES)
    list(REMOVE_ITEM sources "${original}")
    list(APPEND sources "${generated}")
    set(macos_capture "${CMAKE_BINARY_DIR}/NocturneMacOSDisplay.mm")
    nocturne_macos_capture("${CMAKE_SOURCE_DIR}" "${macos_capture}")
    list(REMOVE_ITEM sources "${CMAKE_SOURCE_DIR}/src/platform/macos/display.mm")
    list(APPEND sources "${macos_capture}")
    set(macos_video "${CMAKE_BINARY_DIR}/NocturneMacOSVideo.m")
    nocturne_macos_video("${CMAKE_SOURCE_DIR}" "${macos_video}")
    list(REMOVE_ITEM sources "${CMAKE_SOURCE_DIR}/src/platform/macos/av_video.m")
    list(APPEND sources "${macos_video}")
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
