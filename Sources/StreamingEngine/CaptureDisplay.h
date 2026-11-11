#pragma once
#include "NocturneSession.h"

namespace nocturne {
    inline bool captureSessionLocked() {
        CFDictionaryRef session = CGSessionCopyCurrentDictionary();
        const bool locked = NocturneSessionIsLocked(session);
        if (session) CFRelease(session);
        return locked;
    }
    inline CGDirectDisplayID captureDisplay(CGDirectDisplayID requested) {
        // loginwindow renders its password field on the main display. A newly
        // created secondary virtual monitor is black until the user unlocks.
        const auto main = captureSessionLocked() ? CGMainDisplayID() : kCGNullDirectDisplay;
        // After unplugging a monitor, WindowServer can report its inactive ID or
        // a headless placeholder as main. Keep the usable virtual framebuffer.
        return main != kCGNullDirectDisplay && CGDisplayIsActive(main) &&
            CGDisplayModelNumber(main) != 0x76697274 ? main : requested;
    }
}
