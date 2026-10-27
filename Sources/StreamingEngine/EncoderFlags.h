#pragma once

#include <string_view>
extern "C" {
#include <libavcodec/avcodec.h>
}

namespace nocturne {
inline int encoderFlags(std::string_view encoder) {
    // VideoToolbox's low-latency rate controller can drop complete frames at
    // low bitrates. GameStream interprets the resulting PTS gaps as packet loss
    // and requests another large keyframe, sustaining the drop/recovery loop.
    // Keep real-time hardware encoding and max_b_frames=0 in the upstream
    // configuration; only opt out of this rate controller.
    return static_cast<int>(AV_CODEC_FLAG_CLOSED_GOP |
        (encoder == "videotoolbox" ? 0 : AV_CODEC_FLAG_LOW_DELAY));
}
}
