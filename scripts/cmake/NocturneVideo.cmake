# Generate the same engine video source for packaging and focused regressions.
function(nocturne_video source_root output)
    file(READ "${source_root}/src/video.cpp" video)
    set(before "ctx->flags |= AV_CODEC_FLAG_CLOSED_GOP | AV_CODEC_FLAG_LOW_DELAY;")
    string(FIND "${video}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned engine encoder setup changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "ctx->flags |= nocturne::encoderFlags(encoder.name);" video "${video}")

    # Upstream now permits probing sleeping displays outside Windows, allowing
    # the macOS capture factory to wake them. Keep that platform policy intact.

    # Preserve relative includes without globally adding src/ (its config.h
    # would shadow FFmpeg's internal config.h).
    string(REGEX REPLACE "#include \"([^\"]+)\"" "#include \"${source_root}/src/\\1\"" video "${video}")
    file(CONFIGURE OUTPUT "${output}" CONTENT "#include \"EncoderFlags.h\"\n${video}" @ONLY)
endfunction()
