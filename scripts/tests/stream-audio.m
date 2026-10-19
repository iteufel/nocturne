#define SDL_MAIN_HANDLED
#include <SDL.h>
#include <opus_multistream.h>
#include <Limelight.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define Log(...) ((void)0)
static Uint32 queuedBytes, waitedMs;
static int pendingMs, decodedPackets, failures;
static int decodeFailure, queueFailure, concealmentPackets;
static SDL_AudioStatus playbackStatus;
static uint64_t testTimeMs;

int LiGetPendingAudioDuration(void) { return pendingMs; }
uint64_t LiGetMillis(void) { return testTimeMs; }
int opus_multistream_decode(OpusMSDecoder *decoder, const unsigned char *data, opus_int32 len,
                           opus_int16 *pcm, int frameSize, int fec) {
    decodedPackets++;
    if (data == NULL && len == 0) concealmentPackets++;
    if (decodeFailure) return OPUS_INVALID_PACKET;
    return frameSize;
}
Uint32 SDL_GetQueuedAudioSize(SDL_AudioDeviceID device) { return queuedBytes; }
SDL_AudioStatus SDL_GetAudioDeviceStatus(SDL_AudioDeviceID device) { return playbackStatus; }
void SDL_PauseAudioDevice(SDL_AudioDeviceID device, int pause) { playbackStatus = pause ? SDL_AUDIO_PAUSED : SDL_AUDIO_PLAYING; }
void SDL_ClearQueuedAudio(SDL_AudioDeviceID device) { queuedBytes = 0; }
int SDL_QueueAudio(SDL_AudioDeviceID device, const void *data, Uint32 bytes) {
    if (queueFailure) return -1;
    queuedBytes += bytes;
    return 0;
}
void SDL_Delay(Uint32 ms) {
    waitedMs += ms;
    // A stalled/interrupted output eventually returns; an unbounded wait in the
    // real callback would otherwise prevent both incoming audio and stream stop.
    if (waitedMs >= 200) queuedBytes = 0;
}

#include "audio-under-test.inc"

static void check(int condition, const char *message) {
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message);
    if (!condition) failures++;
}
static void resetAudio(int samplesPerFrame) {
    memset(&audioConfig, 0, sizeof(audioConfig));
    audioConfig.sampleRate = 48000;
    audioConfig.channelCount = 2;
    audioConfig.samplesPerFrame = samplesPerFrame;
    audioFrameSize = samplesPerFrame * 2 * sizeof(short);
    static short samples[960 * 2];
    audioBuffer = samples;
    audioDevice = 1;
    opusDecoder = (OpusMSDecoder *)samples; // Non-null fake, never dereferenced.
    queuedBytes = waitedMs = 0;
    pendingMs = decodedPackets = 0;
    decodeFailure = queueFailure = concealmentPackets = 0;
    playbackStatus = SDL_AUDIO_PLAYING;
    testTimeMs = 0;
#ifdef NOCTURNE_ADAPTIVE_AUDIO
    memset(&audioTiming, 0, sizeof(audioTiming));
#endif
}
int main(void) {
    resetAudio(240);
    pendingMs = 80;
    ArDecodeAndPlaySample("opus", 4);
    check(decodedPackets == 1, "late packets still advance the Opus decoder before PCM is discarded");
    check(queuedBytes == 0, "stale audio is not played after a network burst");

    resetAudio(240);
    queuedBytes = audioFrameSize * 20; // 100 ms of stale output after a route stall.
    ArDecodeAndPlaySample("opus", 4);
    printf("Simulated callback wait: %u ms\n", waitedMs);
    check(waitedMs == 0, "audio receive callback does not wait for queued playback to drain");
    check(queuedBytes <= 48000u * 2 * sizeof(short) * 60 / 1000, "stalled output cannot accumulate more than 60 ms");

    resetAudio(240);
    for (int i = 0; i < 3; i++) ArDecodeAndPlaySample("opus", 4);
    check(playbackStatus == SDL_AUDIO_PAUSED, "playback primes a 20 ms cushion before starting");
    ArDecodeAndPlaySample("opus", 4);
    check(playbackStatus == SDL_AUDIO_PLAYING, "playback starts when the jitter cushion is ready");
    queuedBytes = 0; // Wi-Fi interruption consumes the entire cushion.
    ArDecodeAndPlaySample("opus", 4);
    check(playbackStatus == SDL_AUDIO_PAUSED, "an underrun rebuilds the cushion instead of repeating gaps");

    // Replay a one-second stream in bursts of four 5 ms packets every 20 ms.
    // The receiver must keep consuming packets while playback uses its cushion.
    resetAudio(240);
    int underruns = 0, started = 0;
    for (int millisecond = 0; millisecond < 1000; millisecond++) {
        if (millisecond % 20 == 0) {
            for (int packet = 0; packet < 4; packet++) ArDecodeAndPlaySample("opus", 4);
        }
        if (playbackStatus == SDL_AUDIO_PLAYING) {
            started = 1;
            Uint32 consumed = 48000 * 2 * sizeof(short) / 1000;
            if (queuedBytes < consumed) { underruns++; queuedBytes = 0; }
            else queuedBytes -= consumed;
        }
    }
    check(started && decodedPackets == 200 && waitedMs == 0 && underruns == 0,
          "batched Wi-Fi delivery plays continuously without blocking packet reception");

    resetAudio(240);
    underruns = started = 0;
    const int jitter[] = {0, 6, 1, 3};
    for (int millisecond = 0; millisecond < 1000; millisecond++) {
        for (int packet = 0; packet < 200; packet++) {
            if (millisecond == packet * 5 + jitter[packet % 4]) ArDecodeAndPlaySample("opus", 4);
        }
        if (playbackStatus == SDL_AUDIO_PLAYING) {
            started = 1;
            Uint32 consumed = 48000 * 2 * sizeof(short) / 1000;
            if (queuedBytes < consumed) { underruns++; queuedBytes = 0; }
            else queuedBytes -= consumed;
        }
    }
    printf("Playback gaps with 6 ms arrival jitter: %d ms\n", underruns);
    check(started && decodedPackets == 200 && underruns == 0,
          "small Wi-Fi timing variations do not cause audible gaps");

    // Replay the physical link's 130 ms radio gaps every half second. Packets
    // are delayed together, not lost. After the first recovery, the receiver
    // must preserve audio continuously while keeping latency bounded.
    resetAudio(240);
    int burstGaps = 0;
    Uint32 peakQueued = 0;
    for (int ms = 0; ms < 6000; ms++) {
        testTimeMs = ms;
        int arriving = 0;
        for (int packet = 0; packet < 1200; packet++) {
            int sent = packet * 5, phase = sent % 500;
            int arrival = phase >= 100 && phase < 230 ? sent - phase + 230 : sent;
            if (arrival == ms) arriving++;
        }
        for (int packet = 0; packet < arriving; packet++) {
            pendingMs = (arriving - packet - 1) * 5;
            ArDecodeAndPlaySample("opus", 4);
            if (queuedBytes > peakQueued) peakQueued = queuedBytes;
        }
        if (playbackStatus == SDL_AUDIO_PLAYING) {
            Uint32 consumed = 48000 * 2 * sizeof(short) / 1000;
            if (queuedBytes < consumed) { if (ms >= 1000) burstGaps++; queuedBytes = 0; }
            else queuedBytes -= consumed;
        }
    }
    printf("Playback gaps after adapting to 130 ms bursts: %d ms\n", burstGaps);
    check(burstGaps == 0 && decodedPackets == 1200,
          "recurring 130 ms Wi-Fi gaps preserve continuous audio after adaptation");
    check(peakQueued <= 48000u * 2 * sizeof(short) * 200 / 1000,
          "adaptive audio buffering remains bounded at 200 ms");

    for (int frameSamples = 120; frameSamples <= 960; frameSamples *= 2) {
        resetAudio(frameSamples);
        for (int i = 0; i < 8; i++) ArDecodeAndPlaySample("opus", 4);
        check(queuedBytes <= 48000u * 2 * sizeof(short) * 60 / 1000 && waitedMs == 0,
              "latency cap uses milliseconds for 2.5/5/10/20 ms packets");
    }

    resetAudio(240);
    ArDecodeAndPlaySample(NULL, 0);
    check(concealmentPackets == 1 && queuedBytes == (Uint32)audioFrameSize,
          "missing packets still use Opus packet-loss concealment");

    resetAudio(240);
    decodeFailure = 1;
    ArDecodeAndPlaySample("opus", 4);
    check(queuedBytes == 0 && waitedMs == 0, "a decode error cannot enqueue invalid samples");

    resetAudio(240);
    queueFailure = 1;
    ArDecodeAndPlaySample("opus", 4);
    check(queuedBytes == 0 && playbackStatus == SDL_AUDIO_PAUSED && waitedMs == 0,
          "an output failure leaves playback paused without blocking");

    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
