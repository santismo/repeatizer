import SwiftUI

@MainActor
private final class RepeatizerPluginModel: ObservableObject {
    let audioUnit: RepeatizerAudioUnit
    @Published var configuration: RepeatizerConfiguration
    @Published var selectedNote: Int?
    @Published var theme = PluginTheme.dark
    @Published var presetID = RepeatizerPresets.gmStandard.id
    @Published var randomGenre: DrumPatternStyle = .foundation
    @Published var randomMode: AllPadRandomMode = .selectedGenre
    @Published var heldNotes: Set<Int> = []
    @Published var liveNote: Int?
    @Published var capturedInputNote: Int?
    @Published var settingsVisible = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var lastActivityCounter: UInt64 = 0
    private var liveUntil = Date.distantPast
    private var undoStack: [RepeatizerConfiguration] = []
    private var redoStack: [RepeatizerConfiguration] = []
    private var lastHistoryAction: String?
    private var lastHistoryDate = Date.distantPast
    private var patternRandomNonce = 0
    private var instrumentRandomNonce = 0

    init(audioUnit: RepeatizerAudioUnit) {
        self.audioUnit = audioUnit
        configuration = audioUnit.currentConfiguration()
        presetID = RepeatizerPresets.all.first(where: { $0.configuration == configuration })?.id ?? "custom"
    }

    var selectedPad: PadConfiguration {
        selectedNote.map(configuration.effectivePad) ?? configuration.masterSettings
    }

    var selectedPattern: DrumPatternDefinition { DrumPatternLibrary.pattern(selectedPad.patternID) }
    var selectedPatternRole: DrumPatternRole {
        guard let selectedNote else { return .universal }
        return selectedPad.patternRoleOverride ?? DrumPatternLibrary.inferredRole(forMIDINote: selectedNote)
    }

    var selectedIsFollower: Bool {
        selectedNote.map(configuration.followerNotes.contains) ?? false
    }

    var selectedIsMaster: Bool { selectedNote == configuration.masterNote }

    func select(_ note: Int) {
        selectedNote = note
        settingsVisible = true
    }
    func closeEditor() { settingsVisible = false }
    func toggleEditor() {
        if selectedNote == nil { selectedNote = configuration.visibleNotes.first }
        guard selectedNote != nil else { return }
        settingsVisible.toggle()
    }

    func updateSelected(_ change: (inout PadConfiguration) -> Void) {
        guard let selectedNote else { return }
        mutate(action: "pad-\(selectedNote)") { configuration in
            configuration.updateActivePad(selectedNote, change)
        }
    }

    func applyPreset(_ id: String) {
        guard let preset = RepeatizerPresets.all.first(where: { $0.id == id }) else { return }
        mutate(action: "preset") { $0 = preset.configuration }
        presetID = id
        selectedNote = nil
        settingsVisible = false
    }

    func makeSelectedMaster() {
        guard let selectedNote else { return }
        mutate(action: "master") { configuration in
            if configuration.masterNote == selectedNote { configuration.setMaster(nil) }
            else { configuration.setMaster(selectedNote) }
        }
    }

    func toggleSelectedFollower() {
        guard let selectedNote else { return }
        let follows = !selectedIsFollower
        mutate(action: "follower-\(selectedNote)") { $0.setFollower(selectedNote, follows: follows) }
    }

    var allVisiblePadsFollowMaster: Bool {
        guard let master = configuration.masterNote else { return false }
        let candidates = configuration.visibleNotes.filter { $0 != master }
        return !candidates.isEmpty && candidates.allSatisfy(configuration.followerNotes.contains)
    }

    func toggleAllFollowers() {
        guard configuration.masterNote != nil else { return }
        let shouldFollow = !allVisiblePadsFollowMaster
        mutate(action: "all-followers") { $0.setAllVisiblePadsFollowing(shouldFollow) }
    }

    func addPad(_ note: Int) {
        mutate(action: "add-pad") { $0.addVisiblePad(note) }
        selectedNote = note
        settingsVisible = true
    }

    func beginPadLearn() { capturedInputNote = nil }

    func removeSelectedPad() {
        guard let selectedNote else { return }
        mutate(action: "remove-pad") { $0.removeVisiblePad(selectedNote) }
        self.selectedNote = nil
        settingsVisible = false
    }

    func setTempoMode(_ mode: TempoMode) {
        mutate(action: "clock-mode") { $0.tempoMode = mode }
    }

    func setManualBPM(_ bpm: Double) {
        mutate(action: "manual-bpm") { $0.manualBPM = min(max(bpm, 30), 300) }
    }

    func setTimeScale(_ scale: GlobalTimeScale) {
        mutate(action: "time-scale") { $0.timeScale = scale }
    }

    func setTimingHumanize(_ enabled: Bool) {
        mutate(action: "timing-humanize") { $0.timingHumanizeEnabled = enabled }
    }

    func setTimingHumanizeMilliseconds(_ milliseconds: Double) {
        mutate(action: "timing-humanize-amount") {
            $0.timingHumanizeMilliseconds = min(max(milliseconds, 0), 30)
        }
    }

    func setTimingHumanizeProbability(_ probability: Double) {
        mutate(action: "timing-humanize-probability") {
            $0.timingHumanizeProbability = min(max(probability, 0), 1)
        }
    }

    func setTimingHumanizeBias(_ bias: Double) {
        mutate(action: "timing-humanize-bias") {
            $0.timingHumanizeBias = min(max(bias, -1), 1)
        }
    }

    func setSettingsMode(_ mode: SettingsMode) {
        mutate(action: "settings-mode") { $0.settingsMode = mode }
        if selectedNote == nil { selectedNote = configuration.visibleNotes.first }
    }

    func setPerformanceSurface(_ surface: PerformanceSurface) {
        mutate(action: "performance-surface") { configuration in
            configuration.performanceSurface = surface
            // Instrument mode routes every held pitch through the master lane,
            // so a played chord shares one repeat rhythm.
            if surface == .instrument {
                configuration.settingsMode = .master
                configuration.tapLive = false
            }
        }
        if surface == .instrument {
            selectedNote = nil
            settingsVisible = false
        }
    }

    func setInstrumentDivision(_ division: RepeatDivision) {
        mutate(action: "instrument-division") { configuration in
            configuration.performanceSurface = .instrument
            configuration.settingsMode = .master
            configuration.tapLive = false
            configuration.masterSettings.playbackMode = .repeatNote
            configuration.masterSettings.division = division
            configuration.masterSettings.repeatFillEnabled = false
        }
    }

    func setInstrumentSwing(_ swing: Double) {
        mutate(action: "instrument-swing") { configuration in
            configuration.performanceSurface = .instrument
            configuration.settingsMode = .master
            configuration.tapLive = false
            configuration.masterSettings.playbackMode = .repeatNote
            configuration.masterSettings.swingPercent = min(max(swing, 50), 75)
        }
    }

    func setInstrumentPlaybackMode(_ mode: InstrumentPlaybackMode) {
        mutate(action: "instrument-playback-mode") { configuration in
            configuration.performanceSurface = .instrument
            configuration.settingsMode = .master
            configuration.tapLive = false
            configuration.masterSettings.playbackMode = .repeatNote
            configuration.instrumentSettings.playbackMode = mode
        }
    }

    func setInstrumentStyle(_ style: InstrumentStyle) {
        mutate(action: "instrument-style") { configuration in
            configuration.performanceSurface = .instrument
            configuration.settingsMode = .master
            configuration.tapLive = false
            configuration.masterSettings.playbackMode = .repeatNote
            configuration.instrumentSettings.style = style
        }
    }

    func setInstrumentPatternVariant(_ variant: Int) {
        mutate(action: "instrument-pattern-variant") { configuration in
            configuration.performanceSurface = .instrument
            configuration.settingsMode = .master
            configuration.tapLive = false
            configuration.masterSettings.playbackMode = .repeatNote
            configuration.instrumentSettings.patternVariant = min(max(variant, 0), 7)
        }
    }

    func setInstrumentOctaveRange(_ octaves: Int) {
        mutate(action: "instrument-octaves") { configuration in
            configuration.performanceSurface = .instrument
            configuration.settingsMode = .master
            configuration.instrumentSettings.octaveRange = min(max(octaves, -2), 2)
        }
    }

    func setInstrumentVariation(_ variation: Double) {
        mutate(action: "instrument-variation") { configuration in
            configuration.performanceSurface = .instrument
            configuration.settingsMode = .master
            configuration.instrumentSettings.variation = min(max(variation, 0), 1)
        }
    }

    func setInstrumentLivePattern(_ enabled: Bool) {
        mutate(action: "instrument-live-pattern") {
            $0.instrumentSettings.livePatternEnabled = enabled
        }
    }

    func setInstrumentLivePatternPhraseLength(_ length: Int) {
        mutate(action: "instrument-live-phrase") {
            $0.instrumentSettings.livePatternPhraseLength = [1, 2, 4, 8].contains(length) ? length : 1
        }
    }

    func setInstrumentPatternAutoFill(_ value: Double) {
        mutate(action: "instrument-pattern-fill") { $0.instrumentSettings.patternAutoFill = min(max(value, 0), 1) }
    }

    func setInstrumentPatternFluctuation(_ value: Double) {
        mutate(action: "instrument-pattern-fluctuation") { $0.instrumentSettings.patternFluctuation = min(max(value, 0), 1) }
    }

    func setInstrumentPatternProbability(_ value: Double) {
        mutate(action: "instrument-pattern-probability") { $0.instrumentSettings.patternProbability = min(max(value, 0), 1) }
    }

    func setInstrumentPatternComplexity(_ value: Double) {
        mutate(action: "instrument-pattern-complexity") { $0.instrumentSettings.patternComplexity = min(max(value, 0), 1) }
    }

    func setInstrumentArpGate(_ value: Double) {
        mutate(action: "instrument-arp-gate") { $0.instrumentSettings.arpGate = min(max(value, 0.05), 1) }
    }

    func randomizeArpeggiator() {
        instrumentRandomNonce &+= 1
        let token = max(1, instrumentRandomNonce)
        mutate(action: "instrument-arp-random-\(token)") { configuration in
            configuration.instrumentSettings.seed = token &* 97 &+ 11
        }
    }

    func setInstrumentVelocityMode(_ mode: VelocityMode) {
        mutate(action: "instrument-velocity-mode") { $0.masterSettings.velocityMode = mode }
    }

    func setInstrumentFixedVelocity(_ velocity: Int) {
        mutate(action: "instrument-fixed-velocity") { $0.masterSettings.fixedVelocity = min(max(velocity, 1), 127) }
    }

    func setInstrumentVelocityHumanize(_ enabled: Bool) {
        mutate(action: "instrument-velocity-humanize") {
            if $0.masterSettings.velocityMode == .humanized { $0.masterSettings.velocityMode = .received }
            $0.masterSettings.velocityHumanizeEnabled = enabled
        }
    }

    func setInstrumentHumanizeAmount(_ amount: Int) {
        mutate(action: "instrument-humanize-amount") { $0.masterSettings.humanizeAmount = min(max(amount, 0), 64) }
    }

    func setInstrumentHumanizeProbability(_ value: Double) {
        mutate(action: "instrument-humanize-probability") { $0.masterSettings.humanizeProbability = min(max(value, 0), 1) }
    }

    func setInstrumentHumanizeBias(_ value: Double) {
        mutate(action: "instrument-humanize-bias") { $0.masterSettings.humanizeBias = min(max(value, -1), 1) }
    }

    func smartRandomizeInstrument() {
        guard configuration.instrumentSettings.playbackMode == .chord else { return }
        instrumentRandomNonce &+= 1
        let token = max(1, instrumentRandomNonce)
        let styles = InstrumentStyle.allCases
        mutate(action: "instrument-smart-random-\(token)") { configuration in
            configuration.performanceSurface = .instrument
            configuration.settingsMode = .master
            configuration.tapLive = false
            configuration.masterSettings.playbackMode = .repeatNote
            configuration.instrumentSettings.style = styles[(token &* 7 &+ 3) % styles.count]
            configuration.instrumentSettings.patternVariant = (token &* 3 &+ 2) % 8
            configuration.instrumentSettings.playbackMode = .chord
            configuration.instrumentSettings.octaveRange = [-2, -1, 0, 1, 2][token % 5]
            configuration.instrumentSettings.variation = [0.12, 0.28, 0.45, 0.62][token % 4]
            configuration.instrumentSettings.livePatternEnabled = token % 2 == 0
            configuration.instrumentSettings.livePatternPhraseLength = [1, 2, 4][token % 3]
            configuration.instrumentSettings.patternAutoFill = [0.05, 0.16, 0.28][token % 3]
            configuration.instrumentSettings.patternFluctuation = [0.08, 0.15, 0.24][token % 3]
            configuration.instrumentSettings.patternProbability = [0.82, 0.9, 0.96][token % 3]
            configuration.instrumentSettings.patternComplexity = [0.3, 0.52, 0.75][token % 3]
            configuration.instrumentSettings.seed = token &* 97 &+ 11
        }
    }

    func setCaptureShortTaps(_ enabled: Bool) {
        mutate(action: "capture-short-taps") { $0.captureShortTaps = enabled }
    }

    func setTapLive(_ enabled: Bool) {
        mutate(action: "tap-live") { $0.tapLive = enabled }
    }

    func setTapLiveBuffer(_ division: RepeatDivision) {
        mutate(action: "tap-live-buffer") { $0.tapLiveBuffer = division }
    }

    func setTapLiveQuantizeMode(_ mode: LiveTapQuantizeMode) {
        mutate(action: "tap-live-grid") { $0.tapLiveQuantizeMode = mode }
    }

    func setTapLiveStraightDivision(_ division: RepeatDivision) {
        guard !division.isTriplet else { return }
        mutate(action: "tap-live-straight-grid") { $0.tapLiveStraightDivision = division }
    }

    func setTapLiveTripletDivision(_ division: RepeatDivision) {
        guard division.isTriplet else { return }
        mutate(action: "tap-live-triplet-grid") { $0.tapLiveTripletDivision = division }
    }

    func performAllPatternRandomization() {
        switch randomMode {
        case .selectedGenre: randomizeAllPatterns(in: randomGenre)
        case .smartOneGenre: smartRandomizeAllPatterns()
        case .mixedGenres: randomizeAllPatterns()
        }
    }

    func setPlaybackMode(_ mode: PadPlaybackMode) {
        updateSelected { $0.playbackMode = mode }
    }

    func setSelectedPattern(_ id: Int) {
        guard let selectedNote else { return }
        mutate(action: "pattern-selection-\(selectedNote)") { configuration in
            configuration.updatePatternIdentity(selectedNote) {
                $0.patternID = id
                $0.patternSeed = nextPatternToken()
            }
        }
    }

    func setSelectedPatternRole(_ role: DrumPatternRole) {
        guard let selectedNote else { return }
        let current = selectedPattern
        let variant = current.id % DrumPatternLibrary.variantCount
        mutate(action: "pattern-role-\(selectedNote)") { configuration in
            configuration.updatePatternIdentity(selectedNote) {
                $0.patternRoleOverride = role
                $0.patternID = DrumPatternLibrary.patternID(style: current.style, role: role, variant: variant)
                $0.patternSeed = nextPatternToken()
            }
        }
    }

    func setSelectedPatternStyle(_ style: DrumPatternStyle) {
        guard let selectedNote else { return }
        let current = selectedPattern
        let variant = current.id % DrumPatternLibrary.variantCount
        let role = selectedPatternRole
        mutate(action: "pattern-style-\(selectedNote)") { configuration in
            configuration.updatePatternIdentity(selectedNote) {
                $0.patternID = DrumPatternLibrary.patternID(style: style, role: role, variant: variant)
                $0.patternSeed = nextPatternToken()
            }
        }
    }

    func togglePatternLock(_ note: Int) {
        mutate(action: "pattern-lock-\(note)-\(nextPatternToken())") { configuration in
            configuration.updatePatternIdentity(note) { $0.patternLocked.toggle() }
        }
    }

    func randomizePattern(_ note: Int) {
        let token = nextPatternToken()
        let current = configuration.effectivePad(note)
        let role = current.patternRoleOverride ?? DrumPatternLibrary.inferredRole(forMIDINote: note)
        let currentStyle = DrumPatternLibrary.pattern(current.patternID).style
        let palette = currentStyle.compatibleStyles
        let style = palette[(token &* 7 &+ note) % palette.count]
        let variants = [0, 1, 2, 3, 7, 8, 9, 10, 11, 15, 19]
        let variant = variants[(token &* 3 &+ note) % variants.count]
        mutate(action: "pattern-random-\(note)-\(token)") { configuration in
            configuration.updateActivePad(note) { $0.playbackMode = .pattern }
            configuration.updatePatternIdentity(note) {
                $0.patternID = DrumPatternLibrary.patternID(style: style, role: role, variant: variant)
                $0.patternSeed = token
            }
        }
    }

    func randomizeAllPatterns() {
        let token = nextPatternToken()
        let notes = configuration.visibleNotes
        guard !notes.isEmpty else { return }
        let styles = DrumPatternStyle.allCases
        let seedStyle = styles[(token &* 13 &+ 5) % styles.count]
        let palette = seedStyle.compatibleStyles
        let variants = [0, 1, 2, 3, 7, 8, 9, 10, 11, 15, 19]
        let sharedVariant = variants[(token &* 5 &+ 1) % variants.count]

        mutate(action: "pattern-random-all-\(token)") { configuration in
            if configuration.settingsMode == .master {
                configuration.masterSettings.playbackMode = .pattern
            }
            for note in notes where !configuration.effectivePad(note).patternLocked {
                if configuration.settingsMode == .individual && !configuration.followerNotes.contains(note) {
                    var pad = configuration.pad(note)
                    pad.playbackMode = .pattern
                    configuration.pads[note] = pad
                }
                guard !configuration.followerNotes.contains(note) else { continue }
                let currentPad = configuration.effectivePad(note)
                let role = currentPad.patternRoleOverride ?? DrumPatternLibrary.inferredRole(forMIDINote: note)
                // Mixed mode stays adventurous without assembling unrelated phrase
                // lengths or incompatible genre families on adjacent drum pieces.
                let style = palette[(token &* 13 &+ note &* 7) % palette.count]
                var identity = configuration.pad(note)
                identity.patternID = DrumPatternLibrary.patternID(style: style, role: role, variant: sharedVariant)
                identity.patternSeed = token &+ note
                configuration.pads[note] = identity
            }
            if configuration.settingsMode == .individual, let master = configuration.masterNote {
                let masterPad = configuration.pad(master)
                for follower in configuration.followerNotes { configuration.pads[follower] = masterPad }
            }
        }
    }

    func randomizeAllPatterns(in style: DrumPatternStyle) {
        let token = nextPatternToken()
        let notes = configuration.visibleNotes
        guard !notes.isEmpty else { return }
        let variants = [0, 1, 2, 3, 7, 8, 9, 10, 11, 15, 19]
        let sharedVariant = variants[(token &* 5 &+ 1) % variants.count]

        mutate(action: "pattern-genre-all-\(style.rawValue)-\(token)") { configuration in
            if configuration.settingsMode == .master {
                configuration.masterSettings.playbackMode = .pattern
            }
            for note in notes where !configuration.effectivePad(note).patternLocked {
                if configuration.settingsMode == .individual && !configuration.followerNotes.contains(note) {
                    var pad = configuration.pad(note)
                    pad.playbackMode = .pattern
                    configuration.pads[note] = pad
                }
                guard !configuration.followerNotes.contains(note) else { continue }
                let currentPad = configuration.effectivePad(note)
                let role = currentPad.patternRoleOverride ?? DrumPatternLibrary.inferredRole(forMIDINote: note)
                var identity = configuration.pad(note)
                identity.patternID = DrumPatternLibrary.patternID(style: style, role: role, variant: sharedVariant)
                identity.patternSeed = token &+ note
                configuration.pads[note] = identity
            }
            if configuration.settingsMode == .individual, let master = configuration.masterNote {
                let masterPad = configuration.pad(master)
                for follower in configuration.followerNotes { configuration.pads[follower] = masterPad }
            }
        }
    }

    func smartRandomizeAllPatterns() {
        let token = nextPatternToken()
        let notes = configuration.visibleNotes
        guard !notes.isEmpty else { return }
        let styles = DrumPatternStyle.allCases
        let sharedStyle = styles[(token &* 7 &+ 3) % styles.count]
        randomGenre = sharedStyle
        // These catalog families resolve to compatible 4- or 8-beat phrases,
        // allowing one shared genre to remain coherent across every drum role.
        let compatibleVariants = [0, 1, 2, 3, 7, 8, 9, 10, 11, 15, 19]
        let sharedVariant = compatibleVariants[token % compatibleVariants.count]

        mutate(action: "pattern-smart-all-\(token)") { configuration in
            if configuration.settingsMode == .master {
                configuration.masterSettings.playbackMode = .pattern
            }
            for note in notes where !configuration.effectivePad(note).patternLocked {
                if configuration.settingsMode == .individual && !configuration.followerNotes.contains(note) {
                    var pad = configuration.pad(note)
                    pad.playbackMode = .pattern
                    configuration.pads[note] = pad
                }
                guard !configuration.followerNotes.contains(note) else { continue }
                let currentPad = configuration.effectivePad(note)
                let role = currentPad.patternRoleOverride ?? DrumPatternLibrary.inferredRole(forMIDINote: note)
                var identity = configuration.pad(note)
                identity.patternID = DrumPatternLibrary.patternID(
                    style: sharedStyle, role: role, variant: sharedVariant
                )
                identity.patternSeed = token &* 31 &+ note
                configuration.pads[note] = identity
            }
            if configuration.settingsMode == .individual, let master = configuration.masterNote {
                let masterPad = configuration.pad(master)
                for follower in configuration.followerNotes { configuration.pads[follower] = masterPad }
            }
        }
    }

    func resetAll() {
        let retainedMappings = configuration.liveCC
        mutate(action: "reset-all") { configuration in
            configuration = RepeatizerPresets.gmStandard.configuration
            configuration.liveCC = retainedMappings
        }
        theme = .dark
        presetID = RepeatizerPresets.gmStandard.id
        randomGenre = .foundation
        randomMode = .selectedGenre
        selectedNote = nil
        settingsVisible = false
    }

    func updateLiveCC(_ action: String, _ change: (inout LiveCCConfiguration) -> Void) {
        mutate(action: "live-cc-\(action)") { change(&$0.liveCC) }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(configuration)
        configuration = previous
        finishHistoryNavigation()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(configuration)
        configuration = next
        finishHistoryNavigation()
    }

    func pollInput() {
        refreshConfigurationRestoredByHost()

        let monitoredNotes = configuration.performanceSurface == .instrument
            ? Array(0...127)
            : configuration.visibleNotes
        let nextHeld = Set(monitoredNotes.filter(audioUnit.isNoteHeld))
        if nextHeld != heldNotes { heldNotes = nextHeld }

        let activity = audioUnit.inputActivityCounter()
        if activity != lastActivityCounter {
            lastActivityCounter = activity
            let note = audioUnit.lastInputNote()
            liveNote = note
            capturedInputNote = note
            liveUntil = Date().addingTimeInterval(0.34)
            if configuration.performanceSurface == .drums, configuration.visibleNotes.contains(note) {
                selectedNote = note
            }
        } else if let liveNote, !nextHeld.contains(liveNote), Date() > liveUntil {
            self.liveNote = nil
        }
    }

    func push() { audioUnit.apply(configuration: configuration) }

    private func nextPatternToken() -> Int {
        patternRandomNonce &+= 1
        return max(1, patternRandomNonce)
    }

    private static func resetPatternControls(_ pad: inout PadConfiguration) {
        pad.playbackMode = .repeatNote
        pad.patternVariation = 0
        pad.patternAutoFill = 0
        pad.patternFluctuation = 0
        pad.patternProbability = 1
        pad.patternComplexity = 0.55
    }

    private func mutate(action: String, _ change: (inout RepeatizerConfiguration) -> Void) {
        let before = configuration
        change(&configuration)
        guard configuration != before else { return }
        let now = Date()
        if lastHistoryAction != action || now.timeIntervalSince(lastHistoryDate) > 0.45 {
            undoStack.append(before)
            if undoStack.count > 80 { undoStack.removeFirst() }
        }
        lastHistoryAction = action
        lastHistoryDate = now
        redoStack.removeAll()
        // Any manual edit is custom. Avoid comparing every pad/LFO point against
        // every preset on each slider tick or CC assignment.
        presetID = "custom"
        updateHistoryAvailability()
        push()
    }

    private func finishHistoryNavigation() {
        lastHistoryAction = nil
        presetID = RepeatizerPresets.all.first(where: { $0.configuration == configuration })?.id ?? "custom"
        if let selectedNote, !configuration.visibleNotes.contains(selectedNote) { self.selectedNote = nil }
        updateHistoryAvailability()
        push()
    }

    private func updateHistoryAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Logic is allowed to restore an AU's full state after it has requested the
    /// editor. In that order, the editor's initial snapshot can be stale even
    /// though the realtime kernel has already received the restored clock mode.
    /// Polling the small value type from the UI timer keeps the displayed mode
    /// and BPM aligned with the actual AU state without ever touching audio work.
    private func refreshConfigurationRestoredByHost() {
        let restored = audioUnit.currentConfiguration()
        guard restored != configuration else { return }

        configuration = restored
        presetID = RepeatizerPresets.all.first(where: { $0.configuration == restored })?.id ?? "custom"
        undoStack.removeAll()
        redoStack.removeAll()
        lastHistoryAction = nil
        if let selectedNote, !restored.visibleNotes.contains(selectedNote) {
            self.selectedNote = nil
            settingsVisible = false
        }
        updateHistoryAvailability()
    }
}

private enum AllPadRandomMode: String, CaseIterable, Identifiable {
    case selectedGenre = "Selected Genre"
    case smartOneGenre = "Smart · One Genre"
    case mixedGenres = "Smart · Mixed Genres"

    var id: String { rawValue }
}

private enum PluginTheme: String, CaseIterable, Identifiable {
    case dark = "Dark"
    case graphite = "Graphite"
    case studio = "Studio"
    case console = "Console"

    var id: String { rawValue }
    var isLight: Bool { self == .studio }
    var windowTop: Color {
        switch self {
        case .dark: Color(red: 0.035, green: 0.035, blue: 0.038)
        case .graphite: Color(red: 0.106, green: 0.125, blue: 0.145)
        case .studio: Color(red: 0.80, green: 0.82, blue: 0.85)
        case .console: Color(red: 0.025, green: 0.086, blue: 0.125)
        }
    }
    var windowBottom: Color {
        switch self {
        case .dark: Color.black
        case .graphite: Color(red: 0.043, green: 0.055, blue: 0.066)
        case .studio: Color(red: 0.64, green: 0.67, blue: 0.71)
        case .console: Color(red: 0.008, green: 0.028, blue: 0.045)
        }
    }
    var panel: Color {
        switch self {
        case .dark: Color(red: 0.075, green: 0.075, blue: 0.08)
        case .graphite: Color(red: 0.137, green: 0.161, blue: 0.184)
        case .studio: Color(red: 0.84, green: 0.86, blue: 0.89)
        case .console: Color(red: 0.043, green: 0.126, blue: 0.17)
        }
    }
    var raised: Color {
        switch self {
        case .dark: Color(red: 0.13, green: 0.13, blue: 0.14)
        case .graphite: Color(red: 0.176, green: 0.204, blue: 0.231)
        case .studio: Color(red: 0.72, green: 0.75, blue: 0.79)
        case .console: Color(red: 0.055, green: 0.16, blue: 0.21)
        }
    }
    var board: Color {
        switch self {
        case .dark: Color(red: 0.022, green: 0.022, blue: 0.024)
        case .graphite: Color(red: 0.071, green: 0.086, blue: 0.10)
        case .studio: Color(red: 0.68, green: 0.71, blue: 0.75)
        case .console: Color(red: 0.018, green: 0.061, blue: 0.084)
        }
    }
    var line: Color { isLight ? Color.black.opacity(0.24) : Color.white.opacity(0.20) }
    var text: Color { isLight ? Color(red: 0.08, green: 0.09, blue: 0.105) : Color.white.opacity(0.96) }
    var muted: Color { isLight ? Color.black.opacity(0.56) : Color.white.opacity(0.56) }
    var note: Color { self == .dark ? .white : (self == .console ? Color(red: 0.18, green: 0.87, blue: 0.72) : Color(red: 0.29, green: 0.72, blue: 0.64)) }
    var master: Color { self == .dark ? Color.white.opacity(0.82) : Color(red: 0.94, green: 0.65, blue: 0.24) }
    var live: Color { self == .dark ? .white : Color(red: 0.28, green: 0.86, blue: 0.56) }
    var headerColors: [Color] { [panel.opacity(0.76), panel.opacity(0.76)] }
}

private enum RTType {
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Avenir Next", fixedSize: size).weight(weight)
    }
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .custom("Avenir Next Condensed", fixedSize: size).weight(weight)
    }
    static func label(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .custom("Avenir Next", fixedSize: size).weight(weight)
    }
}

private enum AuxiliaryPanel: Equatable {
    case ccMappings
    case addPad
}

/// Keep the mode selector and BPM control in one stable view hierarchy. The
/// BPM control remains visible in Sync mode (but is disabled and labelled as
/// host-controlled), so a delayed host-state restore can never leave Manual
/// selected with no tempo control on screen.
private struct ClockControls: View {
    @ObservedObject var model: RepeatizerPluginModel
    let theme: PluginTheme

    private var isManual: Bool { model.configuration.tempoMode == .manual }

    var body: some View {
        HStack(spacing: 6) {
            Text("CLOCK")
                .font(RTType.label(9))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: true, vertical: false)

            Picker("Clock", selection: Binding(
                get: { model.configuration.tempoMode },
                set: { model.setTempoMode($0) }
            )) {
                ForEach(TempoMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 116)

            HStack(spacing: 6) {
                Slider(value: Binding(
                    get: { model.configuration.manualBPM },
                    set: { model.setManualBPM($0) }
                ), in: 30...300, step: 0.1)
                    .tint(isManual ? theme.note : theme.muted)
                    .frame(width: 86)

                TextField("BPM", value: Binding(
                    get: { model.configuration.manualBPM },
                    set: { model.setManualBPM($0) }
                ), format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 54)

                Text(isManual ? "BPM" : "HOST")
                    .font(RTType.label(9))
                    .foregroundStyle(isManual ? theme.note : theme.muted)
                    .frame(width: 31, alignment: .leading)
            }
            .disabled(!isManual)
            .opacity(isManual ? 1 : 0.74)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isManual ? "Manual tempo" : "Host-synced tempo")
    }
}

private struct WrappingRow: Layout {
    var horizontalSpacing: CGFloat = 10
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let maximumWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var usedHeight: CGFloat = 0

        for size in sizes {
            let addedWidth = rowWidth == 0 ? size.width : horizontalSpacing + size.width
            if rowWidth > 0, rowWidth + addedWidth > maximumWidth {
                usedWidth = max(usedWidth, rowWidth)
                usedHeight += rowHeight + verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += addedWidth
                rowHeight = max(rowHeight, size.height)
            }
        }
        usedWidth = max(usedWidth, rowWidth)
        usedHeight += rowHeight
        return CGSize(width: proposal.width ?? usedWidth, height: usedHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + horizontalSpacing + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            } else if x > bounds.minX {
                x += horizontalSpacing
            }
            subview.place(
                at: CGPoint(x: x, y: y + (rowHeight > 0 ? max(0, (rowHeight - size.height) * 0.5) : 0)),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct RepeatizerPluginView: View {
    @StateObject private var model: RepeatizerPluginModel
    @State private var auxiliaryPanel: AuxiliaryPanel?
    private let inputTimer = Timer.publish(every: 1.0 / 15.0, on: .main, in: .common).autoconnect()

    init(audioUnit: RepeatizerAudioUnit) {
        _model = StateObject(wrappedValue: RepeatizerPluginModel(audioUnit: audioUnit))
    }

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            header(theme)
            Rectangle().fill(theme.line.opacity(0.7)).frame(height: 1)
            HStack(spacing: 0) {
                if model.configuration.performanceSurface == .drums {
                    padBoard(theme)
                    if model.settingsVisible, let note = model.selectedNote {
                        Rectangle().fill(theme.line.opacity(0.7)).frame(width: 1)
                        PadSettingsPanel(model: model, note: note, theme: theme)
                            .frame(minWidth: 390, idealWidth: 430, maxWidth: 470)
                    }
                } else {
                    InstrumentBoard(model: model, theme: theme)
                }
            }
        }
        .background(MetalBackdrop(theme: theme))
        .foregroundStyle(theme.text)
        .font(RTType.body(12))
        .preferredColorScheme(theme.isLight ? .light : .dark)
        .frame(minWidth: 760, minHeight: 480)
        .overlay { auxiliaryPanelOverlay(theme) }
        .onReceive(inputTimer) { _ in
            model.pollInput()
        }
    }

    private func header(_ theme: PluginTheme) -> some View {
        WrappingRow(horizontalSpacing: 14, verticalSpacing: 8) {
            Text("REPEATIZER")
                .font(RTType.display(22, .heavy))
                .tracking(0.8)
                .frame(width: 150, alignment: .leading)

            HStack(spacing: 4) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(CompactMetalButtonStyle(theme: theme))
                    .disabled(!model.canUndo)
                    .help("Undo")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .buttonStyle(CompactMetalButtonStyle(theme: theme))
                    .disabled(!model.canRedo)
                    .help("Redo")
            }

            Picker("Performance preset", selection: $model.presetID) {
                Text("CUSTOM").tag("custom")
                ForEach(RepeatizerPresets.all) { preset in
                    Text(preset.menuName).tag(preset.id)
                }
            }
            .labelsHidden()
            .frame(width: 220)
            .onChange(of: model.presetID) { _, id in
                if id != "custom" { model.applyPreset(id) }
            }

            Picker("Performance surface", selection: Binding(
                get: { model.configuration.performanceSurface },
                set: { model.setPerformanceSurface($0) }
            )) {
                ForEach(PerformanceSurface.allCases) { surface in
                    Text(surface.rawValue.uppercased()).tag(surface)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 160)
            ClockControls(model: model, theme: theme)

            Picker("Theme", selection: $model.theme) {
                ForEach(PluginTheme.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 82)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(LinearGradient(colors: theme.headerColors, startPoint: .top, endPoint: .bottom))
    }

    private func padBoard(_ theme: PluginTheme) -> some View {
        VStack(spacing: 0) {
            WrappingRow(horizontalSpacing: 10, verticalSpacing: 7) {
                    Picker("Settings mode", selection: Binding(
                        get: { model.configuration.settingsMode },
                        set: { model.setSettingsMode($0) }
                    )) {
                        ForEach(SettingsMode.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)

                    HStack(spacing: 6) {
                        Text("TIME")
                            .font(RTType.label(9))
                            .foregroundStyle(theme.muted)
                        Picker("Global time scale", selection: Binding(
                            get: { model.configuration.timeScale },
                            set: { model.setTimeScale($0) }
                        )) {
                            ForEach(GlobalTimeScale.allCases) { scale in
                                Text(scale.rawValue.uppercased()).tag(scale)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                    }
                    .help("HALF slows every repeat, pattern, and swing grid by 2×. DOUBLE runs them at 2× speed.")

                    if model.configuration.settingsMode == .individual {
                        markerLegend("star.fill", "MASTER", theme.master, theme)
                        markerLegend("hand.point.up.left.fill", "FOLLOW", theme.note, theme)
                        Button {
                            model.toggleAllFollowers()
                        } label: {
                            Label(model.allVisiblePadsFollowMaster ? "UNFOLLOW ALL" : "FOLLOW ALL", systemImage: model.allVisiblePadsFollowMaster ? "link.badge.minus" : "link.badge.plus")
                        }
                        .buttonStyle(CompactMetalButtonStyle(theme: theme, selected: model.allVisiblePadsFollowMaster))
                        .disabled(model.configuration.masterNote == nil)
                    }

                    HStack(spacing: 6) {
                        Text("GENRE")
                            .font(RTType.label(9))
                            .foregroundStyle(theme.muted)
                        Picker("Random genre", selection: $model.randomGenre) {
                            ForEach(DrumPatternStyle.allCases) { style in
                                Text(style.rawValue.uppercased()).tag(style)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 132)

                        Picker("Randomize mode", selection: $model.randomMode) {
                            ForEach(AllPadRandomMode.allCases) { mode in
                                Text(mode.rawValue.uppercased()).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 168)

                        Button {
                            model.performAllPatternRandomization()
                        } label: {
                            Label("ROLL", systemImage: "dice.fill")
                                .lineLimit(1)
                        }
                        .frame(width: 76)
                        .buttonStyle(CompactMetalButtonStyle(theme: theme, emphasized: true))
                    }
                    .help("Use the selected genre, one coherent random genre, or a different random genre for each pad")

                    Button {
                        model.resetAll()
                    } label: {
                        Label("RESET ALL", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(CompactMetalButtonStyle(theme: theme))
                    .help("Reset the complete plugin to its dark master-mode defaults while keeping every MIDI CC assignment")

                    Button {
                        model.toggleEditor()
                    } label: {
                        Label(model.settingsVisible ? "HIDE SETTINGS" : "SHOW SETTINGS", systemImage: "slider.vertical.3")
                    }
                    .buttonStyle(CompactMetalButtonStyle(theme: theme, emphasized: true, selected: model.settingsVisible))
                    .help("Show or hide settings")

                    Button {
                        toggleAuxiliaryPanel(.ccMappings)
                    } label: {
                        Label("MIDI CC", systemImage: "cable.connector.horizontal")
                    }
                    .buttonStyle(CompactMetalButtonStyle(theme: theme, emphasized: true, selected: auxiliaryPanel == .ccMappings))

                    Button {
                        if auxiliaryPanel == .addPad {
                            auxiliaryPanel = nil
                        } else {
                            model.beginPadLearn()
                            auxiliaryPanel = .addPad
                        }
                    } label: {
                        Label("ADD PAD", systemImage: "plus")
                    }
                    .buttonStyle(CompactMetalButtonStyle(theme: theme, emphasized: true, selected: auxiliaryPanel == .addPad))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.panel.opacity(0.48))

            GeometryReader { proxy in
                let fittingColumns = max(2, Int((proxy.size.width - 28) / 150))
                let columns = model.settingsVisible ? min(3, fittingColumns) : min(4, fittingColumns)
                ScrollView {
                    PadMatrix(model: model, theme: theme, columns: columns)
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                }
                .background(theme.board.opacity(0.82))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func markerLegend(_ icon: String, _ text: String, _ color: Color, _ theme: PluginTheme) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).foregroundStyle(theme.muted)
        }
        .font(RTType.label(9))
    }

    private func toggleAuxiliaryPanel(_ panel: AuxiliaryPanel) {
        auxiliaryPanel = auxiliaryPanel == panel ? nil : panel
    }

    @ViewBuilder
    private func auxiliaryPanelOverlay(_ theme: PluginTheme) -> some View {
        if let auxiliaryPanel {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.24)
                    .contentShape(Rectangle())
                    .onTapGesture { self.auxiliaryPanel = nil }

                Group {
                    switch auxiliaryPanel {
                    case .ccMappings:
                        LiveCCPopover(model: model, theme: theme)
                    case .addPad:
                        AddPadPopover(model: model, theme: theme) { self.auxiliaryPanel = nil }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button { self.auxiliaryPanel = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(CompactMetalButtonStyle(theme: theme))
                    .padding(8)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
                .padding(.top, 70)
                .padding(.trailing, 14)
            }
        }
    }
}

private struct InstrumentBoard: View {
    @ObservedObject var model: RepeatizerPluginModel
    let theme: PluginTheme

    private var settings: PadConfiguration { model.configuration.masterSettings }
    private var instrument: InstrumentPerformanceSettings { model.configuration.instrumentSettings }

    var body: some View {
        VStack(spacing: 0) {
            WrappingRow(horizontalSpacing: 12, verticalSpacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("INSTRUMENT")
                        .font(RTType.display(15, .heavy))
                }

                RepeatDivisionSlider(
                    label: "DIVISION",
                    value: Binding(
                        get: { settings.division },
                        set: { model.setInstrumentDivision($0) }
                    ),
                    theme: theme
                )
                .frame(width: 210)

                HStack(spacing: 6) {
                    Text("TIME")
                        .font(RTType.label(9))
                        .foregroundStyle(theme.muted)
                    Picker("Instrument time scale", selection: Binding(
                        get: { model.configuration.timeScale },
                        set: { model.setTimeScale($0) }
                    )) {
                        ForEach(GlobalTimeScale.allCases) { scale in
                            Text(scale.rawValue.uppercased()).tag(scale)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                HStack(spacing: 6) {
                    Text("SWING \(Int(settings.swingPercent.rounded()))%")
                        .font(RTType.label(9))
                        .foregroundStyle(theme.muted)
                    Slider(value: Binding(
                        get: { settings.swingPercent },
                        set: { model.setInstrumentSwing($0) }
                    ), in: 50...75, step: 1)
                    .frame(width: 115)
                }

                Toggle("CAPTURE SHORT TAPS", isOn: Binding(
                    get: { model.configuration.captureShortTaps },
                    set: { model.setCaptureShortTaps($0) }
                ))
                .toggleStyle(.switch)
                .font(RTType.label(9))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.panel.opacity(0.48))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    IncomingMIDIMonitor(
                        heldNotes: model.heldNotes,
                        liveNote: model.liveNote,
                        theme: theme
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("PLAY MODE")
                            .font(RTType.label(10))
                            .tracking(0.9)
                            .foregroundStyle(theme.muted)
                        Picker("Instrument play mode", selection: Binding(
                            get: { instrument.playbackMode },
                            set: { model.setInstrumentPlaybackMode($0) }
                        )) {
                            ForEach(InstrumentPlaybackMode.allCases) { mode in
                                Text(mode.rawValue.uppercased()).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    .padding(12)
                    .background(theme.panel.opacity(0.72))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                    if instrument.playbackMode == .chord {
                        chordPatternControls
                    } else {
                        arpeggiatorControls
                    }

                    instrumentHumanizeControls
                }
                .padding(18)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(theme.board.opacity(0.82))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chordPatternControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CHORD PATTERNS · \(InstrumentStyle.allCases.count) STYLES × 8")
                    .font(RTType.label(10))
                    .tracking(0.9)
                    .foregroundStyle(theme.muted)
                Spacer()
                Button { model.smartRandomizeInstrument() } label: {
                    Label("SMART PLAY", systemImage: "dice.fill")
                }
                .buttonStyle(CompactMetalButtonStyle(theme: theme, emphasized: true))
            }

            WrappingRow(horizontalSpacing: 12, verticalSpacing: 8) {
                HStack(spacing: 6) {
                    Text("STYLE").font(RTType.label(9)).foregroundStyle(theme.muted)
                    Picker("Chord pattern style", selection: Binding(
                        get: { instrument.style },
                        set: { model.setInstrumentStyle($0) }
                    )) {
                        ForEach(InstrumentStyle.allCases) { style in
                            Text(style.rawValue.uppercased()).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 188)
                }

                HStack(spacing: 5) {
                    Text("PATTERN").font(RTType.label(9)).foregroundStyle(theme.muted)
                    Button { model.setInstrumentPatternVariant((instrument.patternVariant + 7) % 8) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(CompactMetalButtonStyle(theme: theme))
                    Picker("Chord pattern", selection: Binding(
                        get: { instrument.patternVariant },
                        set: { model.setInstrumentPatternVariant($0) }
                    )) {
                        ForEach(0..<8, id: \.self) { variant in Text("P\(variant + 1)").tag(variant) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                    Button { model.setInstrumentPatternVariant((instrument.patternVariant + 1) % 8) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(CompactMetalButtonStyle(theme: theme))
                }
            }

            WrappingRow(horizontalSpacing: 14, verticalSpacing: 10) {
                Toggle("LIVE PATTERN", isOn: Binding(
                    get: { instrument.livePatternEnabled },
                    set: { model.setInstrumentLivePattern($0) }
                ))
                .font(RTType.label(10))
                .toggleStyle(.switch)

                if instrument.livePatternEnabled {
                    Picker("Live phrase length", selection: Binding(
                        get: { instrument.livePatternPhraseLength },
                        set: { model.setInstrumentLivePatternPhraseLength($0) }
                    )) {
                        Text("1 PHRASE").tag(1)
                        Text("2 PHRASES").tag(2)
                        Text("4 PHRASES").tag(4)
                        Text("8 PHRASES").tag(8)
                    }
                    .labelsHidden()
                    .frame(width: 132)
                }
            }

            instrumentSlider("VARIATION", value: Binding(
                get: { instrument.variation }, set: { model.setInstrumentVariation($0) }
            ), text: percent(instrument.variation))
            instrumentSlider("COMPLEXITY", value: Binding(
                get: { instrument.patternComplexity }, set: { model.setInstrumentPatternComplexity($0) }
            ), text: percent(instrument.patternComplexity))
            instrumentSlider("AUTO FILL", value: Binding(
                get: { instrument.patternAutoFill }, set: { model.setInstrumentPatternAutoFill($0) }
            ), text: percent(instrument.patternAutoFill))
            instrumentSlider("FLUCTUATION", value: Binding(
                get: { instrument.patternFluctuation }, set: { model.setInstrumentPatternFluctuation($0) }
            ), text: percent(instrument.patternFluctuation))
            instrumentSlider("HIT PROBABILITY", value: Binding(
                get: { instrument.patternProbability }, set: { model.setInstrumentPatternProbability($0) }
            ), text: percent(instrument.patternProbability))
        }
        .padding(12)
        .background(theme.panel.opacity(0.72))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var arpeggiatorControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ARPEGGIATOR")
                .font(RTType.label(10))
                .tracking(0.9)
                .foregroundStyle(theme.muted)

            WrappingRow(horizontalSpacing: 14, verticalSpacing: 8) {
                HStack(spacing: 6) {
                    Text("OCTAVE SPREAD").font(RTType.label(9)).foregroundStyle(theme.muted)
                    Picker("Arpeggiator octave spread", selection: Binding(
                        get: { instrument.octaveRange },
                        set: { model.setInstrumentOctaveRange($0) }
                    )) {
                        Text("−2").tag(-2)
                        Text("−1").tag(-1)
                        Text("0").tag(0)
                        Text("+1").tag(1)
                        Text("+2").tag(2)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }

                if instrument.playbackMode == .arpeggioRandom {
                    Button { model.randomizeArpeggiator() } label: {
                        Label("NEW ORDER", systemImage: "shuffle")
                    }
                    .buttonStyle(CompactMetalButtonStyle(theme: theme, emphasized: true))
                }
            }

            instrumentSlider("ARP GATE", value: Binding(
                get: { instrument.arpGate }, set: { model.setInstrumentArpGate($0) }
            ), text: percent(instrument.arpGate), range: 0.05...1)
        }
        .padding(12)
        .background(theme.panel.opacity(0.72))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var instrumentHumanizeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DYNAMICS & HUMANIZE")
                .font(RTType.label(10))
                .tracking(0.9)
                .foregroundStyle(theme.muted)

            Picker("Instrument velocity base", selection: Binding(
                get: { settings.velocityMode == .fixed ? VelocityMode.fixed : VelocityMode.received },
                set: { model.setInstrumentVelocityMode($0) }
            )) {
                Text("RECEIVED").tag(VelocityMode.received)
                Text("FIXED / LOCKED").tag(VelocityMode.fixed)
            }
            .pickerStyle(.segmented)

            if settings.velocityMode == .fixed {
                instrumentSlider("FIXED VELOCITY", value: Binding(
                    get: { Double(settings.fixedVelocity) },
                    set: { model.setInstrumentFixedVelocity(Int($0.rounded())) }
                ), text: "\(settings.fixedVelocity)", range: 1...127, step: 1)
            }

            Toggle("VELOCITY HUMANIZE", isOn: Binding(
                get: { settings.velocityHumanizeEnabled || settings.velocityMode == .humanized },
                set: { model.setInstrumentVelocityHumanize($0) }
            ))
            .font(RTType.label(10))
            .toggleStyle(.switch)

            if settings.velocityHumanizeEnabled || settings.velocityMode == .humanized {
                instrumentSlider("HUMANIZE RANGE", value: Binding(
                    get: { Double(settings.humanizeAmount) },
                    set: { model.setInstrumentHumanizeAmount(Int($0.rounded())) }
                ), text: "±\(settings.humanizeAmount)", range: 0...64, step: 1)
                instrumentSlider("HIT PROBABILITY", value: Binding(
                    get: { settings.humanizeProbability },
                    set: { model.setInstrumentHumanizeProbability($0) }
                ), text: percent(settings.humanizeProbability))
                instrumentSlider("BIAS", value: Binding(
                    get: { settings.humanizeBias },
                    set: { model.setInstrumentHumanizeBias($0) }
                ), text: humanizeBiasLabel(settings.humanizeBias), range: -1...1)
            }

            Rectangle().fill(theme.line.opacity(0.62)).frame(height: 1)
            Toggle("TIMING HUMANIZE", isOn: Binding(
                get: { model.configuration.timingHumanizeEnabled },
                set: { model.setTimingHumanize($0) }
            ))
            .font(RTType.label(10))
            .toggleStyle(.switch)

            if model.configuration.timingHumanizeEnabled {
                instrumentSlider("TIMING RANGE", value: Binding(
                    get: { model.configuration.timingHumanizeMilliseconds },
                    set: { model.setTimingHumanizeMilliseconds($0) }
                ), text: String(format: "±%.1f ms", model.configuration.timingHumanizeMilliseconds), range: 0...30, step: 0.5)
                instrumentSlider("TIMING PROBABILITY", value: Binding(
                    get: { model.configuration.timingHumanizeProbability },
                    set: { model.setTimingHumanizeProbability($0) }
                ), text: percent(model.configuration.timingHumanizeProbability))
                instrumentSlider("EARLY / LATE", value: Binding(
                    get: { model.configuration.timingHumanizeBias },
                    set: { model.setTimingHumanizeBias($0) }
                ), text: timingBiasLabel(model.configuration.timingHumanizeBias), range: -1...1)
            }
        }
        .padding(12)
        .background(theme.panel.opacity(0.72))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func instrumentSlider(
        _ label: String,
        value: Binding<Double>,
        text: String,
        range: ClosedRange<Double> = 0...1,
        step: Double = 0.01
    ) -> some View {
        HStack(spacing: 10) {
            Text(label).font(RTType.label(9)).foregroundStyle(theme.muted).frame(width: 122, alignment: .leading)
            Slider(value: value, in: range, step: step).tint(theme.note)
            Text(text).font(RTType.label(9)).foregroundStyle(theme.note).frame(width: 70, alignment: .trailing)
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func humanizeBiasLabel(_ bias: Double) -> String {
        if abs(bias) < 0.01 { return "CENTER" }
        return bias > 0 ? "+LOUD \(Int((bias * 100).rounded()))%" : "−SOFT \(Int((abs(bias) * 100).rounded()))%"
    }

    private func timingBiasLabel(_ bias: Double) -> String {
        if abs(bias) < 0.01 { return "CENTER" }
        return bias > 0 ? "LATE \(Int((bias * 100).rounded()))%" : "EARLY \(Int((abs(bias) * 100).rounded()))%"
    }
}

private struct IncomingMIDIMonitor: View {
    let heldNotes: Set<Int>
    let liveNote: Int?
    let theme: PluginTheme

    private var detectedNotes: [Int] {
        var notes = heldNotes
        if let liveNote { notes.insert(liveNote) }
        return notes.sorted()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("NOTES")
                .font(RTType.label(10))
                .tracking(0.9)
                .foregroundStyle(theme.muted)
            if detectedNotes.isEmpty {
                Text("—")
                    .font(RTType.display(14, .heavy))
                    .foregroundStyle(theme.muted)
            } else {
                WrappingRow(horizontalSpacing: 7, verticalSpacing: 7) {
                    ForEach(detectedNotes, id: \.self) { note in
                        Text(instrumentMIDINoteName(note))
                            .font(RTType.display(12, .heavy))
                            .foregroundStyle(heldNotes.contains(note) ? theme.live : theme.note)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(theme.raised)
                        .overlay(Capsule().stroke(theme.line, lineWidth: 1))
                        .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(12)
        .background(theme.panel.opacity(0.74))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private func instrumentMIDINoteName(_ note: Int) -> String {
    let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    return names[(note % 12 + 12) % 12] + "\(note / 12 - 1)"
}

private struct RepeatDivisionSlider: View {
    let label: String
    let value: Binding<RepeatDivision>
    let theme: PluginTheme

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(RTType.label(9))
                .foregroundStyle(theme.muted)
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue.rawValue) },
                    set: { rawValue in
                        value.wrappedValue = RepeatDivision(rawValue: Int(rawValue.rounded())) ?? .sixteenth
                    }
                ),
                in: 0...Double(RepeatDivision.allCases.count - 1),
                step: 1
            )
            .tint(theme.note)
            Text(value.wrappedValue.title)
                .font(RTType.display(12, .heavy))
                .foregroundStyle(theme.note)
                .frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value.wrappedValue.title)
    }
}

private struct PadMatrix: View {
    @ObservedObject var model: RepeatizerPluginModel
    let theme: PluginTheme
    let columns: Int

    var body: some View {
        VStack(spacing: 9) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 9) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, note in
                        if let note {
                            PadButton(model: model, note: note, theme: theme)
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 88)
                        }
                    }
                }
            }
        }
    }

    private var rows: [[Int?]] {
        let notes = model.configuration.visibleNotes.sorted()
        guard !notes.isEmpty else { return [Array(repeating: nil, count: columns)] }
        var lowToHigh: [[Int]] = []
        for start in stride(from: 0, to: notes.count, by: columns) {
            lowToHigh.append(Array(notes[start..<min(start + columns, notes.count)]))
        }
        return lowToHigh.reversed().map { chunk in
            let leadingBlanks = chunk.count < columns ? columns - chunk.count : 0
            return Array(repeating: Optional<Int>.none, count: leadingBlanks) + chunk.map(Optional.some)
        }
    }
}

private struct PadButton: View {
    @ObservedObject var model: RepeatizerPluginModel
    let note: Int
    let theme: PluginTheme

    var body: some View {
        let settings = model.configuration.effectivePad(note)
        let pattern = DrumPatternLibrary.pattern(settings.patternID)
        let selected = model.selectedNote == note
        let held = model.heldNotes.contains(note)
        let live = held || model.liveNote == note
        let master = model.configuration.masterNote == note
        let follower = model.configuration.followerNotes.contains(note)
        ZStack(alignment: .topTrailing) {
            Button { model.select(note) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 5) {
                        Text(String(format: "%03d", note))
                            .font(RTType.label(10))
                            .foregroundStyle(live ? theme.live : theme.muted)
                        if master {
                            Image(systemName: "star.fill").foregroundStyle(theme.master)
                        } else if follower {
                            Image(systemName: "hand.point.up.left.fill").foregroundStyle(theme.note)
                        }
                        Spacer()
                    }
                    Text(GMDrumMap.name(for: note).uppercased())
                        .font(RTType.display(11, .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                    Spacer(minLength: 2)
                    HStack {
                        Text(settings.playbackMode == .pattern ? pattern.style.rawValue.uppercased() : settings.division.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Spacer()
                        Text(settings.playbackMode == .pattern ? "P\(pattern.id + 1)" : "\(Int(settings.swingPercent.rounded()))%")
                    }
                    .font(RTType.label(11))
                    .foregroundStyle(live ? theme.live : (selected ? theme.note : theme.muted))
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: live ? [theme.live.opacity(0.34), theme.raised] : [theme.raised, theme.panel],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(live ? theme.live : (selected ? theme.note : (master ? theme.master.opacity(0.75) : theme.line)), lineWidth: live ? 2.2 : (selected ? 1.7 : 1))
                )
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .shadow(color: live ? theme.live.opacity(0.35) : .black.opacity(theme.isLight ? 0.08 : 0.25), radius: live ? 8 : 2, y: 2)
                .scaleEffect(held ? 0.975 : 1)
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                if settings.playbackMode == .pattern {
                    Button { model.togglePatternLock(note) } label: {
                        Image(systemName: settings.patternLocked ? "lock.fill" : "lock.open")
                    }
                    .help(settings.patternLocked ? "Unlock this pattern" : "Keep this pattern during Randomize All")
                }
                Button { model.randomizePattern(note) } label: { Image(systemName: "dice") }
                    .help("Smart random pattern for this drum role")
            }
            .font(RTType.label(9))
            .foregroundStyle(theme.note)
            .padding(7)
            .buttonStyle(.plain)
        }
        .accessibilityLabel("\(GMDrumMap.name(for: note)), MIDI note \(note)")
    }
}

private struct PadSettingsPanel: View {
    @ObservedObject var model: RepeatizerPluginModel
    let note: Int
    let theme: PluginTheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.configuration.settingsMode == .master ? "MASTER SETTINGS" : GMDrumMap.name(for: note).uppercased())
                        .font(RTType.display(17, .heavy))
                    Text(model.configuration.settingsMode == .master
                         ? "NON-DESTRUCTIVE OVERRIDE · ALL PADS"
                         : "MIDI \(note) · \(model.selectedIsFollower ? "FOLLOWER" : (model.selectedIsMaster ? "MASTER" : "INDEPENDENT"))")
                        .font(RTType.label(9))
                        .tracking(0.8)
                        .foregroundStyle(model.selectedIsMaster ? theme.master : theme.muted)
                }
                Spacer()
                Button { model.closeEditor() } label: { Image(systemName: "xmark") }
                    .buttonStyle(CompactMetalButtonStyle(theme: theme))
            }
            .padding(14)
            .background(theme.panel)

            if model.configuration.settingsMode == .individual { HStack(spacing: 8) {
                Button {
                    model.makeSelectedMaster()
                } label: {
                    Label(model.selectedIsMaster ? "CLEAR MASTER" : "MAKE MASTER", systemImage: "star.fill")
                }
                .buttonStyle(CompactMetalButtonStyle(theme: theme, tint: theme.master, selected: model.selectedIsMaster))

                Button {
                    model.toggleSelectedFollower()
                } label: {
                    Label(model.selectedIsFollower ? "UNFOLLOW" : "FOLLOW MASTER", systemImage: "hand.point.up.left.fill")
                }
                .buttonStyle(CompactMetalButtonStyle(theme: theme, emphasized: true, selected: model.selectedIsFollower))
                .disabled(model.configuration.masterNote == nil || model.selectedIsMaster)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .background(theme.panel)
            }

            if model.configuration.settingsMode == .individual, model.selectedIsFollower, let master = model.configuration.masterNote {
                HStack(spacing: 7) {
                    Image(systemName: "link")
                    Text("Following \(GMDrumMap.name(for: master)) exactly. Unfollow to edit this pad independently.")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.text)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.note.opacity(0.18))
            }

            Rectangle().fill(theme.line).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    timingSection
                    sectionDivider
                    velocitySection
                    sectionDivider
                    if model.configuration.settingsMode == .individual { Button(role: .destructive) {
                        model.removeSelectedPad()
                    } label: {
                        Label("REMOVE PAD FROM THIS VIEW", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .font(RTType.label(10))
                    .foregroundStyle(Color.red.opacity(0.88))
                    .padding(14)
                    }
                }
                .disabled(model.configuration.settingsMode == .individual && model.selectedIsFollower)
            }
        }
        .background(theme.panel.opacity(0.98))
    }

    private var timingSection: some View {
        settingsSection("TIMING", icon: "metronome") {
            Picker("Playback mode", selection: Binding(
                get: { model.selectedPad.playbackMode },
                set: { model.setPlaybackMode($0) }
            )) {
                ForEach(PadPlaybackMode.allCases) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .pickerStyle(.segmented)

            if model.selectedPad.playbackMode == .pattern {
                patternControls
            } else {
                RepeatDivisionSlider(
                    label: "REPEAT DIVISION",
                    value: Binding(
                        get: { model.selectedPad.division },
                        set: { value in model.updateSelected { $0.division = value } }
                    ),
                    theme: theme
                )
                Toggle("SMART REPEAT FILLS", isOn: Binding(
                    get: { model.selectedPad.repeatFillEnabled },
                    set: { enabled in model.updateSelected { $0.repeatFillEnabled = enabled } }
                ))
                .font(RTType.label(10))
                .toggleStyle(.switch)
                if model.selectedPad.repeatFillEnabled {
                    valueSlider("FILL LENGTH", value: Binding(
                        get: { model.selectedPad.repeatFillAmount },
                        set: { value in model.updateSelected { $0.repeatFillAmount = value } }
                    ), range: 0...1, valueText: percent(model.selectedPad.repeatFillAmount), step: 0.01)
                    valueSlider("FILL DENSITY", value: Binding(
                        get: { model.selectedPad.repeatFillDensity },
                        set: { value in model.updateSelected { $0.repeatFillDensity = value } }
                    ), range: 0...1, valueText: percent(model.selectedPad.repeatFillDensity), step: 0.01)
                    valueSlider("PHRASE CHANCE", value: Binding(
                        get: { model.selectedPad.repeatFillProbability },
                        set: { value in model.updateSelected { $0.repeatFillProbability = value } }
                    ), range: 0...1, valueText: percent(model.selectedPad.repeatFillProbability), step: 0.01)
                    settingRow("MAX SPEED") {
                        Picker("Maximum fill speed", selection: Binding(
                            get: { model.selectedPad.repeatFillSpeedSteps },
                            set: { value in model.updateSelected { $0.repeatFillSpeedSteps = value } }
                        )) {
                            Text("+1 DIVISION").tag(1)
                            Text("+2 DIVISIONS").tag(2)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    settingRow("FILL EVERY") {
                        Picker("Fill cadence", selection: Binding(
                            get: { model.selectedPad.repeatFillEveryBars },
                            set: { value in model.updateSelected { $0.repeatFillEveryBars = value } }
                        )) {
                            ForEach([1, 2, 4, 8], id: \.self) { bars in
                                Text(bars == 1 ? "BAR" : "\(bars) BARS").tag(bars)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                    valueSlider("KIT BALANCE", value: Binding(
                        get: { model.selectedPad.repeatFillBalance },
                        set: { value in model.updateSelected { $0.repeatFillBalance = value } }
                    ), range: 0...1, valueText: percent(model.selectedPad.repeatFillBalance), step: 0.01)
                    Text("Creates varied phrase-ending fills. KIT BALANCE favors musically useful drum roles so the entire kit does not accelerate together.")
                        .font(.caption2)
                        .foregroundStyle(theme.muted)
                }
            }
            settingRow("SWING GRID") {
                Picker("Swing grid", selection: Binding(
                    get: { model.selectedPad.swingDivision },
                    set: { value in model.updateSelected { $0.swingDivision = value } }
                )) {
                    ForEach(SwingDivision.allCases) { division in
                        Text(division.title).tag(division)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            Text(model.selectedPad.swingDivision == .automatic
                 ? (model.selectedPad.playbackMode == .pattern
                    ? "AUTO follows the selected pattern's step division."
                    : "AUTO follows the repeat division.")
                 : "Swing is applied only on this independent grid.")
                .font(.caption2)
                .foregroundStyle(theme.muted)
            VStack(spacing: 5) {
                HStack {
                    Text("SWING")
                    Spacer()
                    Text("\(model.selectedPad.swingPercent, format: .number.precision(.fractionLength(1)))%")
                        .foregroundStyle(theme.note)
                }
                .font(RTType.label(10))
                Slider(value: Binding(
                    get: { model.selectedPad.swingPercent },
                    set: { value in model.updateSelected { $0.swingPercent = value } }
                ), in: 50...75, step: 0.1)
                .tint(theme.note)
            }

            if model.configuration.settingsMode == .master {
                masterTapControls
            }
        }
    }

    private var patternControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingRow("DRUM ROLE") {
                Picker("Drum role", selection: Binding(
                    get: { model.selectedPatternRole },
                    set: { model.setSelectedPatternRole($0) }
                )) {
                    ForEach(DrumPatternRole.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            settingRow("STYLE") {
                Picker("Pattern style", selection: Binding(
                    get: { model.selectedPattern.style },
                    set: { model.setSelectedPatternStyle($0) }
                )) {
                    ForEach(DrumPatternStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Menu {
                ForEach(DrumPatternLibrary.patterns(
                    for: model.selectedPatternRole,
                    style: model.selectedPattern.style
                )) { pattern in
                    Button {
                        model.setSelectedPattern(pattern.id)
                    } label: {
                        if pattern.id == model.selectedPattern.id {
                            Label(pattern.name, systemImage: "checkmark")
                        } else {
                            Text(pattern.name)
                        }
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.selectedPattern.style.rawValue.uppercased())
                            .font(RTType.label(9))
                            .foregroundStyle(theme.note)
                        Text(model.selectedPattern.name)
                            .font(RTType.body(11, .semibold))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }
                .padding(8)
                .background(theme.raised.opacity(0.8))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton)

            PatternPreview(pattern: model.selectedPattern, theme: theme)

            HStack(spacing: 8) {
                Button { model.randomizePattern(note) } label: {
                    Label("SMART RANDOM", systemImage: "dice.fill")
                }
                .buttonStyle(CompactMetalButtonStyle(theme: theme, emphasized: true))
                Button { model.togglePatternLock(note) } label: {
                    Label(model.selectedPad.patternLocked ? "LOCKED" : "LOCK", systemImage: model.selectedPad.patternLocked ? "lock.fill" : "lock.open")
                }
                .buttonStyle(CompactMetalButtonStyle(theme: theme, selected: model.selectedPad.patternLocked))
            }

            valueSlider("COMPLEXITY", value: Binding(
                get: { model.selectedPad.patternComplexity },
                set: { value in model.updateSelected { $0.patternComplexity = value } }
            ), range: 0...1, valueText: percent(model.selectedPad.patternComplexity), step: 0.01)
            valueSlider("VARIATION", value: Binding(
                get: { model.selectedPad.patternVariation },
                set: { value in model.updateSelected { $0.patternVariation = value } }
            ), range: 0...1, valueText: percent(model.selectedPad.patternVariation), step: 0.01)
            valueSlider("AUTO FILL", value: Binding(
                get: { model.selectedPad.patternAutoFill },
                set: { value in model.updateSelected { $0.patternAutoFill = value } }
            ), range: 0...1, valueText: percent(model.selectedPad.patternAutoFill), step: 0.01)
            valueSlider("FLUCTUATION", value: Binding(
                get: { model.selectedPad.patternFluctuation },
                set: { value in model.updateSelected { $0.patternFluctuation = value } }
            ), range: 0...1, valueText: percent(model.selectedPad.patternFluctuation), step: 0.01)
            valueSlider("HIT PROBABILITY", value: Binding(
                get: { model.selectedPad.patternProbability },
                set: { value in model.updateSelected { $0.patternProbability = value } }
            ), range: 0...1, valueText: percent(model.selectedPad.patternProbability), step: 0.01)

            Text("Release stops this lane. Press again and it rejoins the pattern at the current project position.")
                .font(.caption2)
                .foregroundStyle(theme.muted)
        }
    }

    private var velocitySection: some View {
        settingsSection("DYNAMICS & HUMANIZE", icon: "waveform.path") {
            Picker("Velocity base", selection: Binding(
                get: { model.selectedPad.velocityMode == .fixed ? VelocityMode.fixed : VelocityMode.received },
                set: { value in model.updateSelected { $0.velocityMode = value } }
            )) {
                Text("RECEIVED").tag(VelocityMode.received)
                Text("FIXED / LOCKED").tag(VelocityMode.fixed)
            }
            .pickerStyle(.segmented)
            if model.selectedPad.velocityMode == .fixed {
                valueSlider("FIXED", value: Binding(
                    get: { Double(model.selectedPad.fixedVelocity) },
                    set: { value in model.updateSelected { $0.fixedVelocity = Int(value.rounded()) } }
                ), range: 1...127, valueText: "\(model.selectedPad.fixedVelocity)")
            }

            Toggle("HUMANIZE", isOn: Binding(
                get: { model.selectedPad.velocityHumanizeEnabled || model.selectedPad.velocityMode == .humanized },
                set: { enabled in
                    model.updateSelected {
                        if $0.velocityMode == .humanized { $0.velocityMode = .received }
                        $0.velocityHumanizeEnabled = enabled
                    }
                }
            ))
            .font(RTType.label(10))
            .toggleStyle(.switch)

            if model.selectedPad.velocityHumanizeEnabled || model.selectedPad.velocityMode == .humanized {
                valueSlider("HUMANIZE RANGE", value: Binding(
                    get: { Double(model.selectedPad.humanizeAmount) },
                    set: { value in model.updateSelected { $0.humanizeAmount = Int(value.rounded()) } }
                ), range: 0...64, valueText: "±\(model.selectedPad.humanizeAmount)")
                valueSlider("HIT PROBABILITY", value: Binding(
                    get: { model.selectedPad.humanizeProbability },
                    set: { value in model.updateSelected { $0.humanizeProbability = value } }
                ), range: 0...1, valueText: "\(Int((model.selectedPad.humanizeProbability * 100).rounded()))%", step: 0.01)
                valueSlider("BIAS", value: Binding(
                    get: { model.selectedPad.humanizeBias },
                    set: { value in model.updateSelected { $0.humanizeBias = value } }
                ), range: -1...1, valueText: humanizeBiasLabel(model.selectedPad.humanizeBias), step: 0.01)
            }

            if model.configuration.settingsMode == .master {
                Rectangle().fill(theme.line.opacity(0.62)).frame(height: 1)
                Toggle("TIMING HUMANIZE", isOn: Binding(
                    get: { model.configuration.timingHumanizeEnabled },
                    set: { model.setTimingHumanize($0) }
                ))
                .font(RTType.label(10))
                .toggleStyle(.switch)

                if model.configuration.timingHumanizeEnabled {
                    valueSlider("TIMING RANGE", value: Binding(
                        get: { model.configuration.timingHumanizeMilliseconds },
                        set: { model.setTimingHumanizeMilliseconds($0) }
                    ), range: 0...30, valueText: String(format: "±%.1f ms", model.configuration.timingHumanizeMilliseconds), step: 0.5)
                    valueSlider("HIT PROBABILITY", value: Binding(
                        get: { model.configuration.timingHumanizeProbability },
                        set: { model.setTimingHumanizeProbability($0) }
                    ), range: 0...1, valueText: percent(model.configuration.timingHumanizeProbability), step: 0.01)
                    valueSlider("EARLY / LATE BIAS", value: Binding(
                        get: { model.configuration.timingHumanizeBias },
                        set: { model.setTimingHumanizeBias($0) }
                    ), range: -1...1, valueText: timingBiasLabel(model.configuration.timingHumanizeBias), step: 0.01)
                    Text("Timing changes generated repeat and pattern notes only, with range limited to keep notes inside their grid neighborhood.")
                        .font(.caption2)
                        .foregroundStyle(theme.muted)
                }
            }
        }
    }

    private var masterTapControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(theme.line.opacity(0.62)).frame(height: 1)
            Toggle("CAPTURE TAPS", isOn: Binding(
                get: { model.configuration.captureShortTaps },
                set: { model.setCaptureShortTaps($0) }
            ))
            .font(RTType.label(10))
            .toggleStyle(.switch)

            Toggle("TAP LIVE", isOn: Binding(
                get: { model.configuration.tapLive },
                set: { model.setTapLive($0) }
            ))
            .font(RTType.label(10))
            .toggleStyle(.switch)

            if model.configuration.tapLive {
                settingRow("LIVE HIT GRID") {
                    Picker("Live-hit grid", selection: Binding(
                        get: { model.configuration.tapLiveQuantizeMode },
                        set: { model.setTapLiveQuantizeMode($0) }
                    )) {
                        ForEach(LiveTapQuantizeMode.allCases) { mode in
                            Text(mode.rawValue.uppercased()).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                if model.configuration.tapLiveQuantizeMode.usesStraightGrid {
                    settingRow("EVEN GRID") {
                        Picker("Straight live-hit division", selection: Binding(
                            get: { model.configuration.tapLiveStraightDivision },
                            set: { model.setTapLiveStraightDivision($0) }
                        )) {
                            ForEach(RepeatDivision.straightCases) { division in
                                Text(division.title).tag(division)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }
                if model.configuration.tapLiveQuantizeMode.usesTripletGrid {
                    settingRow("ODD GRID") {
                        Picker("Triplet live-hit division", selection: Binding(
                            get: { model.configuration.tapLiveTripletDivision },
                            set: { model.setTapLiveTripletDivision($0) }
                        )) {
                            ForEach(RepeatDivision.tripletCases) { division in
                                Text(division.title).tag(division)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }
                settingRow("REPEAT WAIT") {
                    Picker("Tap Live pause", selection: Binding(
                        get: { model.configuration.tapLiveBuffer },
                        set: { model.setTapLiveBuffer($0) }
                    )) {
                        ForEach(RepeatDivision.allCases) { division in
                            Text(division.title).tag(division)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                Text("The live hit uses its own FREE, EVEN, ODD, or BOTH grid. REPEAT WAIT separately decides when the held repeat or pattern resumes.")
                    .font(.caption2)
                    .foregroundStyle(theme.muted)
            }
        }
    }

    private var sectionDivider: some View { Rectangle().fill(theme.line.opacity(0.62)).frame(height: 1) }

    private func settingsSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(RTType.label(10, .heavy))
                .tracking(0.8)
                .foregroundStyle(theme.note)
            content()
        }
        .padding(14)
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(RTType.label(10)).foregroundStyle(theme.muted)
            Spacer()
            content()
        }
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, valueText: String, step: Double = 1) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).foregroundStyle(theme.note)
            }
            .font(RTType.label(10))
            Slider(value: value, in: range, step: step).tint(theme.note)
        }
    }

    private func humanizeBiasLabel(_ bias: Double) -> String {
        if abs(bias) < 0.01 { return "CENTER" }
        return bias > 0 ? "+LOUD \(Int((bias * 100).rounded()))%" : "−SOFT \(Int((abs(bias) * 100).rounded()))%"
    }

    private func timingBiasLabel(_ bias: Double) -> String {
        if abs(bias) < 0.01 { return "CENTER" }
        return bias > 0 ? "+LATE \(Int((bias * 100).rounded()))%" : "−EARLY \(Int((abs(bias) * 100).rounded()))%"
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

private struct PatternPreview: View {
    let pattern: DrumPatternDefinition
    let theme: PluginTheme

    var body: some View {
        let rows = max(1, Int(ceil(Double(pattern.lengthSteps) / 16.0)))
        Canvas { context, size in
            let gap: CGFloat = 2
            let cellWidth = (size.width - gap * 15) / 16
            let cellHeight = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            for step in 0..<pattern.lengthSteps {
                let column = step % 16
                let row = step / 16
                let rect = CGRect(
                    x: CGFloat(column) * (cellWidth + gap),
                    y: CGFloat(row) * (cellHeight + gap),
                    width: cellWidth,
                    height: cellHeight
                )
                let bit = UInt64(1) << UInt64(step)
                let fill: Color
                if pattern.coreMask & bit != 0 { fill = theme.note }
                else if pattern.detailMask & bit != 0 { fill = theme.note.opacity(0.48) }
                else { fill = theme.raised.opacity(column.isMultiple(of: 4) ? 0.9 : 0.48) }
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(fill))
                if pattern.fillMask & bit != 0 {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 0.8, dy: 0.8), cornerRadius: 1), with: .color(theme.master), lineWidth: 1)
                }
            }
        }
        .frame(height: CGFloat(rows) * 10 + CGFloat(rows - 1) * 2)
        .padding(7)
        .background(theme.board.opacity(0.78))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.line.opacity(0.7)))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("Pattern preview with \(pattern.lengthSteps) steps")
    }
}

private struct LiveCCPopover: View {
    @ObservedObject var model: RepeatizerPluginModel
    let theme: PluginTheme

    private let divisionActions: [MomentaryCCAction] = [
        .straightUp1, .straightDown1, .tripletUp1, .tripletDown1
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MIDI CC")
                .font(RTType.display(13, .heavy))
            Text("Continuous mappings use the full 0–127 CC range. Division ± controls are momentary: any nonzero value holds the shift and CC 0 releases it.")
                .font(.caption)
                .foregroundStyle(theme.muted)

            let swing = model.configuration.liveCC.mapping(.swing)
            HStack(spacing: 10) {
                Toggle("SWING SLIDER", isOn: swingEnabled)
                    .font(RTType.label(9))
                Spacer()
                ccInput(swingCC)
            }
            .padding(9)
            .background(theme.board)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(swing.enabled ? theme.note.opacity(0.65) : theme.line))

            let divisionSlider = model.configuration.liveCC.mapping(.divisionDepth)
            HStack(spacing: 10) {
                Toggle("REPEAT DIVISION SLIDER", isOn: mappingEnabled(.divisionDepth))
                    .font(RTType.label(9))
                Spacer()
                ccInput(mappingCC(.divisionDepth))
            }
            .padding(9)
            .background(theme.board)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(divisionSlider.enabled ? theme.note.opacity(0.65) : theme.line))

            let velocitySlider = model.configuration.liveCC.mapping(.velocity)
            HStack(spacing: 10) {
                Toggle("FIXED VELOCITY SLIDER", isOn: mappingEnabled(.velocity))
                    .font(RTType.label(9))
                Spacer()
                ccInput(mappingCC(.velocity))
            }
            .padding(9)
            .background(theme.board)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(velocitySlider.enabled ? theme.note.opacity(0.65) : theme.line))

            Text("The division slider scrolls from the slowest to fastest repeat division. The velocity slider locks generated notes from 1 to 127; velocity humanize still applies afterward.")
                .font(.caption2)
                .foregroundStyle(theme.muted)

            Text("MOMENTARY DIVISION ±1")
                .font(RTType.label(9, .heavy))
                .foregroundStyle(theme.note)

            ForEach(divisionActions, id: \.self) { action in
                let mapping = model.configuration.liveCC.momentaryMapping(action)
                HStack(spacing: 10) {
                    Toggle(divisionLabel(action), isOn: enabled(action))
                        .font(RTType.label(9))
                    Spacer()
                    ccInput(cc(action))
                }
                .padding(9)
                .background(theme.board)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(mapping.enabled ? theme.note.opacity(0.65) : theme.line))
            }

            Text("EVEN selects the next faster or slower straight division. ODD selects the next faster or slower triplet division—even when the pad starts on the other family.")
                .font(.caption2)
                .foregroundStyle(theme.muted)
        }
        .padding(16)
        .frame(width: 410)
        .background(theme.panel)
        .foregroundStyle(theme.text)
    }

    private var swingEnabled: Binding<Bool> { Binding(
        get: { model.configuration.liveCC.mapping(.swing).enabled },
        set: { value in model.updateLiveCC("swing-enabled") { $0.updateMapping(.swing) { $0.enabled = value } } }
    ) }

    private var swingCC: Binding<Int> { Binding(
        get: { model.configuration.liveCC.mapping(.swing).ccNumber },
        set: { value in model.updateLiveCC("swing-cc") { $0.updateMapping(.swing) { $0.ccNumber = min(max(value, 0), 127) } } }
    ) }

    private func mappingEnabled(_ destination: CCDestination) -> Binding<Bool> { Binding(
        get: { model.configuration.liveCC.mapping(destination).enabled },
        set: { value in model.updateLiveCC("\(destination.rawValue)-enabled") { $0.updateMapping(destination) { $0.enabled = value } } }
    ) }

    private func mappingCC(_ destination: CCDestination) -> Binding<Int> { Binding(
        get: { model.configuration.liveCC.mapping(destination).ccNumber },
        set: { value in model.updateLiveCC("\(destination.rawValue)-cc") { $0.updateMapping(destination) { $0.ccNumber = min(max(value, 0), 127) } } }
    ) }

    private func enabled(_ action: MomentaryCCAction) -> Binding<Bool> { Binding(
        get: { model.configuration.liveCC.momentaryMapping(action).enabled },
        set: { value in model.updateLiveCC(action.rawValue) { $0.updateMomentaryMapping(action) { $0.enabled = value } } }
    ) }

    private func cc(_ action: MomentaryCCAction) -> Binding<Int> { Binding(
        get: { model.configuration.liveCC.momentaryMapping(action).ccNumber },
        set: { value in model.updateLiveCC(action.rawValue) { $0.updateMomentaryMapping(action) { $0.ccNumber = min(max(value, 0), 127) } } }
    ) }

    private func divisionLabel(_ action: MomentaryCCAction) -> String {
        switch action {
        case .straightUp1: "EVEN DIVISION +1"
        case .straightDown1: "EVEN DIVISION −1"
        case .tripletUp1: "ODD / TRIPLET +1"
        case .tripletDown1: "ODD / TRIPLET −1"
        default: action.rawValue.uppercased()
        }
    }

    private func ccInput(_ value: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Text("CC").font(RTType.label(8)).foregroundStyle(theme.muted)
            TextField("0–127", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            Stepper("CC", value: value, in: 0...127)
                .labelsHidden()
        }
        .frame(width: 102)
    }
}

private struct AddPadPopover: View {
    @ObservedObject var model: RepeatizerPluginModel
    let theme: PluginTheme
    let dismiss: () -> Void
    @State private var note = 52
    @State private var learned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ADD PAD")
                .font(RTType.display(13, .heavy))
            Text("Strike a MIDI pad or key, then add the captured note.")
                .font(.caption)
                .foregroundStyle(theme.muted)
            HStack(spacing: 8) {
                Image(systemName: learned ? "checkmark.circle.fill" : "waveform.badge.mic")
                    .foregroundStyle(learned ? theme.note : theme.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(learned ? "MIDI NOTE \(note) CAPTURED" : "WAITING FOR MIDI…")
                        .font(RTType.label(10))
                    if learned { Text(GMDrumMap.name(for: note)).font(.caption).foregroundStyle(theme.muted) }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.board)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(learned ? theme.note : theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            Stepper(value: $note, in: 0...127) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MANUAL FALLBACK").font(.caption2.weight(.bold)).foregroundStyle(theme.muted)
                    Text("\(GMDrumMap.name(for: note)) · MIDI \(note)").font(.caption.monospacedDigit())
                }
            }
            Button("ADD & EDIT") {
                model.addPad(note)
                dismiss()
            }
            .buttonStyle(CompactMetalButtonStyle(theme: theme, emphasized: true))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(width: 300)
        .background(theme.panel)
        .foregroundStyle(theme.text)
        .onReceive(model.$capturedInputNote.compactMap { $0 }) { captured in
            note = captured
            learned = true
        }
    }
}

private struct MetalBackdrop: View {
    let theme: PluginTheme
    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.windowTop, theme.windowBottom], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                for y in stride(from: 0.0, through: size.height, by: 5.0) {
                    let path = Path(CGRect(x: 0, y: y, width: size.width, height: 0.5))
                    context.fill(path, with: .color(Color.white.opacity(theme.isLight ? 0.025 : 0.012)))
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private struct CompactMetalButtonStyle: ButtonStyle {
    let theme: PluginTheme
    var emphasized = false
    var tint: Color? = nil
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RTType.label(9))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .foregroundStyle(selected ? (theme.isLight ? Color.black : Color.white) : theme.text)
            .background(
                LinearGradient(
                    colors: selected || emphasized
                        ? [(tint ?? theme.note).opacity(configuration.isPressed ? 0.38 : 0.27), theme.raised]
                        : [theme.raised, theme.panel],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? (tint ?? theme.note) : theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}
