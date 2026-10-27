#pragma once
#include "NocturneSession.h"

namespace nocturne {
    inline CGDirectDisplayID captureDisplay(CGDirectDisplayID requested) {
        CFDictionaryRef session = CGSessionCopyCurrentDictionary();
        const bool locked = NocturneSessionIsLocked(session);
        if (session) CFRelease(session);
        // loginwindow renders its password field on the main display. A newly
        // created secondary virtual monitor is black until the user unlocks.
        const auto main = locked ? CGMainDisplayID() : kCGNullDirectDisplay;
        return main != kCGNullDirectDisplay ? main : requested;
    }
}
