#pragma once

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMIDI/MIDIMessages.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>

#include "RepeatizerParameterAddresses.h"

/// The realtime layer for Repeatizer. All editor writes land in atomics, and
/// render calls use fixed-size buffers only: no locks, allocations, or UI work.
class RepeatizerKernel {
public:
    static constexpr int kNoteCount = 128;
    static constexpr int kMaxQueuedEvents = 1024;
    static constexpr int kMaxPendingOffs = 512;
    static constexpr int kCustomPointCount = 16;
    static constexpr int kCCDestinationCount = 6;
    static constexpr int kMomentaryActionCount = 4;
    static constexpr int kGestureCount = 8;

    RepeatizerKernel() {
        for (int note = 0; note < kNoteCount; ++note) {
            mCCValues[note] = 0;
            mNoteDown[note] = false;
            mDivision[note] = 5;       // 1/16
            mRepeatFillEnabled[note] = false;
            mRepeatFillAmountThousandths[note] = 350;
            mRepeatFillDensityThousandths[note] = 420;
            mRepeatFillProbabilityThousandths[note] = 480;
            mRepeatFillEveryBars[note] = 2;
            mRepeatFillSpeedSteps[note] = 1;
            mRepeatFillBalanceThousandths[note] = 650;
            mSwingDivision[note] = -1; // auto
            mSwingTenths[note] = 500; // 50.0%
            mVelocityMode[note] = 0;  // received
            mFixedVelocity[note] = 100;
            mHumanize[note] = 10;
            mVelocityHumanize[note] = 0;
            mHumanizeProbabilityThousandths[note] = 1000;
            mHumanizeBiasThousandths[note] = 0;
            mDivisionPath[note] = 1; // same rhythmic family
            mPlaybackMode[note] = 0;
            mPatternLengthSteps[note] = 16;
            mPatternStepMillionths[note] = 250000;
            mPatternCoreMask[note] = 1;
            mPatternDetailMask[note] = 0;
            mPatternVariationMask[note] = 0;
            mPatternFillMask[note] = 0;
            mPatternVariationThousandths[note] = 0;
            mPatternAutoFillThousandths[note] = 0;
            mPatternFluctuationThousandths[note] = 0;
            mPatternProbabilityThousandths[note] = 1000;
            mPatternComplexityThousandths[note] = 550;
            mPatternSeed[note] = 1;
            for (int lane = 0; lane < 3; ++lane) {
                mModMode[lane][note] = 0;
                mModRateTenThousandths[lane][note] = 5000;
                mModDepthTenths[lane][note] = 10;
                mModDirection[lane][note] = 2;
                mModClock[lane][note] = 0;
                mModShape[lane][note] = 0;
                mModSymmetryThousandths[lane][note] = 500;
                mModCurveThousandths[lane][note] = 0;
                mModPhaseThousandths[lane][note] = 0;
                mModProbabilityBiasThousandths[lane][note] = 0;
                for (int point = 0; point < kCustomPointCount; ++point) {
                    mModCustomPointThousandths[lane][note][point] = int(std::round(std::sin(2.0 * M_PI * double(point) / double(kCustomPointCount)) * 1000.0));
                }
            }
        }
        for (int destination = 0; destination < kCCDestinationCount; ++destination) {
            mCCMappingEnabled[destination] = false;
            mCCMappingNumber[destination] = 1;
        }
        for (int action = 0; action < kMomentaryActionCount; ++action) {
            mMomentaryEnabled[action] = false;
            mMomentaryCC[action] = std::clamp(70 + action, 0, 127);
        }
        for (int gesture = 0; gesture < kGestureCount; ++gesture) {
            mGestureEnabled[gesture] = false;
            mGestureCC[gesture] = 20 + gesture;
        }
    }

    void initialize(double sampleRate) { mSampleRate = std::max(1.0, sampleRate); }
    void deInitialize() {
        mHeld.fill({});
        for (auto& noteDown : mNoteDown) { noteDown.store(false, std::memory_order_relaxed); }
        mPendingOffCount = 0;
        mManualOriginSample.store(-1, std::memory_order_relaxed);
        mFallbackOriginValid.store(false, std::memory_order_relaxed);
        mHasClockSource = false;
        mUsingHostClock = false;
        mRenderContextValid = false;
        mLastClockValid = false;
        mHasSynchronizedClock.store(false, std::memory_order_relaxed);
        mClockResetRequested.store(true, std::memory_order_relaxed);
    }

    bool isBypassed() const { return mBypassed.load(); }
    void setBypass(bool value) { mBypassed.store(value); }
    AUAudioFrameCount maximumFramesToRender() const { return mMaximumFrames.load(); }
    void setMaximumFramesToRender(AUAudioFrameCount value) { mMaximumFrames.store(value); }
    MIDIProtocolID AudioUnitMIDIProtocol() const { return kMIDIProtocol_1_0; }
    int lastInputNote() const { return mLastInputNote.load(std::memory_order_relaxed); }
    uint64_t inputActivityCounter() const { return mInputActivityCounter.load(std::memory_order_relaxed); }
    double currentBeat() const { return mCurrentBeat.load(std::memory_order_relaxed); }
    double currentBPM() const { return mCurrentBPM.load(std::memory_order_relaxed); }
    bool isNoteHeld(int note) const {
        return note >= 0 && note < kNoteCount && mNoteDown[note].load(std::memory_order_relaxed);
    }

    // Host callback blocks can originate on the stack. Keep strong, copied
    // references for as long as the audio unit may call them from render.
    void setMusicalContextBlock(AUHostMusicalContextBlock block) { mMusicalContextBlock = [block copy]; }
    void setMIDIOutputEventBlock(AUMIDIEventListBlock block) { mMIDIOutBlock = [block copy]; }

    /// Cache Logic's musical context once for the complete render cycle. The
    /// host callback describes the render-cycle timestamp, not each sub-segment
    /// created around incoming MIDI events.
    void beginRenderCycle(AUEventSampleTime sample) {
        mRenderContextValid = false;
        mRenderStartSample = sample;
        if (!mHostSync.load() || !mMusicalContextBlock) { return; }

        double bpm = mManualBPM.load();
        double beat = 0;
        if (mMusicalContextBlock(&bpm, nullptr, nullptr, &beat, nullptr, nullptr)
            && std::isfinite(bpm) && bpm > 0 && std::isfinite(beat)) {
            mRenderBPM = bpm;
            mRenderStartBeat = beat;
            mRenderContextValid = true;
            mSynchronizedBPM.store(float(bpm), std::memory_order_relaxed);
            mHasSynchronizedClock.store(true, std::memory_order_relaxed);

            const double samplesFromOrigin = beat * mSampleRate * 60.0 / bpm;
            mManualOriginSample.store(sample - AUEventSampleTime(std::llround(samplesFromOrigin)),
                                      std::memory_order_relaxed);
            mFallbackOriginValid.store(true, std::memory_order_relaxed);
        }
    }

    void setParameter(AUParameterAddress address, AUValue value) {
        switch (address) {
        case RepeatizerParameterAddressTempoMode: setTempoMode(value >= 0.5); break;
        case RepeatizerParameterAddressManualBPM: setManualBPM(value); break;
        default: break;
        }
    }

    AUValue getParameter(AUParameterAddress address) const {
        switch (address) {
        case RepeatizerParameterAddressTempoMode: return mHostSync.load() ? 1.f : 0.f;
        case RepeatizerParameterAddressManualBPM: return mManualBPM.load();
        default: return 0.f;
        }
    }

    void setTempoMode(bool hostSync) {
        if (mHostSync.exchange(hostSync) != hostSync) {
            mClockResetRequested.store(true, std::memory_order_relaxed);
        }
    }

    void setManualBPM(double bpm) {
        const float value = float(std::clamp(bpm, 30.0, 300.0));
        if (std::abs(mManualBPM.exchange(value) - value) > 0.0001f) {
            mClockResetRequested.store(true, std::memory_order_relaxed);
        }
    }

    void setTimeScale(double multiplier) {
        const int value = int(std::round(std::clamp(multiplier, 0.5, 2.0) * 1000.0));
        if (mTimeScaleThousandths.exchange(value) != value) { mTimeScaleChanged.store(true); }
    }

    /// Called by the SwiftUI editor for one of the 128 independently configured pads.
    void setPad(int note, int division, bool repeatFillEnabled, double repeatFillAmount,
                double repeatFillDensity, double repeatFillProbability, int repeatFillEveryBars,
                int repeatFillSpeedSteps, double repeatFillBalance,
                int swingDivision, double swingPercent, int velocityMode, int fixedVelocity, int humanizeAmount,
                bool velocityHumanize, double humanizeProbability, double humanizeBias,
                int divisionMode, double divisionRate, double divisionDepth, int divisionDirection,
                int divisionClock, int divisionShape, double divisionSymmetry, double divisionCurve, double divisionPhase, double divisionProbabilityBias,
                int divisionPath,
                int swingMode, double swingRate, double swingDepth, int swingDirection,
                int swingClock, int swingShape, double swingSymmetry, double swingCurve, double swingPhase, double swingProbabilityBias,
                int velocityModeMod, double velocityRate, double velocityDepth, int velocityDirection,
                int velocityClock, int velocityShape, double velocitySymmetry, double velocityCurve, double velocityPhase, double velocityProbabilityBias) {
        if (note < 0 || note >= kNoteCount) { return; }
        mDivision[note] = std::clamp(division, 0, 9);
        mRepeatFillEnabled[note] = repeatFillEnabled;
        mRepeatFillAmountThousandths[note] = int(std::round(std::clamp(repeatFillAmount, 0.0, 1.0) * 1000.0));
        mRepeatFillDensityThousandths[note] = int(std::round(std::clamp(repeatFillDensity, 0.0, 1.0) * 1000.0));
        mRepeatFillProbabilityThousandths[note] = int(std::round(std::clamp(repeatFillProbability, 0.0, 1.0) * 1000.0));
        mRepeatFillEveryBars[note] = repeatFillEveryBars == 1 || repeatFillEveryBars == 2
            || repeatFillEveryBars == 4 || repeatFillEveryBars == 8 ? repeatFillEveryBars : 2;
        mRepeatFillSpeedSteps[note] = std::clamp(repeatFillSpeedSteps, 1, 2);
        mRepeatFillBalanceThousandths[note] = int(std::round(std::clamp(repeatFillBalance, 0.0, 1.0) * 1000.0));
        mSwingDivision[note] = std::clamp(swingDivision, -1, 9);
        mSwingTenths[note] = int(std::round(std::clamp(swingPercent, 50.0, 75.0) * 10));
        mVelocityMode[note] = std::clamp(velocityMode, 0, 2);
        mFixedVelocity[note] = std::clamp(fixedVelocity, 1, 127);
        mHumanize[note] = std::clamp(humanizeAmount, 0, 64);
        mVelocityHumanize[note] = velocityHumanize ? 1 : 0;
        mHumanizeProbabilityThousandths[note] = int(std::round(std::clamp(humanizeProbability, 0.0, 1.0) * 1000));
        mHumanizeBiasThousandths[note] = int(std::round(std::clamp(humanizeBias, -1.0, 1.0) * 1000));
        mDivisionPath[note] = std::clamp(divisionPath, 0, 1);
        setMod(0, note, divisionMode, divisionRate, divisionDepth, divisionDirection, divisionClock, divisionShape, divisionSymmetry, divisionCurve, divisionPhase, divisionProbabilityBias);
        setMod(1, note, swingMode, swingRate, swingDepth, swingDirection, swingClock, swingShape, swingSymmetry, swingCurve, swingPhase, swingProbabilityBias);
        setMod(2, note, velocityModeMod, velocityRate, velocityDepth, velocityDirection, velocityClock, velocityShape, velocitySymmetry, velocityCurve, velocityPhase, velocityProbabilityBias);
    }

    void setCustomPoint(int lane, int note, int point, double value) {
        if (lane < 0 || lane >= 3 || note < 0 || note >= kNoteCount || point < 0 || point >= kCustomPointCount) { return; }
        mModCustomPointThousandths[lane][note][point] = int(std::round(std::clamp(value, -1.0, 1.0) * 1000));
    }

    void configurePattern(int note, int playbackMode, int lengthSteps, double stepBeats,
                          uint64_t coreMask, uint64_t detailMask, uint64_t variationMask, uint64_t fillMask,
                          double variation, double autoFill, double fluctuation, double probability,
                          double complexity, int seed) {
        if (note < 0 || note >= kNoteCount) { return; }
        mPlaybackMode[note] = std::clamp(playbackMode, 0, 1);
        mPatternLengthSteps[note] = std::clamp(lengthSteps, 1, 64);
        mPatternStepMillionths[note] = int(std::round(std::clamp(stepBeats, 0.015625, 4.0) * 1000000.0));
        mPatternCoreMask[note] = coreMask;
        mPatternDetailMask[note] = detailMask;
        mPatternVariationMask[note] = variationMask;
        mPatternFillMask[note] = fillMask;
        mPatternVariationThousandths[note] = int(std::round(std::clamp(variation, 0.0, 1.0) * 1000.0));
        mPatternAutoFillThousandths[note] = int(std::round(std::clamp(autoFill, 0.0, 1.0) * 1000.0));
        mPatternFluctuationThousandths[note] = int(std::round(std::clamp(fluctuation, 0.0, 1.0) * 1000.0));
        mPatternProbabilityThousandths[note] = int(std::round(std::clamp(probability, 0.0, 1.0) * 1000.0));
        mPatternComplexityThousandths[note] = int(std::round(std::clamp(complexity, 0.0, 1.0) * 1000.0));
        mPatternSeed[note] = seed;
    }

    void configureCCMapping(int destination, bool enabled, int cc) {
        if (destination < 0 || destination >= kCCDestinationCount) { return; }
        mCCMappingEnabled[destination] = enabled;
        mCCMappingNumber[destination] = std::clamp(cc, 0, 127);
    }

    void setCaptureShortTaps(bool enabled) { mCaptureShortTaps = enabled; }
    void setTapLive(bool enabled) { mTapLive = enabled; }
    void setTapLiveBufferDivision(int division) {
        mTapLiveBufferDivision = std::clamp(division, 0, 9);
    }
    void setTapLiveQuantization(int mode, int straightDivision, int tripletDivision) {
        mTapLiveQuantizeMode = std::clamp(mode, 0, 3);
        mTapLiveStraightDivision = std::clamp(straightDivision, 0, 9);
        mTapLiveTripletDivision = std::clamp(tripletDivision, 0, 9);
    }
    void setTimingHumanize(bool enabled, double milliseconds, double probability, double bias) {
        mTimingHumanizeEnabled = enabled;
        mTimingHumanizeMicroseconds = int(std::round(std::clamp(milliseconds, 0.0, 30.0) * 1000.0));
        mTimingHumanizeProbabilityThousandths = int(std::round(std::clamp(probability, 0.0, 1.0) * 1000.0));
        mTimingHumanizeBiasThousandths = int(std::round(std::clamp(bias, -1.0, 1.0) * 1000.0));
    }

    void configureMomentaryAction(int action, bool enabled, int cc) {
        if (action < 0 || action >= kMomentaryActionCount) { return; }
        mMomentaryEnabled[action] = enabled;
        mMomentaryCC[action] = std::clamp(cc, 0, 127);
    }

    void configureGestureSettings(double rateBeats, int lengthSteps, double intensity) {
        mGestureRateMillionths = int(std::round(std::clamp(rateBeats, 0.015625, 4.0) * 1000000));
        mGestureLengthSteps = std::clamp(lengthSteps, 1, 32);
        mGestureIntensityThousandths = int(std::round(std::clamp(intensity, 0.0, 1.0) * 1000));
    }

    void configureGestureMapping(int gesture, bool enabled, int cc) {
        if (gesture < 0 || gesture >= kGestureCount) { return; }
        mGestureEnabled[gesture] = enabled;
        mGestureCC[gesture] = std::clamp(cc, 0, 127);
    }

    void process(AUEventSampleTime bufferStart, AUAudioFrameCount frameCount) {
        if (mBypassed.load() || !mMIDIOutBlock) { return; }
        mQueuedCount = 0;
        const Clock clock = makeClock(bufferStart, frameCount);
        const bool timeScaleChanged = mTimeScaleChanged.exchange(false);
        if (clock.sourceChanged || timeScaleChanged) {
            // Logic can expose its musical-context callback before the callback
            // has valid transport data. When the real project clock arrives,
            // move held lanes onto that grid instead of flushing stale fallback
            // beats as a burst at the start of the buffer.
            mPendingOffCount = 0;
            for (int note = 0; note < kNoteCount; ++note) {
                auto& held = mHeld[note];
                if (!held.isHeld) { continue; }
                const double regridBeat = std::max(clock.startBeat, held.earliestRepeatBeat);
                if (held.gesture >= 0) {
                    held.nextBeat = nextGestureGrid(regridBeat);
                    held.isSwungSide = false;
                } else if (mPlaybackMode[note].load() == 1) {
                    const auto point = nextPatternPoint(note, regridBeat, held.repeatIndex, clock.bpm);
                    held.nextBeat = point.beat;
                    held.patternGlobalStep = point.globalStep;
                    held.patternPointValid = point.valid;
                    held.isSwungSide = positiveModulo(point.globalStep, 2) != 0;
                } else {
                    const auto settings = resolve(note, regridBeat, held.repeatIndex, clock.bpm);
                    const auto grid = nextGridPoint(settings, regridBeat, note, held.repeatIndex);
                    held.nextBeat = grid.beat;
                    held.isSwungSide = grid.isSwungSide;
                }
            }
        }
        queueDueOffs(clock);

        for (int note = 0; note < kNoteCount; ++note) {
            auto& held = mHeld[note];
            if (!held.isHeld) { continue; }
            if (held.liveTapPending) {
                if (held.liveTapBeat > clock.endBeat + 0.0000001) { continue; }
                queueEvent(true, note, held.channel, held.velocity, held.liveTapBeat, clock);
                held.liveTapPending = false;
                if (held.stopAfterLiveTap) {
                    addPendingOff(note, held.channel, held.liveTapBeat + 0.03);
                    held.isHeld = false;
                    continue;
                }
            }
            while (true) {
                const auto settings = resolve(note, held.nextBeat, held.repeatIndex, clock.bpm);
                const bool isPattern = held.gesture < 0 && mPlaybackMode[note].load() == 1;
                const double outputBeat = timingHumanizedBeat(
                    held.nextBeat, settings, note, held.repeatIndex, clock.bpm, isPattern
                );
                if (outputBeat > clock.endBeat + 0.0000001) { break; }
                if (!isPattern || held.patternPointValid) {
                    int velocity = velocityFor(settings, held.velocity, note, held.repeatIndex);
                    if (held.gesture >= 0) { velocity = gestureVelocity(held.gesture, velocity, held.repeatIndex); }
                    const double protectedBeat = std::max(outputBeat, held.earliestRepeatBeat);
                    queueEvent(true, note, held.channel, velocity, protectedBeat, clock);
                    addPendingOff(note, held.channel, protectedBeat + 0.03);
                }

                if (held.gesture >= 0) {
                    held.nextBeat += gestureInterval(held.gesture, held.repeatIndex);
                } else if (isPattern) {
                    const auto point = nextPatternPoint(note, held.nextBeat + 0.000001, held.repeatIndex + 1, clock.bpm);
                    held.nextBeat = point.beat;
                    held.patternGlobalStep = point.globalStep;
                    held.patternPointValid = point.valid;
                    held.isSwungSide = positiveModulo(point.globalStep, 2) != 0;
                } else {
                    const auto grid = nextGridPoint(settings, held.nextBeat + 0.000001, note, held.repeatIndex + 1);
                    held.nextBeat = grid.beat;
                    held.isSwungSide = grid.isSwungSide;
                }
                ++held.repeatIndex;
                if (held.releaseAfterFirst) { held.isHeld = false; break; }
            }
        }
        flushQueue(clock);
    }

    void handleOneEvent(AUEventSampleTime now, const AURenderEvent* event) {
        switch (event->head.eventType) {
        case AURenderEventParameter:
            setParameter(event->parameter.parameterAddress, event->parameter.value);
            break;
        case AURenderEventMIDIEventList:
            handleMIDIEventList(now, &event->MIDIEventsList);
            break;
        default:
            break;
        }
    }

private:
    struct Held {
        bool isHeld = false;
        uint8_t velocity = 0;
        uint8_t channel = 0;
        double nextBeat = 0;
        int repeatIndex = 0;
        bool isSwungSide = false;
        int64_t patternGlobalStep = 0;
        bool patternPointValid = false;
        bool releaseAfterFirst = false;
        double earliestRepeatBeat = 0;
        double liveTapBeat = 0;
        bool liveTapPending = false;
        bool stopAfterLiveTap = false;
        int gesture = -1;
    };
    struct PendingOff { int note = 0; int channel = 0; double beat = 0; };
    struct QueuedEvent { bool on = false; int note = 0; int channel = 0; int velocity = 0; double beat = 0; };
    struct Clock { AUEventSampleTime startSample = 0; double startBeat = 0; double endBeat = 0; double beatsPerFrame = 0; double bpm = 120; bool sourceChanged = false; };
    struct GridPoint { double beat = 0; bool isSwungSide = false; };
    struct PatternPoint { double beat = 0; int64_t globalStep = 0; bool valid = false; };
    struct ResolvedSettings {
        int divisionIndex = 5;
        double divisionBeats = 0.25;
        bool repeatFillEnabled = false;
        double repeatFillAmount = 0.35;
        double repeatFillDensity = 0.42;
        double repeatFillProbability = 0.48;
        int repeatFillEveryBars = 2;
        int repeatFillSpeedSteps = 1;
        double repeatFillBalance = 0.65;
        double swingDivisionBeats = 0;
        double swing = 50;
        int velocityMode = 0;
        int fixedVelocity = 100;
        int humanize = 10;
        bool velocityHumanize = false;
        double humanizeProbability = 1;
        double humanizeBias = 0;
        double velocityMovement = 0;
    };

    void setMod(int lane, int note, int mode, double rate, double depth, int direction,
                int clock, int shape, double symmetry, double curve, double phase, double probabilityBias) {
        mModMode[lane][note] = std::clamp(mode, 0, 3);
        mModRateTenThousandths[lane][note] = int(std::round(std::clamp(rate, 0.01, 20.0) * 10000));
        mModDepthTenths[lane][note] = int(std::round(std::clamp(depth, 0.0, 8.0) * 10));
        mModDirection[lane][note] = std::clamp(direction, 0, 2);
        mModClock[lane][note] = std::clamp(clock, 0, 1);
        mModShape[lane][note] = std::clamp(shape, 0, 6);
        mModSymmetryThousandths[lane][note] = int(std::round(std::clamp(symmetry, 0.05, 0.95) * 1000));
        mModCurveThousandths[lane][note] = int(std::round(std::clamp(curve, -1.0, 1.0) * 1000));
        mModPhaseThousandths[lane][note] = int(std::round(std::clamp(phase, 0.0, 1.0) * 1000));
        mModProbabilityBiasThousandths[lane][note] = int(std::round(std::clamp(probabilityBias, -1.0, 1.0) * 1000));
    }

    Clock makeClock(AUEventSampleTime sample, AUAudioFrameCount frames) {
        const bool hostSync = mHostSync.load();
        const bool resetRequested = mClockResetRequested.exchange(false, std::memory_order_relaxed);
        double bpm = hostSync && mHasSynchronizedClock.load(std::memory_order_relaxed)
            ? double(mSynchronizedBPM.load(std::memory_order_relaxed))
            : double(mManualBPM.load());
        double beat = 0;
        bool usingHostClock = false;
        if (hostSync && mRenderContextValid) {
            bpm = mRenderBPM;
            const double beatsPerFrame = (bpm / 60.0) / mSampleRate;
            beat = mRenderStartBeat + double(sample - mRenderStartSample) * beatsPerFrame;
            usingHostClock = true;
        }
        if (!usingHostClock) {
            auto origin = mManualOriginSample.load();
            if (resetRequested || !mFallbackOriginValid.load(std::memory_order_relaxed)) {
                const double anchorBeat = mLastClockValid ? mLastClockBeat : 0.0;
                const auto samplesFromAnchor = AUEventSampleTime(std::llround(anchorBeat * mSampleRate * 60.0 / bpm));
                mManualOriginSample.store(sample - samplesFromAnchor);
                mFallbackOriginValid.store(true, std::memory_order_relaxed);
                origin = sample - samplesFromAnchor;
            }
            beat = (double(sample - origin) / mSampleRate) * bpm / 60.0;
        }
        bool sourceChanged = resetRequested;
        if (mLastClockValid) {
            const double expectedBeat = mLastClockBeat
                + double(sample - mLastClockSample) * (mLastClockBPM / 60.0) / mSampleRate;
            sourceChanged = sourceChanged
                || std::abs(beat - expectedBeat) > 0.01
                || std::abs(bpm - mLastClockBPM) > 0.001;
        }
        mHasClockSource = true;
        mUsingHostClock = usingHostClock;
        mLastClockValid = true;
        mLastClockSample = sample;
        mLastClockBeat = beat;
        mLastClockBPM = bpm;
        const double beatsPerFrame = (bpm / 60.0) / mSampleRate;
        mCurrentBeat.store(beat, std::memory_order_relaxed);
        mCurrentBPM.store(bpm, std::memory_order_relaxed);
        return Clock { sample, beat, beat + beatsPerFrame * double(frames), beatsPerFrame, bpm, sourceChanged };
    }

    ResolvedSettings resolve(int note, double beat, int eventIndex, double bpm) const {
        int index = movedDivisionIndex(
            mDivision[note].load(),
            0,
            mDivisionPath[note].load() == 1
        );
        if (mappingEnabled(2)) { index = std::clamp(int(std::round(mappedValue(2) * 9.0)), 0, 9); }
        const int evenMovement = (momentaryActive(0) ? 1 : 0) - (momentaryActive(1) ? 1 : 0);
        const int oddMovement = (momentaryActive(2) ? 1 : 0) - (momentaryActive(3) ? 1 : 0);
        if (evenMovement != 0) { index = movedToFamilyDivisionIndex(index, evenMovement, false); }
        if (oddMovement != 0) { index = movedToFamilyDivisionIndex(index, oddMovement, true); }
        double swing = std::clamp(double(mSwingTenths[note].load()) / 10.0, 50.0, 75.0);
        if (mappingEnabled(0)) { swing = 50.0 + mappedValue(0) * 25.0; }
        swing = std::clamp(swing, 50.0, 75.0);
        int velocityMode = mVelocityMode[note].load();
        int fixedVelocity = mFixedVelocity[note].load();
        if (mappingEnabled(1)) {
            velocityMode = 1;
            fixedVelocity = std::clamp(1 + int(std::round(mappedValue(1) * 126.0)), 1, 127);
        }
        int humanize = mHumanize[note].load();
        if (mappingEnabled(5)) { humanize = int(std::round(mappedValue(5) * 64.0)); }
        const double scale = timeScale();
        return ResolvedSettings {
            index,
            divisionBeats(index) * scale,
            mRepeatFillEnabled[note].load(),
            double(mRepeatFillAmountThousandths[note].load()) / 1000.0,
            double(mRepeatFillDensityThousandths[note].load()) / 1000.0,
            double(mRepeatFillProbabilityThousandths[note].load()) / 1000.0,
            mRepeatFillEveryBars[note].load(),
            mRepeatFillSpeedSteps[note].load(),
            double(mRepeatFillBalanceThousandths[note].load()) / 1000.0,
            mSwingDivision[note].load() < 0 ? 0.0 : divisionBeats(mSwingDivision[note].load()) * scale,
            swing,
            velocityMode,
            fixedVelocity,
            humanize,
            mVelocityHumanize[note].load() == 1,
            double(mHumanizeProbabilityThousandths[note].load()) / 1000.0,
            double(mHumanizeBiasThousandths[note].load()) / 1000.0,
            0
        };
    }

    double modulation(int lane, int note, double beat, int eventIndex, double bpm) const {
        const int mode = mModMode[lane][note].load();
        if (mode == 0) { return 0; }
        const double rate = double(mModRateTenThousandths[lane][note].load()) / 10000.0;
        const double depth = mappingEnabled(2 + lane)
            ? mappedValue(2 + lane) * 8.0
            : double(mModDepthTenths[lane][note].load()) / 10.0;
        const double elapsed = mModClock[lane][note].load() == 0 ? beat : beat * 60.0 / std::max(1.0, bpm);
        const double cycle = elapsed * rate + double(mModPhaseThousandths[lane][note].load()) / 1000.0;
        double position = cycle - std::floor(cycle);
        if (position < 0) { position += 1.0; }
        if (mode == 3) { position = probabilityPosition(lane, note, cycle); }
        double raw = mode == 2 ? smoothRandom(note, lane, cycle, position) : waveform(lane, note, position);
        switch (mModDirection[lane][note].load()) {
        case 0: raw = -std::abs(raw); break;
        case 1: raw = std::abs(raw); break;
        default: break;
        }
        return raw * depth;
    }

    bool mappingEnabled(int destination) const {
        return destination >= 0 && destination < kCCDestinationCount && mCCMappingEnabled[destination].load();
    }

    double mappedValue(int destination) const {
        const int cc = mCCMappingNumber[destination].load();
        return double(mCCValues[cc].load()) / 127.0;
    }

    bool momentaryActive(int action) const {
        if (action < 0 || action >= kMomentaryActionCount || !mMomentaryEnabled[action].load()) { return false; }
        return mCCValues[mMomentaryCC[action].load()].load() > 0;
    }

    double waveform(int lane, int note, double position) const {
        const double split = double(mModSymmetryThousandths[lane][note].load()) / 1000.0;
        const double warped = position < split
            ? 0.5 * position / split
            : 0.5 + 0.5 * (position - split) / (1.0 - split);
        double raw = 0;
        switch (mModShape[lane][note].load()) {
        case 1: raw = 1.0 - 4.0 * std::abs(warped - 0.5); break;
        case 2: raw = 2.0 * position - 1.0; break;
        case 3: raw = 1.0 - 2.0 * position; break;
        case 4: return position < split ? 1.0 : -1.0;
        case 5: return position < split ? 1.0 : 0.0;
        case 6: {
            const double scaled = position * double(kCustomPointCount);
            const int lower = int(std::floor(scaled)) % kCustomPointCount;
            const int upper = (lower + 1) % kCustomPointCount;
            const double blend = scaled - std::floor(scaled);
            const double first = double(mModCustomPointThousandths[lane][note][lower].load()) / 1000.0;
            const double second = double(mModCustomPointThousandths[lane][note][upper].load()) / 1000.0;
            raw = first + (second - first) * blend;
            break;
        }
        default: raw = std::sin(2.0 * M_PI * warped); break;
        }
        const double curve = double(mModCurveThousandths[lane][note].load()) / 1000.0;
        const double exponent = std::pow(2.0, curve * 2.0);
        return std::copysign(std::pow(std::abs(raw), exponent), raw);
    }

    static double smoothRandom(int note, int lane, double cycle, double position) {
        const int step = int(std::floor(cycle));
        const double blend = position * position * (3.0 - 2.0 * position);
        const int seed = modulationSeed(note, lane);
        const double first = modulationRandom(seed, step);
        return first + (modulationRandom(seed, step + 1) - first) * blend;
    }

    double probabilityPosition(int lane, int note, double cycle) const {
        const int step = int(std::floor(cycle));
        const double bias = double(mModProbabilityBiasThousandths[lane][note].load()) / 1000.0;
        const double peakChance = std::clamp((bias + 1.0) * 0.5, 0.0, 1.0);
        const int seed = modulationSeed(note, lane);
        const bool choosePeak = modulationRandomUnit(seed + 401, step) < peakChance;
        double selected = modulationRandomUnit(seed + 503, step);
        double selectedValue = waveform(lane, note, selected);
        for (int candidateIndex = 1; candidateIndex < 8; ++candidateIndex) {
            const double candidate = modulationRandomUnit(seed + 503 + candidateIndex * 37, step);
            const double value = waveform(lane, note, candidate);
            if ((choosePeak && value > selectedValue) || (!choosePeak && value < selectedValue)) {
                selected = candidate;
                selectedValue = value;
            }
        }
        return selected;
    }

    static double divisionBeats(int index) {
        constexpr std::array<double, 10> values { 2.0, 1.0, 2.0 / 3.0, 0.5, 1.0 / 3.0, 0.25, 1.0 / 6.0, 0.125, 1.0 / 12.0, 0.0625 };
        return values[std::clamp(index, 0, 9)];
    }

    static int movedDivisionIndex(int base, int steps, bool sameFeel) {
        base = std::clamp(base, 0, 9);
        if (!sameFeel) { return std::clamp(base + steps, 0, 9); }
        constexpr std::array<int, 6> straight { 0, 1, 3, 5, 7, 9 };
        constexpr std::array<int, 4> triplets { 2, 4, 6, 8 };
        const bool isTriplet = base == 2 || base == 4 || base == 6 || base == 8;
        if (isTriplet) {
            const auto found = std::find(triplets.begin(), triplets.end(), base);
            const int position = int(std::distance(triplets.begin(), found));
            return triplets[std::clamp(position + steps, 0, int(triplets.size()) - 1)];
        }
        const auto found = std::find(straight.begin(), straight.end(), base);
        const int position = int(std::distance(straight.begin(), found));
        return straight[std::clamp(position + steps, 0, int(straight.size()) - 1)];
    }

    static int movedToFamilyDivisionIndex(int base, int direction, bool tripletFamily) {
        if (direction == 0) { return std::clamp(base, 0, 9); }
        constexpr std::array<int, 6> straight { 0, 1, 3, 5, 7, 9 };
        constexpr std::array<int, 4> triplets { 2, 4, 6, 8 };
        const auto move = [base, direction](const auto& family) {
            const auto found = std::find(family.begin(), family.end(), base);
            if (found != family.end()) {
                const int position = int(std::distance(family.begin(), found));
                return family[std::clamp(position + (direction > 0 ? 1 : -1), 0, int(family.size()) - 1)];
            }
            const double current = divisionBeats(base);
            if (direction > 0) {
                for (auto candidate = family.rbegin(); candidate != family.rend(); ++candidate) {
                    if (divisionBeats(*candidate) < current - 0.0000001) {
                        int closest = *candidate;
                        auto next = candidate;
                        while (++next != family.rend() && divisionBeats(*next) < current - 0.0000001) {
                            closest = *next;
                        }
                        return closest;
                    }
                }
                return family.back();
            }
            int closest = family.front();
            bool foundSlower = false;
            for (const int candidate : family) {
                if (divisionBeats(candidate) > current + 0.0000001) {
                    closest = candidate;
                    foundSlower = true;
                }
            }
            return foundSlower ? closest : family.front();
        };
        return tripletFamily ? move(triplets) : move(straight);
    }

    static double random(int note, int eventIndex, int lane) {
        uint64_t x = uint64_t(uint32_t(note * 1103515245u + eventIndex * 12345u + lane * 747796405u));
        x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
        return double((x * 2685821657736338717ULL) % 10000) / 5000.0 - 1.0;
    }

    static int modulationSeed(int note, int lane) {
        constexpr std::array<int, 3> offsets { 0, 97, 211 };
        return note + offsets[std::clamp(lane, 0, 2)];
    }

    static double modulationRandom(int seed, int step) {
        uint64_t x = uint64_t(uint32_t(seed * 1103515245u + step * 12345u));
        x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
        return double((x * 2685821657736338717ULL) % 10000) / 5000.0 - 1.0;
    }

    static double modulationRandomUnit(int seed, int step) {
        return (modulationRandom(seed, step) + 1.0) * 0.5;
    }

    static double randomUnit(int note, int eventIndex, int lane) {
        return (random(note, eventIndex, lane) + 1.0) * 0.5;
    }

    static int velocityFor(const ResolvedSettings& settings, int input, int note, int eventIndex) {
        int base = input;
        if (settings.velocityMode == 1) { base = settings.fixedVelocity; }
        const bool usesHumanize = settings.velocityHumanize || settings.velocityMode == 2;
        if (usesHumanize && randomUnit(note + 1003, eventIndex, 9) <= settings.humanizeProbability) {
            const double biased = std::clamp(random(note, eventIndex, 9) + settings.humanizeBias, -1.0, 1.0);
            base += int(std::round(biased * settings.humanize));
        }
        return std::clamp(base, 1, 127);
    }

    double timingHumanizedBeat(
        double beat,
        const ResolvedSettings& settings,
        int note,
        int eventIndex,
        double bpm,
        bool pattern
    ) const {
        if (!mTimingHumanizeEnabled.load()) { return beat; }
        const double milliseconds = double(mTimingHumanizeMicroseconds.load()) / 1000.0;
        if (milliseconds <= 0) { return beat; }
        const double probability = double(mTimingHumanizeProbabilityThousandths.load()) / 1000.0;
        if (randomUnit(note + 5003, eventIndex, 17) > probability) { return beat; }
        const double requestedBeats = milliseconds / 1000.0 * bpm / 60.0;
        double interval = settings.divisionBeats;
        if (pattern) {
            interval = std::max(0.015625, double(mPatternStepMillionths[note].load()) / 1000000.0) * timeScale();
        } else if (settings.repeatFillEnabled) {
            const int fillSteps = std::clamp(settings.repeatFillSpeedSteps, 1, 2);
            const int fillIndex = movedDivisionIndex(settings.divisionIndex, fillSteps, true);
            interval = divisionBeats(fillIndex) * timeScale();
        }
        const double maximum = std::min(requestedBeats, interval * 0.4);
        const double bias = double(mTimingHumanizeBiasThousandths.load()) / 1000.0;
        const double movement = std::clamp(random(note + 4001, eventIndex, 13) + bias, -1.0, 1.0);
        return beat + movement * maximum;
    }

    static GridPoint nextGridPoint(const ResolvedSettings& settings, double beat, int note, int eventIndex) {
        const double amount = std::clamp(settings.repeatFillAmount, 0.0, 1.0);
        const int fillSteps = std::clamp(settings.repeatFillSpeedSteps, 1, 2);
        const int fillIndex = settings.repeatFillEnabled && amount > 0.001
            ? movedDivisionIndex(settings.divisionIndex, fillSteps, true)
            : settings.divisionIndex;
        const double scale = settings.divisionBeats / divisionBeats(settings.divisionIndex);
        const double searchBeats = divisionBeats(fillIndex) * scale;
        int64_t step = int64_t(std::floor(beat / searchBeats)) - 2;
        for (int search = 0; search < 128; ++search, ++step) {
            const double straightBeat = double(step) * searchBeats;
            const double basePosition = straightBeat / settings.divisionBeats;
            const bool baseHit = std::abs(basePosition - std::round(basePosition)) < 0.0000001;
            double phase = std::fmod(straightBeat, 4.0);
            if (phase < 0) { phase += 4.0; }
            const int64_t barIndex = int64_t(std::floor(straightBeat / 4.0));
            const int everyBars = settings.repeatFillEveryBars == 1 || settings.repeatFillEveryBars == 2
                || settings.repeatFillEveryBars == 4 || settings.repeatFillEveryBars == 8
                ? settings.repeatFillEveryBars : 2;
            const bool cadenceActive = positiveModulo(barIndex, everyBars) == everyBars - 1;
            const double balance = std::clamp(settings.repeatFillBalance, 0.0, 1.0);
            const double activationChance = std::clamp(settings.repeatFillProbability, 0.0, 1.0)
                * ((1.0 - balance) + balance * repeatFillRoleWeight(note));
            const bool phraseActive = cadenceActive
                && randomUnit(note + 709, int(barIndex), 71) <= activationChance;
            const double fillZoneStart = 4.0 - (0.25 + amount * 0.75);
            const bool inFillZone = settings.repeatFillEnabled && amount > 0.001 && phraseActive
                && phase >= fillZoneStart - 0.0000001 && phase < 4.0 - 0.0000001;
            const int selectedSteps = fillSteps == 2
                && randomUnit(note + 811, int(barIndex), 73) > 0.55 ? 2 : 1;
            const int selectedFillIndex = movedDivisionIndex(settings.divisionIndex, selectedSteps, true);
            const double selectedFillBeats = divisionBeats(selectedFillIndex) * scale;
            const double selectedPosition = straightBeat / selectedFillBeats;
            const bool belongsToSelectedSpeed = std::abs(selectedPosition - std::round(selectedPosition)) < 0.0000001;
            const double phraseVariation = 0.65 + randomUnit(note + 919, int(barIndex), 79) * 0.70;
            const double fillChance = settings.repeatFillDensity >= 0.999
                ? 1.0 : std::clamp(settings.repeatFillDensity * phraseVariation, 0.0, 1.0);
            const bool extraHit = inFillZone && !baseHit && belongsToSelectedSpeed
                && randomUnit(note + 1019, int(step), 83) <= fillChance;
            if (!baseHit && !extraHit) { continue; }
            const double candidate = swungBeat(
                straightBeat, settings, extraHit ? selectedFillBeats : settings.divisionBeats
            );
            if (candidate >= beat - 0.0000001) {
                return GridPoint { candidate, std::abs(candidate - straightBeat) > 0.0000001 };
            }
        }
        return GridPoint { beat + settings.divisionBeats, false };
    }

    static double repeatFillRoleWeight(int note) {
        switch (note) {
        case 35: case 36: return 0.48;
        case 37: case 38: case 39: case 40: return 0.88;
        case 42: case 44: case 46: return 0.58;
        case 41: case 43: case 45: case 47: case 48: case 50: return 0.94;
        case 49: case 51: case 52: case 53: case 55: case 57: case 59: return 0.38;
        default: return note >= 54 && note <= 81 ? 0.72 : 0.62;
        }
    }

    static double swungBeat(double straightBeat, const ResolvedSettings& settings, double automaticUnit) {
        const double unit = settings.swingDivisionBeats > 0 ? settings.swingDivisionBeats : automaticUnit;
        const double position = straightBeat / unit;
        const int64_t index = int64_t(std::llround(position));
        if (std::abs(position - double(index)) >= 0.0000001 || positiveModulo(index, 2) == 0) {
            return straightBeat;
        }
        const int64_t pairIndex = int64_t(std::floor(double(index) / 2.0));
        const double pairStart = double(pairIndex * 2) * unit;
        return pairStart + unit * 2.0 * settings.swing / 100.0;
    }

    static int positiveModulo(int64_t value, int divisor) {
        const int result = int(value % int64_t(divisor));
        return result < 0 ? result + divisor : result;
    }

    static double patternRandomUnit(int note, int64_t globalStep, int seed, int salt) {
        uint64_t x = uint64_t(note) * 48271ULL
                   + uint64_t(globalStep) * 6969ULL
                   + uint64_t(uint32_t(seed)) * 1013ULL
                   + uint64_t(salt) * 65537ULL;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        return double((x * 2685821657736338717ULL) >> 11) / double(1ULL << 53);
    }

    bool patternHit(int note, int64_t globalStep) const {
        const int length = std::clamp(mPatternLengthSteps[note].load(), 1, 64);
        const int localStep = positiveModulo(globalStep, length);
        const uint64_t bit = 1ULL << localStep;
        const int seed = mPatternSeed[note].load();
        const int64_t cycle = int64_t(std::floor(double(globalStep) / double(length)));

        double complexity = double(mPatternComplexityThousandths[note].load()) / 1000.0;
        const double fluctuation = double(mPatternFluctuationThousandths[note].load()) / 1000.0;
        complexity = std::clamp(complexity
            + std::sin(double(cycle + seed) * 0.754877666 + double(note) * 0.173205081) * fluctuation * 0.5,
            0.0, 1.0);

        bool hit = (mPatternCoreMask[note].load() & bit) != 0;
        if ((mPatternDetailMask[note].load() & bit) != 0
            && patternRandomUnit(note, globalStep, seed, 11) <= complexity) {
            hit = true;
        }

        const double variation = double(mPatternVariationThousandths[note].load()) / 1000.0;
        if ((mPatternVariationMask[note].load() & bit) != 0
            && patternRandomUnit(note, globalStep, seed, 23) <= variation) {
            hit = !hit;
        }

        const double autoFill = double(mPatternAutoFillThousandths[note].load()) / 1000.0;
        const bool fillCycle = patternRandomUnit(note, cycle, seed, 37) <= autoFill;
        if (fillCycle && (mPatternFillMask[note].load() & bit) != 0) { hit = true; }
        if (!hit) { return false; }

        const double probability = double(mPatternProbabilityThousandths[note].load()) / 1000.0;
        return probability >= 1.0 || patternRandomUnit(note, globalStep, seed, 53) <= probability;
    }

    PatternPoint nextPatternPoint(int note, double beat, int eventIndex, double bpm) const {
        const double stepBeats = std::max(0.015625, double(mPatternStepMillionths[note].load()) / 1000000.0)
            * timeScale();
        const int length = std::clamp(mPatternLengthSteps[note].load(), 1, 64);
        int64_t globalStep = int64_t(std::floor(beat / stepBeats)) - 2;
        const int searchLimit = std::max(64, length * 8);

        for (int search = 0; search < searchLimit; ++search, ++globalStep) {
            const double straightBeat = double(globalStep) * stepBeats;
            const auto settings = resolve(note, straightBeat, eventIndex + search, bpm);
            const double candidate = swungBeat(straightBeat, settings, stepBeats);
            if (candidate < beat - 0.0000001 || !patternHit(note, globalStep)) { continue; }
            return PatternPoint { candidate, globalStep, true };
        }

        // A probability setting can intentionally suppress every candidate in
        // the bounded search. Re-check from a later cycle without ever blocking
        // or allocating on Logic's render thread.
        const int64_t retryStep = (int64_t(std::floor(beat / stepBeats / double(length))) + 1) * length;
        return PatternPoint { double(retryStep) * stepBeats, retryStep, false };
    }

    int activeGesture() const {
        for (int gesture = 0; gesture < kGestureCount; ++gesture) {
            if (mGestureEnabled[gesture].load() && mCCValues[mGestureCC[gesture].load()].load() > 0) {
                return gesture;
            }
        }
        return -1;
    }

    void regridMomentaryRepeats(AUEventSampleTime now, int cc) {
        bool controlsMomentaryAction = mappingEnabled(2) && mCCMappingNumber[2].load() == cc;
        for (int action = 0; action < kMomentaryActionCount; ++action) {
            if (mMomentaryEnabled[action].load() && mMomentaryCC[action].load() == cc) {
                controlsMomentaryAction = true;
                break;
            }
        }
        if (!controlsMomentaryAction) { return; }
        const auto clock = makeClock(now, 1);
        for (int note = 0; note < kNoteCount; ++note) {
            auto& held = mHeld[note];
            if (!held.isHeld || held.gesture >= 0) { continue; }
            const double regridBeat = std::max(clock.startBeat, held.earliestRepeatBeat);
            if (mPlaybackMode[note].load() == 1) {
                const auto point = nextPatternPoint(note, regridBeat, held.repeatIndex, clock.bpm);
                held.nextBeat = point.beat;
                held.patternGlobalStep = point.globalStep;
                held.patternPointValid = point.valid;
                held.isSwungSide = positiveModulo(point.globalStep, 2) != 0;
            } else {
                const auto settings = resolve(note, regridBeat, held.repeatIndex, clock.bpm);
                const auto grid = nextGridPoint(settings, regridBeat, note, held.repeatIndex);
                held.nextBeat = grid.beat;
                held.isSwungSide = grid.isSwungSide;
            }
        }
    }

    double timeScale() const { return double(mTimeScaleThousandths.load()) / 1000.0; }

    double tapLiveResumeBeat(double liveBeat) const {
        return liveBeat + divisionBeats(mTapLiveBufferDivision.load()) * timeScale();
    }

    double quantizedLiveTapBeat(double beat) const {
        const auto nextGrid = [beat, this](int division) {
            const double unit = divisionBeats(division) * timeScale();
            return std::ceil((beat - 0.0000001) / unit) * unit;
        };
        switch (mTapLiveQuantizeMode.load()) {
        case 1: return nextGrid(mTapLiveStraightDivision.load());
        case 2: return nextGrid(mTapLiveTripletDivision.load());
        case 3: return std::min(nextGrid(mTapLiveStraightDivision.load()), nextGrid(mTapLiveTripletDivision.load()));
        default: return beat;
        }
    }

    double gestureRate() const {
        return double(mGestureRateMillionths.load()) / 1000000.0 * timeScale();
    }

    double nextGestureGrid(double beat) const {
        const double rate = gestureRate();
        return std::ceil((beat - 0.0000001) / rate) * rate;
    }

    double gestureInterval(int gesture, int step) const {
        const double base = gestureRate();
        const int length = std::max(1, mGestureLengthSteps.load());
        const double progress = double(step % length) / double(std::max(length - 1, 1));
        switch (gesture) {
        case 0: return base * (step % 2 == 0 ? 0.14 : 0.86); // flam
        case 1: return base * (step % 2 == 0 ? 0.35 : 0.65); // diddle
        case 5: return base * 0.25; // buzz
        case 6: return base * (step % 3 < 2 ? 0.15 : 0.70); // drag
        case 7: return std::max(base * 0.25, base * (1.0 - 0.65 * progress)); // fill burst
        default: return base;
        }
    }

    int gestureVelocity(int gesture, int base, int step) const {
        const int length = std::max(1, mGestureLengthSteps.load());
        const double progress = double(step % length) / double(std::max(length - 1, 1));
        double shaped = base;
        switch (gesture) {
        case 0: shaped = base * (step % 2 == 0 ? 0.58 : 1.0); break;
        case 1: shaped = base * (step % 2 == 0 ? 1.0 : 0.78); break;
        case 2: shaped = base * (0.25 + 0.75 * progress); break;
        case 3: shaped = base * (1.0 - 0.75 * progress); break;
        case 6: shaped = base * (step % 3 == 2 ? 1.0 : 0.52); break;
        case 7: shaped = base * (0.55 + 0.45 * progress); break;
        default: break;
        }
        const double intensity = double(mGestureIntensityThousandths.load()) / 1000.0;
        return std::clamp(int(std::round(base + (shaped - base) * intensity)), 1, 127);
    }

    void queueDueOffs(const Clock& clock) {
        int keep = 0;
        for (int i = 0; i < mPendingOffCount; ++i) {
            const auto off = mPendingOffs[i];
            if (off.beat <= clock.endBeat) {
                queueEvent(false, off.note, off.channel, 0, off.beat, clock);
            } else {
                mPendingOffs[keep++] = off;
            }
        }
        mPendingOffCount = keep;
    }

    void addPendingOff(int note, int channel, double beat) {
        if (mPendingOffCount < kMaxPendingOffs) {
            mPendingOffs[mPendingOffCount++] = PendingOff { note, channel, beat };
        }
    }

    void queueEvent(bool on, int note, int channel, int velocity, double beat, const Clock& clock) {
        if (mQueuedCount >= kMaxQueuedEvents || beat > clock.endBeat + 0.000001) { return; }
        mQueued[mQueuedCount++] = QueuedEvent { on, note, channel, velocity, std::max(beat, clock.startBeat) };
    }

    void flushQueue(const Clock& clock) {
        std::sort(mQueued.begin(), mQueued.begin() + mQueuedCount, [](const QueuedEvent& a, const QueuedEvent& b) { return a.beat < b.beat; });
        for (int i = 0; i < mQueuedCount; ++i) {
            const auto& event = mQueued[i];
            const auto delta = std::max(0.0, event.beat - clock.startBeat);
            const auto sample = clock.startSample + AUEventSampleTime(std::llround(delta / clock.beatsPerFrame));
            event.on ? sendNoteOn(sample, event.note, event.channel, event.velocity) : sendNoteOff(sample, event.note, event.channel);
        }
        mQueuedCount = 0;
    }

    void handleMIDIEventList(AUEventSampleTime now, const AUMIDIEventList* midiEvent) {
        const MIDIEventList& list = midiEvent->eventList;
        const MIDIEventPacket* packet = &list.packet[0];
        for (UInt32 packetIndex = 0; packetIndex < list.numPackets; ++packetIndex) {
            for (UInt32 word = 0; word < packet->wordCount;) {
                const UInt32 data = packet->words[word];
                const UInt32 type = data >> 28;
                const UInt32 wordCount = type == 0x4 ? 2 : 1;
                if ((type == 0x2 || type == 0x4) && word + wordCount <= packet->wordCount) {
                    const int status = type == 0x2 ? int((data >> 16) & 0xF0) : int((data >> 20) & 0xF);
                    const int channel = type == 0x2 ? int((data >> 16) & 0x0F) : int((data >> 16) & 0x0F);
                    const int note = int((data >> 8) & 0x7F);
                    const int velocity = type == 0x2
                        ? int(data & 0x7F)
                        : int((uint64_t(packet->words[word + 1] >> 16) * 127ULL + 32767ULL) / 65535ULL);
                    const bool isNoteOn = type == 0x2 ? status == 0x90 : status == 0x9;
                    const bool isNoteOff = type == 0x2 ? status == 0x80 : status == 0x8;
                    const bool isCC = type == 0x2 ? status == 0xB0 : status == 0xB;
                    if (isCC) {
                        const int value = type == 0x2
                            ? int(data & 0x7F)
                            : int((uint64_t(packet->words[word + 1]) * 127ULL + 0x7FFFFFFFULL) / 0xFFFFFFFFULL);
                        mCCValues[note].store(std::clamp(value, 0, 127), std::memory_order_relaxed);
                        regridMomentaryRepeats(now, note);
                    } else if (isNoteOn && velocity > 0) { beginHeld(now, note, channel, velocity); }
                    else if (isNoteOff || (isNoteOn && velocity == 0)) { endHeld(now, note, channel); }
                }
                word += wordCount;
            }
            packet = MIDIEventPacketNext(packet);
        }
    }

    void beginHeld(AUEventSampleTime now, int note, int channel, int velocity) {
        if (note < 0 || note >= kNoteCount) { return; }
        mNoteDown[note].store(true, std::memory_order_relaxed);
        mLastInputNote.store(note, std::memory_order_relaxed);
        mInputActivityCounter.fetch_add(1, std::memory_order_relaxed);
        const auto clock = makeClock(now, 1);
        auto& held = mHeld[note];
        held.isHeld = true;
        held.velocity = uint8_t(std::clamp(velocity, 1, 127));
        held.channel = uint8_t(channel);
        held.repeatIndex = 0;
        held.patternGlobalStep = 0;
        held.patternPointValid = false;
        held.releaseAfterFirst = false;
        held.liveTapBeat = mTapLive.load() ? quantizedLiveTapBeat(clock.startBeat) : clock.startBeat;
        held.liveTapPending = mTapLive.load() && mTapLiveQuantizeMode.load() != 0;
        held.stopAfterLiveTap = false;
        held.gesture = -1;
        const auto settings = resolve(note, clock.startBeat, 0, clock.bpm);
        held.earliestRepeatBeat = mTapLive.load()
            ? tapLiveResumeBeat(held.liveTapBeat)
            : clock.startBeat;
        if (mTapLive.load() && !held.liveTapPending) { sendNoteOn(now, note, channel, velocity); }
        if (mPlaybackMode[note].load() == 1) {
            const auto point = nextPatternPoint(note, held.earliestRepeatBeat, 0, clock.bpm);
            held.nextBeat = point.beat;
            held.patternGlobalStep = point.globalStep;
            held.patternPointValid = point.valid;
            held.isSwungSide = positiveModulo(point.globalStep, 2) != 0;
        } else {
            const auto firstGrid = nextGridPoint(settings, held.earliestRepeatBeat, note, 0);
            held.nextBeat = firstGrid.beat;
            held.isSwungSide = firstGrid.isSwungSide;
        }
    }

    void endHeld(AUEventSampleTime now, int note, int channel) {
        if (note < 0 || note >= kNoteCount) { return; }
        mNoteDown[note].store(false, std::memory_order_relaxed);
        auto& held = mHeld[note];
        if (mTapLive.load() && held.liveTapPending) {
            held.stopAfterLiveTap = true;
            return;
        }
        if (!mTapLive.load() && mCaptureShortTaps.load() && mPlaybackMode[note].load() == 0
            && held.repeatIndex == 0 && held.gesture < 0) { held.releaseAfterFirst = true; }
        else { held.isHeld = false; }
        sendNoteOff(now, note, channel);
    }

    void sendNoteOn(AUEventSampleTime sample, int note, int channel, int velocity) {
        if (!mMIDIOutBlock) { return; }
        const UInt32 message = midi1ChannelVoiceWord(0x90, channel, note, std::clamp(velocity, 1, 127));
        MIDIEventList list = {};
        auto* packet = MIDIEventListInit(&list, kMIDIProtocol_1_0);
        MIDIEventListAdd(&list, sizeof(MIDIEventList), packet, 0, 1, &message);
        mMIDIOutBlock(sample, 0, &list);
    }

    void sendNoteOff(AUEventSampleTime sample, int note, int channel) {
        if (!mMIDIOutBlock) { return; }
        const UInt32 message = midi1ChannelVoiceWord(0x80, channel, note, 0);
        MIDIEventList list = {};
        auto* packet = MIDIEventListInit(&list, kMIDIProtocol_1_0);
        MIDIEventListAdd(&list, sizeof(MIDIEventList), packet, 0, 1, &message);
        mMIDIOutBlock(sample, 0, &list);
    }

    static UInt32 midi1ChannelVoiceWord(int status, int channel, int data1, int data2) {
        return (0x2u << 28)
             | (UInt32((status & 0xF0) | (channel & 0x0F)) << 16)
             | (UInt32(data1 & 0x7F) << 8)
             | UInt32(data2 & 0x7F);
    }

    AUHostMusicalContextBlock __strong mMusicalContextBlock = nil;
    AUMIDIEventListBlock __strong mMIDIOutBlock = nil;
    double mSampleRate = 44100.0;
    bool mHasClockSource = false;
    bool mUsingHostClock = false;
    bool mRenderContextValid = false;
    bool mLastClockValid = false;
    AUEventSampleTime mLastClockSample = 0;
    double mLastClockBeat = 0;
    double mLastClockBPM = 120;
    AUEventSampleTime mRenderStartSample = 0;
    double mRenderStartBeat = 0;
    double mRenderBPM = 120;
    std::atomic<bool> mBypassed { false };
    std::atomic<AUAudioFrameCount> mMaximumFrames { 1024 };
    std::atomic<bool> mHostSync { true };
    std::atomic<float> mManualBPM { 120.f };
    std::atomic<float> mSynchronizedBPM { 120.f };
    std::atomic<bool> mHasSynchronizedClock { false };
    std::atomic<bool> mClockResetRequested { true };
    std::atomic<int> mTimeScaleThousandths { 1000 };
    std::atomic<bool> mTimeScaleChanged { false };
    std::atomic<AUEventSampleTime> mManualOriginSample { -1 };
    std::atomic<bool> mFallbackOriginValid { false };
    std::atomic<int> mLastInputNote { -1 };
    std::atomic<uint64_t> mInputActivityCounter { 0 };
    std::atomic<double> mCurrentBeat { 0 };
    std::atomic<double> mCurrentBPM { 120 };
    std::array<std::atomic<int>, kNoteCount> mCCValues;
    std::array<std::atomic<bool>, kCCDestinationCount> mCCMappingEnabled;
    std::array<std::atomic<int>, kCCDestinationCount> mCCMappingNumber;
    std::atomic<bool> mCaptureShortTaps { true };
    std::atomic<bool> mTapLive { false };
    std::atomic<int> mTapLiveBufferDivision { 1 };
    std::atomic<int> mTapLiveQuantizeMode { 0 };
    std::atomic<int> mTapLiveStraightDivision { 5 };
    std::atomic<int> mTapLiveTripletDivision { 6 };
    std::atomic<bool> mTimingHumanizeEnabled { false };
    std::atomic<int> mTimingHumanizeMicroseconds { 8000 };
    std::atomic<int> mTimingHumanizeProbabilityThousandths { 1000 };
    std::atomic<int> mTimingHumanizeBiasThousandths { 0 };
    std::array<std::atomic<bool>, kMomentaryActionCount> mMomentaryEnabled;
    std::array<std::atomic<int>, kMomentaryActionCount> mMomentaryCC;
    std::atomic<int> mGestureRateMillionths { 250000 }, mGestureLengthSteps { 8 }, mGestureIntensityThousandths { 1000 };
    std::array<std::atomic<bool>, kGestureCount> mGestureEnabled;
    std::array<std::atomic<int>, kGestureCount> mGestureCC;
    std::array<std::atomic<bool>, kNoteCount> mNoteDown;
    std::array<std::atomic<int>, kNoteCount> mDivision, mSwingDivision, mSwingTenths, mVelocityMode, mFixedVelocity, mHumanize, mDivisionPath;
    std::array<std::atomic<bool>, kNoteCount> mRepeatFillEnabled;
    std::array<std::atomic<int>, kNoteCount> mRepeatFillAmountThousandths;
    std::array<std::atomic<int>, kNoteCount> mRepeatFillDensityThousandths;
    std::array<std::atomic<int>, kNoteCount> mRepeatFillProbabilityThousandths;
    std::array<std::atomic<int>, kNoteCount> mRepeatFillEveryBars;
    std::array<std::atomic<int>, kNoteCount> mRepeatFillSpeedSteps;
    std::array<std::atomic<int>, kNoteCount> mRepeatFillBalanceThousandths;
    std::array<std::atomic<int>, kNoteCount> mVelocityHumanize, mHumanizeProbabilityThousandths, mHumanizeBiasThousandths;
    std::array<std::atomic<int>, kNoteCount> mPlaybackMode, mPatternLengthSteps, mPatternStepMillionths;
    std::array<std::atomic<uint64_t>, kNoteCount> mPatternCoreMask, mPatternDetailMask, mPatternVariationMask, mPatternFillMask;
    std::array<std::atomic<int>, kNoteCount> mPatternVariationThousandths, mPatternAutoFillThousandths;
    std::array<std::atomic<int>, kNoteCount> mPatternFluctuationThousandths, mPatternProbabilityThousandths;
    std::array<std::atomic<int>, kNoteCount> mPatternComplexityThousandths, mPatternSeed;
    std::array<std::array<std::atomic<int>, kNoteCount>, 3> mModMode, mModRateTenThousandths, mModDepthTenths, mModDirection;
    std::array<std::array<std::atomic<int>, kNoteCount>, 3> mModClock, mModShape, mModSymmetryThousandths, mModCurveThousandths, mModPhaseThousandths;
    std::array<std::array<std::atomic<int>, kNoteCount>, 3> mModProbabilityBiasThousandths;
    std::array<std::array<std::array<std::atomic<int>, kCustomPointCount>, kNoteCount>, 3> mModCustomPointThousandths;
    std::array<Held, kNoteCount> mHeld {};
    std::array<PendingOff, kMaxPendingOffs> mPendingOffs {};
    int mPendingOffCount = 0;
    std::array<QueuedEvent, kMaxQueuedEvents> mQueued {};
    int mQueuedCount = 0;
};
