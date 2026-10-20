#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

static inline bool NocturneSessionFlag(CFDictionaryRef session, CFStringRef key) {
    if (!session) return false;
    CFTypeRef value = CFDictionaryGetValue(session, key);
    if (!value) return false;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) return CFBooleanGetValue((CFBooleanRef)value);
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int flag = 0;
        return CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &flag) && flag != 0;
    }
    return false;
}

// A locked desktop still belongs to the signed-in console user. Logging out or
// switching to another user is different: Nocturne must not manage that session.
static inline bool NocturneSessionIsAvailable(CFDictionaryRef session) {
    return NocturneSessionFlag(session, kCGSessionOnConsoleKey) &&
        NocturneSessionFlag(session, kCGSessionLoginDoneKey);
}

static inline bool NocturneSessionIsLocked(CFDictionaryRef session) {
    return NocturneSessionIsAvailable(session) &&
        NocturneSessionFlag(session, CFSTR("CGSSessionScreenIsLocked"));
}
