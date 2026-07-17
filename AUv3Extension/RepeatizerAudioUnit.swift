import AVFoundation

/// Logic-facing AUv3 MIDI processor. UI edits are copied into the C++ realtime
/// kernel as atomic values, so per-pad modulation is safe while the transport runs.
public final class RepeatizerAudioUnit: AUAudioUnit, @unchecked Sendable {
    private let kernel = RepeatizerKernelBridge()
    private let stateLock = NSLock()
    private var storedConfiguration = RepeatizerPresets.gmStandard.configuration
    private var hasAppliedConfiguration = false
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var outputBus: AUAudioUnitBus!
    private var outputBusArray: AUAudioUnitBusArray!
    private lazy var repeatizerInternalRenderBlock = kernel.internalRenderBlock()

    @objc override public init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions) throws {
        try super.init(componentDescription: componentDescription, options: options)
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 2
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        kernel.initialize(withSampleRate: format.sampleRate)
        apply(configuration: RepeatizerPresets.gmStandard.configuration)
    }

    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    public override var maximumFramesToRender: AUAudioFrameCount {
        get { kernel.maximumFramesToRender() }
        set { kernel.setMaximumFramesToRender(newValue) }
    }
    public override var shouldBypassEffect: Bool {
        get { kernel.isBypassed() }
        set { kernel.setBypassed(newValue) }
    }
    public override var audioUnitMIDIProtocol: MIDIProtocolID { kernel.midiProtocol() }
    public override var internalRenderBlock: AUInternalRenderBlock { repeatizerInternalRenderBlock }
    public override var musicalContextBlock: AUHostMusicalContextBlock? {
        get { super.musicalContextBlock }
        set {
            super.musicalContextBlock = newValue
            kernel.setMusicalContextBlock(newValue)
        }
    }
    public override var midiOutputEventListBlock: AUMIDIEventListBlock? {
        get { super.midiOutputEventListBlock }
        set {
            super.midiOutputEventListBlock = newValue
            kernel.setMIDIOutputEventBlock(newValue)
        }
    }

    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            if let data = try? JSONEncoder().encode(currentConfiguration()) {
                state["repeatizer.configuration"] = data
            }
            return state
        }
        set {
            super.fullState = newValue
            if let data = newValue?["repeatizer.configuration"] as? Data,
               let configuration = try? JSONDecoder().decode(RepeatizerConfiguration.self, from: data) {
                apply(configuration: configuration)
            }
        }
    }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        kernel.setMusicalContextBlock(musicalContextBlock)
        kernel.setMIDIOutputEventBlock(midiOutputEventListBlock)
        kernel.initialize(withSampleRate: outputBus.format.sampleRate)
    }

    public override func deallocateRenderResources() {
        kernel.deInitialize()
        kernel.setMusicalContextBlock(nil)
        kernel.setMIDIOutputEventBlock(nil)
        super.deallocateRenderResources()
    }

    /// Applies the complete UI state. This is deliberately a small, deterministic
    /// handoff: the render thread never reads Swift collections or locks.
    public func apply(configuration: RepeatizerConfiguration) {
        stateLock.lock()
        let previous = storedConfiguration
        storedConfiguration = configuration
        let firstApply = !hasAppliedConfiguration
        hasAppliedConfiguration = true
        stateLock.unlock()
        kernel.setHostSync(configuration.tempoMode == .hostSync)
        kernel.setManualBPM(configuration.manualBPM)
        kernel.setTimeScale(configuration.timeScale.intervalMultiplier)
        kernel.setTimingHumanizeEnabled(
            configuration.timingHumanizeEnabled,
            milliseconds: configuration.timingHumanizeMilliseconds,
            probability: configuration.timingHumanizeProbability,
            bias: configuration.timingHumanizeBias
        )
        for (index, destination) in CCDestination.allCases.enumerated() {
            let mapping = configuration.liveCC.mapping(destination)
            kernel.configureCCMapping(
                index,
                enabled: [.swing, .velocity, .divisionDepth].contains(destination) && mapping.enabled,
                cc: mapping.ccNumber
            )
        }
        kernel.setCaptureShortTaps(configuration.captureShortTaps)
        kernel.setTapLive(configuration.tapLive)
        kernel.setTapLiveBufferDivision(configuration.tapLiveBuffer.rawValue)
        kernel.setTapLiveQuantizeMode(
            configuration.tapLiveQuantizeMode.kernelValue,
            straightDivision: configuration.tapLiveStraightDivision.rawValue,
            tripletDivision: configuration.tapLiveTripletDivision.rawValue
        )
        kernel.configureInstrumentEnabled(
            configuration.performanceSurface == .instrument,
            playbackMode: configuration.instrumentSettings.playbackMode.kernelValue,
            octaveRange: configuration.instrumentSettings.octaveRange,
            style: configuration.instrumentSettings.style.kernelValue,
            patternVariant: configuration.instrumentSettings.patternVariant,
            variation: configuration.instrumentSettings.variation,
            livePatternEnabled: configuration.instrumentSettings.livePatternEnabled,
            livePatternPhraseLength: configuration.instrumentSettings.livePatternPhraseLength,
            patternAutoFill: configuration.instrumentSettings.patternAutoFill,
            patternFluctuation: configuration.instrumentSettings.patternFluctuation,
            patternProbability: configuration.instrumentSettings.patternProbability,
            patternComplexity: configuration.instrumentSettings.patternComplexity,
            arpGate: configuration.instrumentSettings.arpGate,
            seed: configuration.instrumentSettings.seed
        )
        let retainedDivisionActions: [MomentaryCCAction] = [
            .straightUp1, .straightDown1, .tripletUp1, .tripletDown1
        ]
        for (index, action) in retainedDivisionActions.enumerated() {
            let mapping = configuration.liveCC.momentaryMapping(action)
            kernel.configureMomentaryCCAction(index, enabled: mapping.enabled, cc: mapping.ccNumber)
        }
        kernel.configureGestureSettings(0.25, lengthSteps: 1, intensity: 0)
        for (index, _) in DrumGestureKind.allCases.enumerated() {
            kernel.configureGestureMapping(index, enabled: false, cc: 0)
        }

        let notes: [Int]
        if firstApply || previous.performanceSurface != configuration.performanceSurface
            || previous.settingsMode != configuration.settingsMode
            || configuration.settingsMode == .master && previous.masterSettings != configuration.masterSettings {
            notes = Array(0...127)
        } else {
            notes = Array(Set(previous.pads.keys).union(configuration.pads.keys)).filter {
                previous.effectivePad($0) != configuration.effectivePad($0)
            }
        }
        for note in notes {
            let pad = configuration.effectivePad(note)
            kernel.configurePad(
                note, division: pad.division.rawValue,
                repeatFillEnabled: pad.repeatFillEnabled, repeatFillAmount: pad.repeatFillAmount,
                repeatFillDensity: pad.repeatFillDensity, repeatFillProbability: pad.repeatFillProbability,
                repeatFillEveryBars: pad.repeatFillEveryBars, repeatFillSpeedSteps: pad.repeatFillSpeedSteps,
                repeatFillBalance: pad.repeatFillBalance,
                swingDivision: pad.swingDivision.rawValue, swingPercent: pad.swingPercent,
                velocityMode: pad.velocityMode.kernelValue, fixedVelocity: pad.fixedVelocity, humanizeAmount: pad.humanizeAmount,
                velocityHumanize: pad.velocityHumanizeEnabled, humanizeProbability: pad.humanizeProbability, humanizeBias: pad.humanizeBias,
                divisionMode: 0, divisionRate: 0.5, divisionDepth: 0, divisionDirection: 2,
                divisionClock: 0, divisionShape: 0, divisionSymmetry: 0.5, divisionCurve: 0, divisionPhase: 0, divisionProbabilityBias: 0, divisionPath: 1,
                swingMode: 0, swingRate: 0.5, swingDepth: 0, swingDirection: 2,
                swingClock: 0, swingShape: 0, swingSymmetry: 0.5, swingCurve: 0, swingPhase: 0, swingProbabilityBias: 0,
                velocityModeMod: 0, velocityRate: 0.5, velocityDepth: 0, velocityDirection: 2,
                velocityClock: 0, velocityShape: 0, velocitySymmetry: 0.5, velocityCurve: 0, velocityPhase: 0, velocityProbabilityBias: 0
            )
            let pattern = DrumPatternLibrary.pattern(pad.patternID)
            kernel.configurePattern(
                note, playbackMode: pad.playbackMode == .pattern ? 1 : 0,
                lengthSteps: pattern.lengthSteps, stepBeats: pattern.stepDivision.beats,
                coreMask: pattern.coreMask, detailMask: pattern.detailMask,
                variationMask: pattern.variationMask, fillMask: pattern.fillMask,
                variation: pad.patternVariation, autoFill: pad.patternAutoFill,
                fluctuation: pad.patternFluctuation, probability: pad.patternProbability,
                complexity: pad.patternComplexity, seed: pad.patternSeed
            )
        }
    }

    func currentConfiguration() -> RepeatizerConfiguration {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedConfiguration
    }

    func inputActivityCounter() -> UInt64 { kernel.inputActivityCounter() }
    func currentBeat() -> Double { kernel.currentBeat() }
    func currentBPM() -> Double { kernel.currentBPM() }
    func lastInputNote() -> Int { kernel.lastInputNote() }
    func isNoteHeld(_ note: Int) -> Bool { kernel.isNoteHeld(note) }
}

private extension VelocityMode {
    var kernelValue: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

private extension LiveTapQuantizeMode {
    var kernelValue: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

private extension ModulationMode {
    var kernelValue: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

private extension ModulationDirection {
    var kernelValue: Int { Self.allCases.firstIndex(of: self) ?? 2 }
}

private extension ModulationClock {
    var kernelValue: Int { self == .sync ? 0 : 1 }
}

private extension LFOShape {
    var kernelValue: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

private extension DivisionModulationPath {
    var kernelValue: Int { self == .sameFeel ? 1 : 0 }
}
