#pragma once
#include <IOKit/pwr_mgt/IOPMLib.h>

namespace nocturne {
    // An active virtual framebuffer can coexist with sleeping WindowServer
    // rendering. Remote-user activity and idle-sleep prevention do not wake it.
    // Own an explicit display wake alongside the backend's existing sleep guard.
    class CaptureWake {
        IOPMAssertionID assertion_ {kIOPMNullAssertionID};
    public:
        CaptureWake() {
            IOPMAssertionID assertion {kIOPMNullAssertionID};
            if (IOPMAssertionDeclareUserActivity(CFSTR("Nocturne screen capture"), kIOPMUserActiveLocal,
                                                &assertion) == kIOReturnSuccess) {
                assertion_ = assertion;
            }
        }
        ~CaptureWake() {
            if (assertion_ != kIOPMNullAssertionID) IOPMAssertionRelease(assertion_);
        }
        CaptureWake(const CaptureWake &) = delete;
        CaptureWake &operator=(const CaptureWake &) = delete;
        explicit operator bool() const { return assertion_ != kIOPMNullAssertionID; }
    };
}
