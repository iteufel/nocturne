# Generate the same engine video source for packaging and focused regressions.
function(nocturne_video source_root output)
    file(READ "${source_root}/src/video.cpp" video)
    set(before "ctx->flags |= AV_CODEC_FLAG_CLOSED_GOP | AV_CODEC_FLAG_LOW_DELAY;")
    string(FIND "${video}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned engine encoder setup changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "ctx->flags |= nocturne::encoderFlags(encoder.name);" video "${video}")

    # A sleeping Mac can enumerate displays with no active mode. The platform
    # capture factory wakes them; rejecting here prevents that factory running.
    # Keep the upstream DXGI protection on other platforms.
    set(before "      // Since Windows 11 24H2, it is possible that there will be no active devices present")
    set(after "#ifdef __APPLE__\n      return true;  // macOS wakes the selected display before its hardware probe.\n#else\n${before}")
    string(FIND "${video}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned encoder display check changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" video "${video}")
    set(before "      BOOST_LOG(error) << \"No display devices are active at the moment! Cannot probe the encoders.\";\n      return false;")
    string(FIND "${video}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned inactive-display error changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${before}\n#endif" video "${video}")

    # Preserve relative includes without globally adding src/ (its config.h
    # would shadow FFmpeg's internal config.h).
    string(REGEX REPLACE "#include \"([^\"]+)\"" "#include \"${source_root}/src/\\1\"" video "${video}")
    file(CONFIGURE OUTPUT "${output}" CONTENT "#include \"EncoderFlags.h\"\n${video}" @ONLY)
endfunction()
