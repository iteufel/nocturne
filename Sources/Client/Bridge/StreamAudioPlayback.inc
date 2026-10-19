void ArDecodeAndPlaySample(char* sampleData, int sampleLength)
{
    const uint64_t now = LiGetMillis();
    unsigned targetMs = audioTiming.targetMs ? audioTiming.targetMs : 20;
    if (audioTiming.hasPacket && now >= audioTiming.lastPacketMs) {
        uint64_t gapMs = now - audioTiming.lastPacketMs;
        if (gapMs > targetMs) {
            // A Wi-Fi burst must fit in both the playout cushion and the
            // pending-packet limit. Otherwise the receiver discards the very
            // audio needed to recover from every radio scheduling gap.
            targetMs = (unsigned)(gapMs < 145 ? gapMs + 15 : 160);
        }
    }
    audioTiming.lastPacketMs = now;
    audioTiming.hasPacket = true;
    audioTiming.targetMs = targetMs;
    // Opus is stateful: even audio that is too late to play must be decoded so
    // the next packet (including packet-loss concealment) has valid history.
    int decodedSamples = opus_multistream_decode(opusDecoder, (unsigned char *)sampleData, sampleLength,
                                                (short *)audioBuffer, audioConfig.samplesPerFrame, 0);
    if (decodedSamples <= 0 || LiGetPendingAudioDuration() > (int)(targetMs > 30 ? targetMs : 30)) {
        return;
    }

    const Uint32 bytesPerSecond = audioConfig.sampleRate * audioConfig.channelCount * sizeof(short);
    const Uint32 decodedBytes = decodedSamples * audioConfig.channelCount * sizeof(short);
    const Uint32 targetBytes = bytesPerSecond * targetMs / 1000;
    const Uint32 maximumBytes = bytesPerSecond * (targetMs + 40) / 1000;
    Uint32 queuedBytes = SDL_GetQueuedAudioSize(audioDevice);

    // Never sleep on the receive/decode thread. A paused output or route change
    // otherwise stalls packet consumption (and LiStopConnection) indefinitely.
    // Discard stale PCM, keeping the decoder state and the newest audio.
    if (queuedBytes + decodedBytes > maximumBytes) {
        SDL_ClearQueuedAudio(audioDevice);
        queuedBytes = 0;
    }
    if (queuedBytes == 0) {
        SDL_PauseAudioDevice(audioDevice, 1);
    }

    if (SDL_QueueAudio(audioDevice, audioBuffer, decodedBytes) < 0) {
        Log(LOG_E, @"Failed to queue audio sample: %s\n", SDL_GetError());
        return;
    }

    // SDL opens paused. Prime at startup and after an underrun to absorb small
    // Wi-Fi bursts; use time rather than packet count for every Opus duration.
    if (SDL_GetAudioDeviceStatus(audioDevice) == SDL_AUDIO_PAUSED && queuedBytes + decodedBytes >= targetBytes) {
        SDL_PauseAudioDevice(audioDevice, 0);
    }
}
