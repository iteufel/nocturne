#include "EncoderFlags.h"
#include <climits>
#include <cstdio>
#include <cstring>
#include <vector>
extern "C" {
#include <libavutil/opt.h>
}

// Native regression: the same low bitrate, resolution, and recovery keyframe
// cadence that exposed frame-number gaps on the physical iPad.
static bool checkCodec(const char *name, bool baseline) {
    const AVCodec *codec = avcodec_find_encoder_by_name(name);
    AVCodecContext *context = codec ? avcodec_alloc_context3(codec) : nullptr;
    if (!context) return false;
    context->width = 3200;
    context->height = 2400;
    context->pix_fmt = AV_PIX_FMT_NV12;
    context->time_base = AVRational{1, 30};
    context->framerate = AVRational{30, 1};
    context->bit_rate = 3428000; // negotiated video budget at 5 Mbps
    context->gop_size = INT_MAX;
    context->max_b_frames = 0;
    context->flags = baseline ? AV_CODEC_FLAG_CLOSED_GOP | AV_CODEC_FLAG_LOW_DELAY
                              : nocturne::encoderFlags("videotoolbox");
    AVDictionary *options = nullptr;
    av_dict_set(&options, "realtime", "1", 0);
    av_dict_set(&options, "allow_sw", "0", 0);
    if (std::strstr(name, "hevc")) av_dict_set(&options, "max_ref_frames", "1", 0);
    int status = avcodec_open2(context, codec, &options);
    av_dict_free(&options);
    if (status < 0) {
        std::fprintf(stderr, "%s: hardware encoder unavailable (%d)\n", name, status);
        avcodec_free_context(&context);
        return false;
    }
    AVFrame *frame = av_frame_alloc();
    AVPacket *packet = av_packet_alloc();
    frame->format = context->pix_fmt;
    frame->width = context->width;
    frame->height = context->height;
    status = av_frame_get_buffer(frame, 32);
    std::vector<int64_t> received;
    auto drain = [&] {
        int result;
        while ((result = avcodec_receive_packet(context, packet)) == 0) {
            received.push_back(packet->pts);
            av_packet_unref(packet);
        }
        return result == AVERROR(EAGAIN) || result == AVERROR_EOF;
    };
    constexpr int frameCount = 60;
    for (int n = 1; status >= 0 && n <= frameCount; ++n) {
        status = av_frame_make_writable(frame);
        if (status < 0) break;
        for (int y = 0; y < frame->height; ++y) {
            for (int x = 0; x < frame->width; ++x) {
                frame->data[0][y * frame->linesize[0] + x] =
                    ((x / 8 + y / 8 + n) % 2) ? 210 : 30;
            }
        }
        for (int y = 0; y < frame->height / 2; ++y) {
            std::memset(frame->data[1] + y * frame->linesize[1], 128, frame->width);
        }
        frame->pts = n;
        bool keyframe = (n - 1) % 6 == 0;
        frame->pict_type = keyframe ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
        frame->flags = keyframe ? AV_FRAME_FLAG_KEY : 0;
        status = avcodec_send_frame(context, frame);
        if (status >= 0 && !drain()) status = AVERROR_UNKNOWN;
    }
    if (status >= 0) {
        status = avcodec_send_frame(context, nullptr);
        if (status >= 0 && !drain()) status = AVERROR_UNKNOWN;
    }
    bool complete = status >= 0 && received.size() == frameCount;
    for (size_t n = 0; n < received.size(); ++n) complete &= received[n] == int64_t(n + 1);
    std::printf("%s: %zu/%d frames, contiguous timestamps: %s\n",
                name, received.size(), frameCount, complete ? "yes" : "NO");
    av_packet_free(&packet);
    av_frame_free(&frame);
    avcodec_free_context(&context);
    return complete;
}

int main(int argc, char **argv) {
    bool baseline = argc == 2 && std::strcmp(argv[1], "--baseline") == 0;
    bool h264 = checkCodec("h264_videotoolbox", baseline);
    bool hevc = checkCodec("hevc_videotoolbox", baseline);
    if (nocturne::encoderFlags("software") != static_cast<int>(AV_CODEC_FLAG_CLOSED_GOP | AV_CODEC_FLAG_LOW_DELAY)) return 1;
    return h264 && hevc ? 0 : 1;
}
