#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C surface for the C++ realtime engine. Swift owns editor state;
/// this bridge only copies primitive values into the lock-free kernel.
@interface RepeatizerKernelBridge : NSObject
- (void)initializeWithSampleRate:(double)sampleRate;
- (void)deInitialize;
- (BOOL)isBypassed;
- (void)setBypassed:(BOOL)bypassed;
- (AUAudioFrameCount)maximumFramesToRender;
- (void)setMaximumFramesToRender:(AUAudioFrameCount)frames;
- (MIDIProtocolID)midiProtocol;
- (NSInteger)lastInputNote;
- (uint64_t)inputActivityCounter;
- (double)currentBeat;
- (double)currentBPM;
- (BOOL)isNoteHeld:(NSInteger)note;
- (void)setMusicalContextBlock:(nullable AUHostMusicalContextBlock)block;
- (void)setMIDIOutputEventBlock:(nullable AUMIDIEventListBlock)block;
- (AUInternalRenderBlock)internalRenderBlock;
- (void)setHostSync:(BOOL)hostSync;
- (void)setManualBPM:(double)bpm;
- (void)configureTempoNudgeEnabled:(BOOL)enabled cc:(NSInteger)cc rangeBPM:(double)rangeBPM;
- (void)setTimeScale:(double)multiplier;
- (void)configurePad:(NSInteger)note
             division:(NSInteger)division
    repeatFillEnabled:(BOOL)repeatFillEnabled
     repeatFillAmount:(double)repeatFillAmount
    repeatFillDensity:(double)repeatFillDensity
repeatFillProbability:(double)repeatFillProbability
   repeatFillEveryBars:(NSInteger)repeatFillEveryBars
  repeatFillSpeedSteps:(NSInteger)repeatFillSpeedSteps
     repeatFillBalance:(double)repeatFillBalance
        swingDivision:(NSInteger)swingDivision
         swingPercent:(double)swingPercent
         velocityMode:(NSInteger)velocityMode
        fixedVelocity:(NSInteger)fixedVelocity
      humanizeAmount:(NSInteger)humanizeAmount
   velocityHumanize:(BOOL)velocityHumanize
 humanizeProbability:(double)humanizeProbability
        humanizeBias:(double)humanizeBias
         divisionMode:(NSInteger)divisionMode
         divisionRate:(double)divisionRate
        divisionDepth:(double)divisionDepth
    divisionDirection:(NSInteger)divisionDirection
        divisionClock:(NSInteger)divisionClock
        divisionShape:(NSInteger)divisionShape
     divisionSymmetry:(double)divisionSymmetry
        divisionCurve:(double)divisionCurve
        divisionPhase:(double)divisionPhase
divisionProbabilityBias:(double)divisionProbabilityBias
         divisionPath:(NSInteger)divisionPath
            swingMode:(NSInteger)swingMode
            swingRate:(double)swingRate
           swingDepth:(double)swingDepth
       swingDirection:(NSInteger)swingDirection
            swingClock:(NSInteger)swingClock
            swingShape:(NSInteger)swingShape
         swingSymmetry:(double)swingSymmetry
            swingCurve:(double)swingCurve
            swingPhase:(double)swingPhase
    swingProbabilityBias:(double)swingProbabilityBias
         velocityModeMod:(NSInteger)velocityModeMod
         velocityRate:(double)velocityRate
        velocityDepth:(double)velocityDepth
    velocityDirection:(NSInteger)velocityDirection
         velocityClock:(NSInteger)velocityClock
         velocityShape:(NSInteger)velocityShape
      velocitySymmetry:(double)velocitySymmetry
         velocityCurve:(double)velocityCurve
         velocityPhase:(double)velocityPhase
 velocityProbabilityBias:(double)velocityProbabilityBias;
- (void)configurePattern:(NSInteger)note
            playbackMode:(NSInteger)playbackMode
             lengthSteps:(NSInteger)lengthSteps
               stepBeats:(double)stepBeats
                coreMask:(uint64_t)coreMask
              detailMask:(uint64_t)detailMask
           variationMask:(uint64_t)variationMask
                fillMask:(uint64_t)fillMask
               variation:(double)variation
                autoFill:(double)autoFill
             fluctuation:(double)fluctuation
             probability:(double)probability
              complexity:(double)complexity
                    seed:(NSInteger)seed;
- (void)configureInstrumentEnabled:(BOOL)enabled
                       playbackMode:(NSInteger)playbackMode
                        octaveRange:(NSInteger)octaveRange
                               style:(NSInteger)style
                      patternVariant:(NSInteger)patternVariant
                           variation:(double)variation
              livePatternEnabled:(BOOL)livePatternEnabled
         livePatternPhraseLength:(NSInteger)livePatternPhraseLength
                 patternAutoFill:(double)patternAutoFill
              patternFluctuation:(double)patternFluctuation
              patternProbability:(double)patternProbability
               patternComplexity:(double)patternComplexity
                         arpGate:(double)arpGate
                                seed:(NSInteger)seed;
- (void)configureCustomLFO:(NSInteger)note lane:(NSInteger)lane points:(NSArray<NSNumber *> *)points;
- (void)configureCCMapping:(NSInteger)destination enabled:(BOOL)enabled cc:(NSInteger)cc;
- (void)setCaptureShortTaps:(BOOL)enabled;
- (void)setTapLive:(BOOL)enabled;
- (void)setTapLiveBufferDivision:(NSInteger)division;
- (void)setTapLiveQuantizeMode:(NSInteger)mode straightDivision:(NSInteger)straightDivision tripletDivision:(NSInteger)tripletDivision;
- (void)setTimingHumanizeEnabled:(BOOL)enabled
                     milliseconds:(double)milliseconds
                      probability:(double)probability
                             bias:(double)bias;
- (void)configureMomentaryCCAction:(NSInteger)action enabled:(BOOL)enabled cc:(NSInteger)cc;
- (void)configureGestureSettings:(double)rateBeats lengthSteps:(NSInteger)lengthSteps intensity:(double)intensity;
- (void)configureGestureMapping:(NSInteger)gesture enabled:(BOOL)enabled cc:(NSInteger)cc;
@end

NS_ASSUME_NONNULL_END
