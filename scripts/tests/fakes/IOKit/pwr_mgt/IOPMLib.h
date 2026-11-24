#pragma once
#include <cstdint>
using CFStringRef = const char *;
using IOPMAssertionID = std::uint32_t;
using IOReturn = int;
enum IOPMUserActiveType { kIOPMUserActiveLocal, kIOPMUserActiveRemote };
constexpr IOPMAssertionID kIOPMNullAssertionID = 0;
constexpr IOReturn kIOReturnSuccess = 0;
#define CFSTR(value) value
IOReturn IOPMAssertionDeclareUserActivity(CFStringRef, IOPMUserActiveType, IOPMAssertionID *);
IOReturn IOPMAssertionRelease(IOPMAssertionID);
