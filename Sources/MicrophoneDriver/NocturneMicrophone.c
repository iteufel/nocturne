// A fixed-format, input-only Core Audio HAL plug-in. No hardware, kernel extension,
// sockets, filesystem access, or default-device changes are required by the driver.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <math.h>
#include <string.h>
#include "../MicrophoneBridge/include/NocturneMicrophone.h"

enum { Plugin = kAudioObjectPlugInObject, Device = 2, Stream = 3, Period = 480, Capacity = 24000, Lead = 2880 };
static AudioServerPlugInDriverInterface interface;
static AudioServerPlugInDriverInterface *interfacePointer = &interface;
static AudioServerPlugInDriverRef driver = &interfacePointer;
static AudioServerPlugInHostRef host;
static atomic_uint references = 1, ioClients = 0, streamActive = 1;
static uint64_t anchor;
static double ticksPerFrame;
static pthread_mutex_t audioLock = PTHREAD_MUTEX_INITIALIZER;
static float samples[Capacity];
static int64_t tags[Capacity], writeFrame;
static pid_t producer;
static uint64_t lastWrite;

static bool valid(AudioServerPlugInDriverRef ref, AudioObjectID object) {
    return ref == driver && (object == Plugin || object == Device || object == Stream);
}
static int64_t frameAt(uint64_t ticks) { return (int64_t)((ticks - anchor) / ticksPerFrame); }
static bool expired(uint64_t ticks) { return producer && (ticks - lastWrite) / ticksPerFrame >= NocturneMicRate * 2; }
static void clearAudio(void) {
    memset(samples, 0, sizeof(samples));
    for (int i = 0; i < Capacity; ++i) tags[i] = -1;
    writeFrame = 0;
}
static AudioStreamBasicDescription format(void) {
    return (AudioStreamBasicDescription){ .mSampleRate = NocturneMicRate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked, .mBytesPerPacket = sizeof(float),
        .mFramesPerPacket = 1, .mBytesPerFrame = sizeof(float), .mChannelsPerFrame = 1, .mBitsPerChannel = 32 };
}

static ULONG addRef(void *ref) { return ref == driver ? atomic_fetch_add(&references, 1) + 1 : 0; }
static ULONG release(void *ref) {
    if (ref != driver) return 0;
    unsigned value = atomic_load(&references);
    while (value && !atomic_compare_exchange_weak(&references, &value, value - 1)) {}
    return value ? value - 1 : 0;
}
static HRESULT query(void *ref, REFIID iid, LPVOID *result) {
    if (ref != driver || !result) return E_NOINTERFACE;
    *result = NULL;
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, iid);
    bool supported = CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(uuid);
    if (!supported) return E_NOINTERFACE;
    addRef(ref); *result = driver; return S_OK;
}
__attribute__((visibility("default")))
void *NocturneMicrophoneFactory(CFAllocatorRef allocator, CFUUIDRef type) {
    return CFEqual(type, kAudioServerPlugInTypeUUID) ? driver : NULL;
}
static OSStatus initialize(AudioServerPlugInDriverRef ref, AudioServerPlugInHostRef newHost) {
    if (ref != driver) return kAudioHardwareBadObjectError;
    host = newHost;
    mach_timebase_info_data_t timebase; mach_timebase_info(&timebase);
    ticksPerFrame = 1e9 * timebase.denom / timebase.numer / NocturneMicRate;
    anchor = mach_absolute_time(); clearAudio(); producer = 0;
    return noErr;
}
static OSStatus createDevice(AudioServerPlugInDriverRef ref, CFDictionaryRef description, const AudioServerPlugInClientInfo *client, AudioObjectID *device) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus destroyDevice(AudioServerPlugInDriverRef ref, AudioObjectID device) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus deviceClient(AudioServerPlugInDriverRef ref, AudioObjectID device, const AudioServerPlugInClientInfo *client) {
    return ref == driver && device == Device ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus configuration(AudioServerPlugInDriverRef ref, AudioObjectID device, UInt64 action, void *info) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus propertySize(AudioServerPlugInDriverRef ref, AudioObjectID object, pid_t pid,
    const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 *size) {
    if (!valid(ref, object)) return kAudioHardwareBadObjectError;
    if (!address || !size) return kAudioHardwareIllegalOperationError;
    if (address->mElement != kAudioObjectPropertyElementMain) return kAudioHardwareUnknownPropertyError;
    UInt32 selector = address->mSelector, scope = address->mScope;
    if (scope != kAudioObjectPropertyScopeGlobal && (object != Device || (scope != kAudioObjectPropertyScopeInput && scope != kAudioObjectPropertyScopeOutput))) return kAudioHardwareUnknownPropertyError;
    switch (selector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
            *size = sizeof(UInt32); return noErr;
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer:
            *size = sizeof(CFStringRef); return noErr;
        case kAudioObjectPropertyOwnedObjects:
            *size = object == Stream || scope == kAudioObjectPropertyScopeOutput ? 0 : sizeof(AudioObjectID); return noErr;
    }
    if (object == Plugin) {
        switch (selector) {
            case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
                *size = sizeof(AudioObjectID); return noErr;
            case kAudioPlugInPropertyResourceBundle: *size = sizeof(CFStringRef); return noErr;
            case kAudioPlugInPropertyBoxList: case kAudioPlugInPropertyClockDeviceList: *size = 0; return noErr;
        }
    } else if (object == Device) {
        switch (selector) {
            case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID:
                *size = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyTransportType: case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod:
                *size = sizeof(UInt32); return noErr;
            case NocturneMicVersionProperty: case NocturneMicControlProperty: case NocturneMicAudioProperty:
                *size = sizeof(CFPropertyListRef); return noErr;
            case kAudioObjectPropertyCustomPropertyInfoList: *size = 3 * sizeof(AudioServerPlugInCustomPropertyInfo); return noErr;
            case kAudioDevicePropertyRelatedDevices: *size = sizeof(AudioObjectID); return noErr;
            case kAudioDevicePropertyStreams: *size = scope == kAudioObjectPropertyScopeOutput ? 0 : sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyControlList: *size = 0; return noErr;
            case kAudioDevicePropertyNominalSampleRate: *size = sizeof(Float64); return noErr;
            case kAudioDevicePropertyAvailableNominalSampleRates: *size = sizeof(AudioValueRange); return noErr;
            case kAudioDevicePropertyPreferredChannelLayout: *size = sizeof(AudioChannelLayout); return noErr;
        }
    } else {
        switch (selector) {
            case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
                *size = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
                *size = sizeof(AudioStreamBasicDescription); return noErr;
            case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
                *size = sizeof(AudioStreamRangedDescription); return noErr;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}
static Boolean hasProperty(AudioServerPlugInDriverRef ref, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *address) {
    UInt32 size; return propertySize(ref, object, pid, address, 0, NULL, &size) == noErr;
}
static OSStatus settable(AudioServerPlugInDriverRef ref, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *address, Boolean *result) {
    if (!hasProperty(ref, object, pid, address)) return kAudioHardwareUnknownPropertyError;
    if (!result) return kAudioHardwareIllegalOperationError;
    *result = (object == Device && (address->mSelector == NocturneMicControlProperty || address->mSelector == NocturneMicAudioProperty)) ||
        (object == Stream && address->mSelector == kAudioStreamPropertyIsActive);
    return noErr;
}
static OSStatus getProperty(AudioServerPlugInDriverRef ref, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize, const void *qualifier, UInt32 available, UInt32 *used, void *data) {
    UInt32 size = 0;
    OSStatus status = propertySize(ref, object, pid, address, qualifierSize, qualifier, &size);
    if (status != noErr) return status;
    if (!used || (size && !data)) return kAudioHardwareIllegalOperationError;
    if (available < size) return kAudioHardwareBadPropertySizeError;
    *used = size; if (!size) return noErr;
    UInt32 value = 0;
    CFStringRef string = NULL;
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: value = kAudioObjectClassID; break;
        case kAudioObjectPropertyClass: value = object == Plugin ? kAudioPlugInClassID : object == Device ? kAudioDeviceClassID : kAudioStreamClassID; break;
        case kAudioObjectPropertyOwner: value = object == Plugin ? kAudioObjectUnknown : object == Device ? Plugin : Device; break;
        case kAudioObjectPropertyName: string = NOCTURNE_MIC_NAME; break;
        case kAudioObjectPropertyManufacturer: string = CFSTR("Nocturne"); break;
        case kAudioObjectPropertyOwnedObjects: value = object == Plugin ? Device : Stream; break;
        case kAudioPlugInPropertyDeviceList: case kAudioDevicePropertyRelatedDevices: value = Device; break;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            if (qualifierSize != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
            value = CFEqual(*(CFStringRef const *)qualifier, NOCTURNE_MIC_UID) ? Device : kAudioObjectUnknown; break;
        case kAudioPlugInPropertyResourceBundle: string = CFSTR(""); break;
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: string = NOCTURNE_MIC_UID; break;
        case kAudioDevicePropertyTransportType: value = kAudioDeviceTransportTypeVirtual; break;
        case kAudioDevicePropertyDeviceIsAlive: value = 1; break;
        case kAudioDevicePropertyDeviceIsRunning: value = atomic_load(&ioClients) > 0; break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: value = address->mScope == kAudioObjectPropertyScopeInput; break;
        case kAudioDevicePropertyZeroTimeStampPeriod: value = Period; break;
        case kAudioDevicePropertyStreams: value = Stream; break;
        case NocturneMicVersionProperty: case NocturneMicControlProperty: {
            SInt32 number = address->mSelector == NocturneMicVersionProperty ? NocturneMicVersion : 0;
            CFNumberRef result = CFNumberCreate(NULL, kCFNumberSInt32Type, &number);
            memcpy(data, &result, size); return noErr;
        }
        case NocturneMicAudioProperty: {
            // Never expose captured samples through properties.
            CFDataRef result = CFDataCreate(NULL, NULL, 0); memcpy(data, &result, size); return noErr;
        }
        case kAudioObjectPropertyCustomPropertyInfoList: {
            AudioServerPlugInCustomPropertyInfo properties[] = {
                {NocturneMicVersionProperty, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone},
                {NocturneMicControlProperty, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone},
                {NocturneMicAudioProperty, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone}
            };
            memcpy(data, properties, size); return noErr;
        }
        case kAudioDevicePropertyNominalSampleRate: { Float64 rate = NocturneMicRate; memcpy(data, &rate, size); return noErr; }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange range = {NocturneMicRate, NocturneMicRate}; memcpy(data, &range, size); return noErr;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            AudioChannelLayout layout = {0}; layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
            memcpy(data, &layout, size); return noErr;
        }
        case kAudioStreamPropertyIsActive: value = atomic_load(&streamActive); break;
        case kAudioStreamPropertyDirection: case kAudioStreamPropertyStartingChannel: value = 1; break;
        case kAudioStreamPropertyTerminalType: value = kAudioStreamTerminalTypeMicrophone; break;
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription description = format(); memcpy(data, &description, size); return noErr;
        }
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription description = {format(), {NocturneMicRate, NocturneMicRate}};
            memcpy(data, &description, size); return noErr;
        }
        default: break; // Zero latency, safety offset, clock domain, hidden, and system-default flags.
    }
    if (string) { CFRetain(string); memcpy(data, &string, sizeof(string)); }
    else memcpy(data, &value, sizeof(value));
    return noErr;
}
static OSStatus setProperty(AudioServerPlugInDriverRef ref, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize, const void *qualifier, UInt32 size, const void *data) {
    Boolean writable = false;
    OSStatus status = settable(ref, object, pid, address, &writable);
    if (status != noErr) return status;
    if (!writable) return kAudioHardwareUnsupportedOperationError;
    if (!data) return kAudioHardwareIllegalOperationError;
    if (object == Stream) {
        if (size != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        UInt32 active; memcpy(&active, data, size);
        if (active > 1) return kAudioHardwareIllegalOperationError;
        atomic_store(&streamActive, active);
        if (host) host->PropertiesChanged(host, Stream, 1, address);
        return noErr;
    }
    if (pid <= 0) return kAudioHardwareIllegalOperationError;
    // Custom properties cross the coreaudiod process boundary. Only CF property
    // lists/strings are marshalled by HAL; raw byte structs are not supported.
    if (size != sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
    CFPropertyListRef property; memcpy(&property, data, size);
    if (!property) return kAudioHardwareIllegalOperationError;
    uint64_t ticks = mach_absolute_time();
    pthread_mutex_lock(&audioLock);
    if (expired(ticks)) { producer = 0; clearAudio(); }
    if (address->mSelector == NocturneMicControlProperty) {
        SInt32 command;
        if (CFGetTypeID(property) != CFNumberGetTypeID() || !CFNumberGetValue(property, kCFNumberSInt32Type, &command)) {
            status = kAudioHardwareIllegalOperationError; goto done;
        }
        if (command == NocturneMicStart && !producer) {
            clearAudio(); producer = pid; lastWrite = ticks;
        } else if (command == NocturneMicStop && (!producer || producer == pid)) {
            clearAudio(); producer = 0;
        } else status = kAudioHardwareIllegalOperationError;
    } else {
        if (CFGetTypeID(property) != CFDataGetTypeID() || CFDataGetLength(property) != NocturneMicFrameSamples * sizeof(SInt16)) {
            status = kAudioHardwareBadPropertySizeError; goto done;
        }
        if (producer != pid) { status = kAudioHardwareIllegalOperationError; goto done; }
        int64_t now = frameAt(ticks);
        // Bound latency under packet bursts and clock drift. No old speech is replayed
        // after a stall; tags also let multiple recording apps read the same timeline.
        if (writeFrame < now || writeFrame > now + NocturneMicRate / 4) { clearAudio(); writeFrame = now + Lead; }
        const uint8_t *bytes = CFDataGetBytePtr(property);
        for (int i = 0; i < NocturneMicFrameSamples; ++i, ++writeFrame) {
            int index = (int)(writeFrame % Capacity);
            SInt16 sample = (SInt16)((UInt16)bytes[2*i] | ((UInt16)bytes[2*i+1] << 8));
            samples[index] = (float)sample / 32768.0f; tags[index] = writeFrame;
        }
        lastWrite = ticks;
    }
done:
    pthread_mutex_unlock(&audioLock); return status;
}

static OSStatus startIO(AudioServerPlugInDriverRef ref, AudioObjectID device, UInt32 client) {
    if (ref != driver || device != Device) return kAudioHardwareBadObjectError;
    atomic_fetch_add(&ioClients, 1); return noErr;
}
static OSStatus stopIO(AudioServerPlugInDriverRef ref, AudioObjectID device, UInt32 client) {
    if (ref != driver || device != Device) return kAudioHardwareBadObjectError;
    unsigned count = atomic_load(&ioClients);
    while (count && !atomic_compare_exchange_weak(&ioClients, &count, count - 1)) {}
    return noErr;
}
static OSStatus zeroTime(AudioServerPlugInDriverRef ref, AudioObjectID device, UInt32 client, Float64 *sample, UInt64 *ticks, UInt64 *seed) {
    if (ref != driver || device != Device) return kAudioHardwareBadObjectError;
    int64_t boundary = (frameAt(mach_absolute_time()) / Period) * Period;
    *sample = boundary; *ticks = anchor + (UInt64)(boundary * ticksPerFrame); *seed = 1; return noErr;
}
static OSStatus willIO(AudioServerPlugInDriverRef ref, AudioObjectID device, UInt32 client, UInt32 operation, Boolean *will, Boolean *inPlace) {
    if (ref != driver || device != Device) return kAudioHardwareBadObjectError;
    *will = operation == kAudioServerPlugInIOOperationReadInput; *inPlace = true; return noErr;
}
static OSStatus beginEndIO(AudioServerPlugInDriverRef ref, AudioObjectID device, UInt32 client, UInt32 operation, UInt32 count, const AudioServerPlugInIOCycleInfo *cycle) {
    return ref == driver && device == Device ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus doIO(AudioServerPlugInDriverRef ref, AudioObjectID device, AudioObjectID stream, UInt32 client, UInt32 operation,
    UInt32 count, const AudioServerPlugInIOCycleInfo *cycle, void *main, void *secondary) {
    if (ref != driver || device != Device || stream != Stream) return kAudioHardwareBadObjectError;
    if (operation != kAudioServerPlugInIOOperationReadInput) return kAudioHardwareUnsupportedOperationError;
    if (!main || !cycle) return kAudioHardwareIllegalOperationError;
    memset(main, 0, count * sizeof(float));
    // Never block, allocate, or call the host on the real-time callback.
    if (!atomic_load(&streamActive) || pthread_mutex_trylock(&audioLock) != 0) return noErr;
    double time = cycle->mInputTime.mSampleTime;
    if (producer && !expired(mach_absolute_time()) && isfinite(time) && time >= 0 && time < INT64_MAX - count) {
        int64_t first = (int64_t)time;
        float *output = main;
        for (UInt32 i = 0; i < count; ++i) {
            int index = (int)((first + i) % Capacity);
            if (tags[index] == first + i) output[i] = samples[index];
        }
    }
    pthread_mutex_unlock(&audioLock); return noErr;
}
static AudioServerPlugInDriverInterface interface = {
    .QueryInterface = query, .AddRef = addRef, .Release = release, .Initialize = initialize,
    .CreateDevice = createDevice, .DestroyDevice = destroyDevice, .AddDeviceClient = deviceClient, .RemoveDeviceClient = deviceClient,
    .PerformDeviceConfigurationChange = configuration, .AbortDeviceConfigurationChange = configuration,
    .HasProperty = hasProperty, .IsPropertySettable = settable, .GetPropertyDataSize = propertySize,
    .GetPropertyData = getProperty, .SetPropertyData = setProperty, .StartIO = startIO, .StopIO = stopIO,
    .GetZeroTimeStamp = zeroTime, .WillDoIOOperation = willIO, .BeginIOOperation = beginEndIO, .DoIOOperation = doIO, .EndIOOperation = beginEndIO
};
