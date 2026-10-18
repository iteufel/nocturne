#include "NocturneMicrophone.h"

AudioDeviceID NocturneMicFindDevice(void) {
    CFStringRef uid = NOCTURNE_MIC_UID;
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(uid), &uid, &size, &device) != noErr) return kAudioObjectUnknown;
    CFNumberRef value = NULL; SInt32 version = 0;
    size = sizeof(value); address.mSelector = NocturneMicVersionProperty;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr) return kAudioObjectUnknown;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberSInt32Type, &version);
        CFRelease(value);
    }
    if (version != NocturneMicVersion) return kAudioObjectUnknown;
    return device;
}

OSStatus NocturneMicSetControl(AudioDeviceID device, UInt32 control) {
    AudioObjectPropertyAddress address = { NocturneMicControlProperty, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberSInt32Type, &control);
    OSStatus result = AudioObjectSetPropertyData(device, &address, 0, NULL, sizeof(value), &value);
    CFRelease(value); return result;
}

OSStatus NocturneMicWrite(AudioDeviceID device, const void *pcm, UInt32 bytes) {
    if (bytes != NocturneMicFrameSamples * sizeof(SInt16)) return kAudioHardwareBadPropertySizeError;
    AudioObjectPropertyAddress address = { NocturneMicAudioProperty, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef value = CFDataCreate(NULL, pcm, bytes);
    OSStatus result = AudioObjectSetPropertyData(device, &address, 0, NULL, sizeof(value), &value);
    CFRelease(value); return result;
}
