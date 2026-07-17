#import "RepeatizerKernelBridge.h"

#include <memory>

#include "RepeatizerAUProcessHelper.hpp"
#include "RepeatizerKernel.hpp"

@implementation RepeatizerKernelBridge {
    std::unique_ptr<RepeatizerKernel> _kernel;
    std::unique_ptr<RepeatizerAUProcessHelper> _processHelper;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _kernel = std::make_unique<RepeatizerKernel>();
        _processHelper = std::make_unique<RepeatizerAUProcessHelper>(*_kernel);
    }
    return self;
}

- (void)initializeWithSampleRate:(double)sampleRate { _kernel->initialize(sampleRate); }
- (void)deInitialize { _kernel->deInitialize(); }
- (BOOL)isBypassed { return _kernel->isBypassed(); }
- (void)setBypassed:(BOOL)bypassed { _kernel->setBypass(bypassed); }
- (AUAudioFrameCount)maximumFramesToRender { return _kernel->maximumFramesToRender(); }
- (void)setMaximumFramesToRender:(AUAudioFrameCount)frames { _kernel->setMaximumFramesToRender(frames); }
- (MIDIProtocolID)midiProtocol { return _kernel->AudioUnitMIDIProtocol(); }
- (NSInteger)lastInputNote { return _kernel->lastInputNote(); }
- (uint64_t)inputActivityCounter { return _kernel->inputActivityCounter(); }
- (double)currentBeat { return _kernel->currentBeat(); }
- (double)currentBPM { return _kernel->currentBPM(); }
- (BOOL)isNoteHeld:(NSInteger)note { return _kernel->isNoteHeld(int(note)); }
- (void)setMusicalContextBlock:(AUHostMusicalContextBlock)block { _kernel->setMusicalContextBlock(block); }
- (void)setMIDIOutputEventBlock:(AUMIDIEventListBlock)block { _kernel->setMIDIOutputEventBlock(block); }
- (AUInternalRenderBlock)internalRenderBlock { return _processHelper->internalRenderBlock(); }
- (void)setHostSync:(BOOL)hostSync { _kernel->setTempoMode(hostSync); }
- (void)setManualBPM:(double)bpm { _kernel->setManualBPM(bpm); }
- (void)setTimeScale:(double)multiplier { _kernel->setTimeScale(multiplier); }

- (void)configurePad:(NSInteger)note division:(NSInteger)division repeatFillEnabled:(BOOL)repeatFillEnabled repeatFillAmount:(double)repeatFillAmount repeatFillDensity:(double)repeatFillDensity repeatFillProbability:(double)repeatFillProbability repeatFillEveryBars:(NSInteger)repeatFillEveryBars repeatFillSpeedSteps:(NSInteger)repeatFillSpeedSteps repeatFillBalance:(double)repeatFillBalance swingDivision:(NSInteger)swingDivision swingPercent:(double)swingPercent velocityMode:(NSInteger)velocityMode fixedVelocity:(NSInteger)fixedVelocity humanizeAmount:(NSInteger)humanizeAmount velocityHumanize:(BOOL)velocityHumanize humanizeProbability:(double)humanizeProbability humanizeBias:(double)humanizeBias divisionMode:(NSInteger)divisionMode divisionRate:(double)divisionRate divisionDepth:(double)divisionDepth divisionDirection:(NSInteger)divisionDirection divisionClock:(NSInteger)divisionClock divisionShape:(NSInteger)divisionShape divisionSymmetry:(double)divisionSymmetry divisionCurve:(double)divisionCurve divisionPhase:(double)divisionPhase divisionProbabilityBias:(double)divisionProbabilityBias divisionPath:(NSInteger)divisionPath swingMode:(NSInteger)swingMode swingRate:(double)swingRate swingDepth:(double)swingDepth swingDirection:(NSInteger)swingDirection swingClock:(NSInteger)swingClock swingShape:(NSInteger)swingShape swingSymmetry:(double)swingSymmetry swingCurve:(double)swingCurve swingPhase:(double)swingPhase swingProbabilityBias:(double)swingProbabilityBias velocityModeMod:(NSInteger)velocityModeMod velocityRate:(double)velocityRate velocityDepth:(double)velocityDepth velocityDirection:(NSInteger)velocityDirection velocityClock:(NSInteger)velocityClock velocityShape:(NSInteger)velocityShape velocitySymmetry:(double)velocitySymmetry velocityCurve:(double)velocityCurve velocityPhase:(double)velocityPhase velocityProbabilityBias:(double)velocityProbabilityBias {
    _kernel->setPad(int(note), int(division), repeatFillEnabled, repeatFillAmount, repeatFillDensity, repeatFillProbability, int(repeatFillEveryBars), int(repeatFillSpeedSteps), repeatFillBalance, int(swingDivision), swingPercent, int(velocityMode), int(fixedVelocity), int(humanizeAmount),
                    velocityHumanize, humanizeProbability, humanizeBias,
                    int(divisionMode), divisionRate, divisionDepth, int(divisionDirection), int(divisionClock), int(divisionShape), divisionSymmetry, divisionCurve, divisionPhase, divisionProbabilityBias, int(divisionPath),
                    int(swingMode), swingRate, swingDepth, int(swingDirection), int(swingClock), int(swingShape), swingSymmetry, swingCurve, swingPhase, swingProbabilityBias,
                    int(velocityModeMod), velocityRate, velocityDepth, int(velocityDirection), int(velocityClock), int(velocityShape), velocitySymmetry, velocityCurve, velocityPhase, velocityProbabilityBias);
}

- (void)configurePattern:(NSInteger)note playbackMode:(NSInteger)playbackMode lengthSteps:(NSInteger)lengthSteps stepBeats:(double)stepBeats coreMask:(uint64_t)coreMask detailMask:(uint64_t)detailMask variationMask:(uint64_t)variationMask fillMask:(uint64_t)fillMask variation:(double)variation autoFill:(double)autoFill fluctuation:(double)fluctuation probability:(double)probability complexity:(double)complexity seed:(NSInteger)seed {
    _kernel->configurePattern(int(note), int(playbackMode), int(lengthSteps), stepBeats,
                              coreMask, detailMask, variationMask, fillMask,
                              variation, autoFill, fluctuation, probability, complexity, int(seed));
}

- (void)configureCustomLFO:(NSInteger)note lane:(NSInteger)lane points:(NSArray<NSNumber *> *)points {
    const NSInteger count = MIN(points.count, RepeatizerKernel::kCustomPointCount);
    for (NSInteger point = 0; point < count; ++point) {
        _kernel->setCustomPoint(int(lane), int(note), int(point), points[point].doubleValue);
    }
}

- (void)configureCCMapping:(NSInteger)destination enabled:(BOOL)enabled cc:(NSInteger)cc {
    _kernel->configureCCMapping(int(destination), enabled, int(cc));
}

- (void)setCaptureShortTaps:(BOOL)enabled { _kernel->setCaptureShortTaps(enabled); }
- (void)setTapLive:(BOOL)enabled { _kernel->setTapLive(enabled); }
- (void)setTapLiveBufferDivision:(NSInteger)division { _kernel->setTapLiveBufferDivision(int(division)); }
- (void)setTapLiveQuantizeMode:(NSInteger)mode straightDivision:(NSInteger)straightDivision tripletDivision:(NSInteger)tripletDivision {
    _kernel->setTapLiveQuantization(int(mode), int(straightDivision), int(tripletDivision));
}
- (void)setTimingHumanizeEnabled:(BOOL)enabled milliseconds:(double)milliseconds probability:(double)probability bias:(double)bias {
    _kernel->setTimingHumanize(enabled, milliseconds, probability, bias);
}
- (void)configureMomentaryCCAction:(NSInteger)action enabled:(BOOL)enabled cc:(NSInteger)cc {
    _kernel->configureMomentaryAction(int(action), enabled, int(cc));
}
- (void)configureGestureSettings:(double)rateBeats lengthSteps:(NSInteger)lengthSteps intensity:(double)intensity {
    _kernel->configureGestureSettings(rateBeats, int(lengthSteps), intensity);
}
- (void)configureGestureMapping:(NSInteger)gesture enabled:(BOOL)enabled cc:(NSInteger)cc {
    _kernel->configureGestureMapping(int(gesture), enabled, int(cc));
}

@end
