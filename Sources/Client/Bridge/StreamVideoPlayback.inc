- (void)displayLinkCallback:(CADisplayLink *)sender
{
    unsigned budget = NocturneVideoPacerBudget(&nocturnePacer,
        LiGetPendingVideoFrames(), sender.timestamp);
    VIDEO_FRAME_HANDLE handle;
    PDECODE_UNIT du;
    while (budget-- && LiPollNextVideoFrame(&handle, &du)) {
        NocturneVideoPacerObserve(&nocturnePacer, du->receiveTimeUs, du->presentationTimeUs);
        LiCompleteVideoFrame(handle, DrSubmitDecodeUnit(du));
        if (nocturnePacer.priming) break;
    }
}
