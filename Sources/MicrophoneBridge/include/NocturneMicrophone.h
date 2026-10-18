#pragma once
#include <CoreAudio/CoreAudio.h>

#define NOCTURNE_MIC_UID CFSTR("app.nocturne.microphone")
#define NOCTURNE_MIC_NAME CFSTR("Nocturne Microphone")
enum {
    NocturneMicVersion = 1,
    NocturneMicRate = 48000,
    NocturneMicFrameSamples = 960,
    NocturneMicVersionProperty = 'ncmv',
    NocturneMicControlProperty = 'ncmc',
    NocturneMicAudioProperty = 'ncma',
    NocturneMicStart = 1,
    NocturneMicStop = 0
};

AudioDeviceID NocturneMicFindDevice(void);
OSStatus NocturneMicSetControl(AudioDeviceID device, UInt32 control);
OSStatus NocturneMicWrite(AudioDeviceID device, const void *pcm, UInt32 bytes);
