#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <math.h>

// The decoder queue remains owned by moonlight-common. Keep enough frames there
// to cover observed network bursts, then release them at the stream cadence.
typedef struct {
    unsigned frameRate, cushionFrames;
    bool priming, hasTiming;
    uint64_t receiveUs, presentationUs;
    double nextFrameTime;
} NocturneVideoPacer;

static inline void NocturneVideoPacerReset(NocturneVideoPacer *p, unsigned rate, bool pacing) {
    *p = (NocturneVideoPacer){.frameRate = rate ? rate : 60,
        .cushionFrames = pacing ? 1u : 0u, .priming = pacing};
}

static inline void NocturneVideoPacerObserve(NocturneVideoPacer *p, uint64_t receiveUs, uint64_t presentationUs) {
    if (p->hasTiming && receiveUs >= p->receiveUs && presentationUs > p->presentationUs) {
        double arrivalGap = (double)(receiveUs - p->receiveUs);
        double sourceGap = (double)(presentationUs - p->presentationUs);
        double jitter = arrivalGap - sourceGap;
        double frameUs = 1000000.0 / p->frameRate;
        if (jitter > frameUs && arrivalGap < 1000000) {
            unsigned cushion = (unsigned)ceil((jitter + 10000) / frameUs);
            unsigned maximum = p->frameRate * 150 / 1000;
            if (maximum < 1) maximum = 1;
            // moonlight-common's queue holds 15 frames. Leave room for a
            // display tick and incoming frames; priming must remain reachable.
            if (maximum > 12) maximum = 12;
            if (cushion > maximum) cushion = maximum;
            if (cushion > p->cushionFrames) {
                p->cushionFrames = cushion;
                p->priming = true;
            }
        }
    }
    p->hasTiming = true;
    p->receiveUs = receiveUs;
    p->presentationUs = presentationUs;
}

static inline unsigned NocturneVideoPacerBudget(NocturneVideoPacer *p, unsigned pending, double now) {
    if (!p->cushionFrames) return pending;
    if (!pending) { p->priming = true; return 0; }
    if (p->priming) {
        if (pending <= p->cushionFrames) return 0;
        p->priming = false;
        p->nextFrameTime = now;
    }
    // Accommodate displays slower or faster than the negotiated stream rate.
    // A small tolerance avoids alternating ticks due to timer rounding.
    double due = (now - p->nextFrameTime) * p->frameRate;
    if (due < -0.01) return 0;
    unsigned budget = (unsigned)floor(due + 0.01) + 1;
    p->nextFrameTime += (double)budget / p->frameRate;
    // Catch up after a suspended app/display without retaining stale video.
    if (pending > p->cushionFrames + budget + 2) budget = pending - p->cushionFrames;
    return budget < pending ? budget : pending;
}
