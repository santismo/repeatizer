#pragma once

#import <AudioToolbox/AudioToolbox.h>
#import <Block.h>

#include "RepeatizerKernel.hpp"

/// Splits render buffers at incoming AU events, keeping MIDI input timing
/// sample-accurate without allocating or touching Objective-C on the audio thread.
class RepeatizerAUProcessHelper {
public:
    explicit RepeatizerAUProcessHelper(RepeatizerKernel& kernel) : mKernel(kernel) {}

    void processWithEvents(const AudioTimeStamp* timestamp, AUAudioFrameCount frameCount, const AURenderEvent* events) {
        AUEventSampleTime now = AUEventSampleTime(timestamp->mSampleTime);
        mKernel.beginRenderCycle(now);
        AUAudioFrameCount remaining = frameCount;
        const AURenderEvent* next = events;

        while (remaining > 0) {
            if (!next) {
                mKernel.process(now, remaining);
                return;
            }
            const auto eventTime = next->head.eventSampleTime;
            const AUAudioFrameCount segment = AUAudioFrameCount(std::max<AUEventSampleTime>(0, eventTime - now));
            if (segment > 0) {
                mKernel.process(now, segment);
                remaining -= segment;
                now += segment;
            }
            do {
                mKernel.handleOneEvent(now, next);
                next = next->head.next;
            } while (next && next->head.eventSampleTime <= now);
        }
    }

    AUInternalRenderBlock internalRenderBlock() {
        AUInternalRenderBlock block = ^AUAudioUnitStatus(AudioUnitRenderActionFlags*, const AudioTimeStamp* timestamp, AUAudioFrameCount frameCount, NSInteger, AudioBufferList*, const AURenderEvent* events, AURenderPullInputBlock __unsafe_unretained) {
            if (frameCount > mKernel.maximumFramesToRender()) {
                return kAudioUnitErr_TooManyFramesToProcess;
            }
            processWithEvents(timestamp, frameCount, events);
            return noErr;
        };
        return (AUInternalRenderBlock)Block_copy(block);
    }

private:
    RepeatizerKernel& mKernel;
};
