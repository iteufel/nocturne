#include <CoreAudio/AudioServerPlugIn.h>
#include <dlfcn.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "../../Sources/MicrophoneBridge/include/NocturneMicrophone.h"

static AudioServerPlugInDriverRef driver;
static AudioDeviceID device, stream;
static OSStatus propertiesChanged(AudioServerPlugInHostRef host, AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *addresses) { return noErr; }
static OSStatus readProperty(AudioObjectID object, UInt32 selector, UInt32 scope, void *output, UInt32 size) {
    AudioObjectPropertyAddress address = {selector, scope, 0}; UInt32 used = 0;
    return (*driver)->GetPropertyData(driver, object, getpid(), &address, 0, NULL, size, &used, output);
}
static OSStatus writeProperty(pid_t pid, UInt32 selector, const void *data, UInt32 size) {
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal, 0};
    CFPropertyListRef value = selector == NocturneMicAudioProperty ?
        (CFPropertyListRef)CFDataCreate(NULL, data, size) : (CFPropertyListRef)CFNumberCreate(NULL, kCFNumberSInt32Type, data);
    // Exercise the same serializable representation used by HAL IPC.
    CFDataRef serialized = CFPropertyListCreateData(NULL, value, kCFPropertyListBinaryFormat_v1_0, 0, NULL); assert(serialized);
    CFPropertyListRef copy = CFPropertyListCreateWithData(NULL, serialized, kCFPropertyListImmutable, NULL, NULL); assert(copy);
    OSStatus result = (*driver)->SetPropertyData(driver, device, pid, &address, 0, NULL, sizeof(copy), &copy);
    CFRelease(copy); CFRelease(serialized); CFRelease(value); return result;
}
static void control(UInt32 command) { assert(writeProperty(getpid(), NocturneMicControlProperty, &command, sizeof(command)) == noErr); }
static double sampleTime(void) {
    Float64 sample; UInt64 time, seed;
    assert((*driver)->GetZeroTimeStamp(driver, device, 1, &sample, &time, &seed) == noErr);
    assert(seed != 0 && time > 0); return sample;
}
enum { Count = 9600 };
static void readAudio(double start, UInt32 client, float *output) {
    AudioServerPlugInIOCycleInfo cycle = {0}; cycle.mInputTime.mSampleTime = start;
    assert((*driver)->DoIOOperation(driver, device, stream, client, kAudioServerPlugInIOOperationReadInput, Count, &cycle, output, NULL) == noErr);
}
static int nonzero(const float *samples) {
    int count = 0; for (int i = 0; i < Count; ++i) if (samples[i] != 0) ++count; return count;
}
int main(int argc, char **argv) {
    assert(argc == 2);
    void *bundle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!bundle) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    void *(*factory)(CFAllocatorRef, CFUUIDRef) = dlsym(bundle, "NocturneMicrophoneFactory"); assert(factory);
    driver = factory(NULL, kAudioServerPlugInTypeUUID); assert(driver);
    AudioServerPlugInHostInterface host = {.PropertiesChanged = propertiesChanged};
    assert((*driver)->Initialize(driver, &host) == noErr);
    assert(readProperty(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, &device, sizeof(device)) == noErr);
    assert(readProperty(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, &stream, sizeof(stream)) == noErr);
    AudioObjectPropertyAddress outputAddress = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, 0}; UInt32 size;
    assert((*driver)->GetPropertyDataSize(driver, device, getpid(), &outputAddress, 0, NULL, &size) == noErr && size == 0);
    CFNumberRef versionValue = NULL; SInt32 version = 0;
    assert(readProperty(device, NocturneMicVersionProperty, kAudioObjectPropertyScopeGlobal, &versionValue, sizeof(versionValue)) == noErr);
    assert(CFNumberGetValue(versionValue, kCFNumberSInt32Type, &version) && version == 1); CFRelease(versionValue);
    AudioServerPlugInCustomPropertyInfo properties[3];
    assert(readProperty(device, kAudioObjectPropertyCustomPropertyInfoList, kAudioObjectPropertyScopeGlobal, properties, sizeof(properties)) == noErr);
    for (int i = 0; i < 3; ++i) assert(properties[i].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    AudioStreamBasicDescription format;
    assert(readProperty(stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, &format, sizeof(format)) == noErr);
    assert(format.mChannelsPerFrame == 1 && format.mSampleRate == 48000 && format.mBitsPerChannel == 32);
    assert((*driver)->StartIO(driver, device, 1) == noErr);
    assert((*driver)->StartIO(driver, device, 2) == noErr);
    float first[Count], second[Count]; double beginning = sampleTime();
    readAudio(beginning, 1, first); assert(nonzero(first) == 0);
    SInt16 pcm[NocturneMicFrameSamples];
    for (int i = 0; i < NocturneMicFrameSamples; ++i) pcm[i] = (i % 2) ? -16384 : 16384;
    assert(writeProperty(getpid(), NocturneMicAudioProperty, pcm, sizeof(pcm)) != noErr); // No lease.
    control(NocturneMicStart);
    UInt32 start = NocturneMicStart, stop = NocturneMicStop;
    assert(writeProperty(getpid() + 1, NocturneMicControlProperty, &start, sizeof(start)) != noErr);
    assert(writeProperty(getpid() + 1, NocturneMicAudioProperty, pcm, sizeof(pcm)) != noErr);
    assert(writeProperty(getpid(), NocturneMicAudioProperty, pcm, sizeof(pcm) - 1) != noErr);
    assert(writeProperty(getpid(), NocturneMicAudioProperty, pcm, sizeof(pcm)) == noErr);
    readAudio(beginning, 1, first); readAudio(beginning, 2, second);
    assert(nonzero(first) == NocturneMicFrameSamples);
    assert(memcmp(first, second, sizeof(first)) == 0); // Recording clients do not consume each other's audio.
    for (int i = 0; i < Count; ++i) assert(first[i] == 0 || fabsf(first[i]) == 0.5f);
    assert(writeProperty(getpid() + 1, NocturneMicControlProperty, &stop, sizeof(stop)) != noErr);
    control(NocturneMicStop); readAudio(beginning, 1, first); assert(nonzero(first) == 0);
    control(NocturneMicStart);
    beginning = sampleTime();
    // A malicious or delayed burst must not create seconds of queued speech.
    for (int i = 0; i < 100; ++i) assert(writeProperty(getpid(), NocturneMicAudioProperty, pcm, sizeof(pcm)) == noErr);
    readAudio(beginning + 24000, 1, first); assert(nonzero(first) == 0);
    readAudio(NAN, 1, first); assert(nonzero(first) == 0);
    usleep(2100000);
    readAudio(beginning, 1, first); assert(nonzero(first) == 0); // Producer crash/timeout is silent, even for old timestamps.
    assert(writeProperty(getpid(), NocturneMicAudioProperty, pcm, sizeof(pcm)) != noErr);
    assert(sampleTime() > beginning);
    control(NocturneMicStart); control(NocturneMicStop);
    assert((*driver)->StopIO(driver, device, 1) == noErr);
    assert((*driver)->StopIO(driver, device, 2) == noErr);
    dlclose(bundle);
    puts("Microphone driver: format, PCM, multi-reader, ownership, bounds, flush, timeout, clock passed.");
}
