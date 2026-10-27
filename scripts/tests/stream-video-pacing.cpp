#include "StreamVideoPacing.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>

struct Frame { double sent, arrival; };
static bool replay(unsigned rate, unsigned refresh, bool baseline, bool jittery) {
    NocturneVideoPacer pacer;
    NocturneVideoPacerReset(&pacer, rate, false);
    std::deque<Frame> queued;
    unsigned generated = 0, rendered = 0;
    double lastOutput = -1, maxGap = 0, maxAge = 0;
    // At 120 fps the upstream 15-frame queue cannot hold a 130 ms burst.
    // Exercise a shorter burst there and check the capacity bound separately.
    double burst = rate == 120 ? 0.075 : 0.13;
    for (unsigned tick = 0; tick < refresh * 10; tick++) {
        double now = (double)tick / refresh;
        while (true) {
            double sent = (double)generated / rate;
            double phase = fmod(sent + 0.000001, 0.5);
            double arrival = jittery && phase >= 0.1 && phase < 0.1 + burst ? sent - phase + 0.1 + burst : sent;
            if (arrival > now + 0.000001) break;
            queued.push_back({sent, arrival}); generated++;
        }
        unsigned budget = baseline ? (unsigned)queued.size() : NocturneVideoPacerBudget(&pacer, (unsigned)queued.size(), now);
        bool displayed = false;
        while (budget-- && !queued.empty()) {
            auto frame = queued.front(); queued.pop_front(); rendered++;
            if (!baseline) NocturneVideoPacerObserve(&pacer, (uint64_t)(frame.arrival * 1000000), (uint64_t)(frame.sent * 1000000));
            if (now >= 1) maxAge = std::max(maxAge, now - frame.sent);
            displayed = true;
            if (!baseline && pacer.priming) break;
        }
        if (displayed) {
            if (now >= 1 && lastOutput >= 0) maxGap = std::max(maxGap, now - lastOutput);
            lastOutput = now;
        }
    }
    double allowedGap = 1.0 / std::min(rate, refresh) + 0.0001;
    bool ok = maxGap <= allowedGap && maxAge < 0.201 && generated - rendered <= rate / 5;
    if (!jittery) ok &= pacer.cushionFrames == 0;
    std::printf("%s %u fps / %u Hz / %s: max gap %.1f ms, max age %.1f ms, buffered %u frames\n",
        ok ? "PASS" : "FAIL", rate, refresh, jittery ? (rate == 120 ? "75 ms bursts" : "130 ms bursts") : "steady link", maxGap * 1000, maxAge * 1000, pacer.cushionFrames);
    return ok;
}
int main(int argc, char **argv) {
    bool baseline = argc == 2 && !std::strcmp(argv[1], "--baseline");
    bool ok = true;
    for (unsigned rate : {30u, 60u, 120u}) {
        ok &= replay(rate, rate, baseline, true);
        ok &= replay(rate, rate, baseline, false);
    }
    ok &= replay(30, 60, baseline, true);
    ok &= replay(60, 30, baseline, true);
    NocturneVideoPacer highRate;
    NocturneVideoPacerReset(&highRate, 120, false);
    NocturneVideoPacerObserve(&highRate, 0, 0);
    NocturneVideoPacerObserve(&highRate, 250000, 8333);
    bool bounded = highRate.cushionFrames <= 12 && NocturneVideoPacerBudget(&highRate, 15, 1) > 0;
    std::printf("%s: high-rate priming fits within the upstream 15-frame queue\n", bounded ? "PASS" : "FAIL");
    ok &= bounded;
    return ok ? 0 : 1;
}
