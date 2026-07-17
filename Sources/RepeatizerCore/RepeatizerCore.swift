import Foundation

public enum TempoMode: String, CaseIterable, Codable, Sendable {
    case hostSync = "Sync"
    case manual = "Manual"
}

public enum GlobalTimeScale: String, CaseIterable, Codable, Sendable, Identifiable {
    case half = "Half"
    case normal = "Normal"
    case double = "Double"

    public var id: String { rawValue }

    /// Multiplies musical intervals while the host/manual tempo remains unchanged.
    public var intervalMultiplier: Double {
        switch self {
        case .half: 2
        case .normal: 1
        case .double: 0.5
        }
    }
}

public enum LiveTapQuantizeMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case free = "Free"
    case straight = "Straight"
    case triplet = "Triplet"
    case both = "Both"

    public var id: String { rawValue }
    public var usesStraightGrid: Bool { self == .straight || self == .both }
    public var usesTripletGrid: Bool { self == .triplet || self == .both }
}

public enum RepeatDivision: Int, CaseIterable, Codable, Sendable, Identifiable {
    case half = 0
    case quarter
    case quarterTriplet
    case eighth
    case eighthTriplet
    case sixteenth
    case sixteenthTriplet
    case thirtySecond
    case thirtySecondTriplet
    case sixtyFourth

    public var id: Int { rawValue }

    /// Quarter-note units. A value of 1 is one quarter note / one beat in 4/4.
    public var beats: Double {
        switch self {
        case .half: 2
        case .quarter: 1
        case .quarterTriplet: 2.0 / 3.0
        case .eighth: 0.5
        case .eighthTriplet: 1.0 / 3.0
        case .sixteenth: 0.25
        case .sixteenthTriplet: 1.0 / 6.0
        case .thirtySecond: 0.125
        case .thirtySecondTriplet: 1.0 / 12.0
        case .sixtyFourth: 0.0625
        }
    }

    public var title: String {
        switch self {
        case .half: "1/2"
        case .quarter: "1/4"
        case .quarterTriplet: "1/4T"
        case .eighth: "1/8"
        case .eighthTriplet: "1/8T"
        case .sixteenth: "1/16"
        case .sixteenthTriplet: "1/16T"
        case .thirtySecond: "1/32"
        case .thirtySecondTriplet: "1/32T"
        case .sixtyFourth: "1/64"
        }
    }

    public var isTriplet: Bool {
        switch self {
        case .quarterTriplet, .eighthTriplet, .sixteenthTriplet, .thirtySecondTriplet: true
        default: false
        }
    }

    public static let straightCases: [RepeatDivision] = [.half, .quarter, .eighth, .sixteenth, .thirtySecond, .sixtyFourth]
    public static let tripletCases: [RepeatDivision] = [.quarterTriplet, .eighthTriplet, .sixteenthTriplet, .thirtySecondTriplet]

    public func moved(by steps: Int, path: DivisionModulationPath = .allDivisions) -> RepeatDivision {
        if path == .sameFeel {
            let triplets: [RepeatDivision] = [.quarterTriplet, .eighthTriplet, .sixteenthTriplet, .thirtySecondTriplet]
            let straight: [RepeatDivision] = [.half, .quarter, .eighth, .sixteenth, .thirtySecond, .sixtyFourth]
            let family = triplets.contains(self) ? triplets : straight
            guard let index = family.firstIndex(of: self) else { return self }
            return family[min(max(index + steps, 0), family.count - 1)]
        }
        let position = min(max(rawValue + steps, 0), Self.allCases.count - 1)
        return Self(rawValue: position) ?? self
    }

    /// Moves one musical size in a requested rhythmic family. When the current
    /// division belongs to the other family, this first selects the nearest
    /// faster/slower member so hardware "odd" controls also work from a normal
    /// straight starting division (and vice versa).
    public func moved(toTripletFamily triplet: Bool, direction: Int) -> RepeatDivision {
        guard direction != 0 else { return self }
        let family = triplet ? Self.tripletCases : Self.straightCases
        if let position = family.firstIndex(of: self) {
            return family[min(max(position + (direction > 0 ? 1 : -1), 0), family.count - 1)]
        }
        if direction > 0 {
            return family.reversed().last(where: { $0.beats < beats - 0.0000001 })
                ?? family.last!
        }
        return family.last(where: { $0.beats > beats + 0.0000001 })
            ?? family.first!
    }
}

public enum SwingDivision: Int, CaseIterable, Codable, Sendable, Identifiable {
    case automatic = -1
    case half = 0
    case quarter
    case quarterTriplet
    case eighth
    case eighthTriplet
    case sixteenth
    case sixteenthTriplet
    case thirtySecond
    case thirtySecondTriplet
    case sixtyFourth

    public var id: Int { rawValue }
    public var title: String { self == .automatic ? "AUTO" : (repeatDivision?.title ?? "AUTO") }
    public var repeatDivision: RepeatDivision? { RepeatDivision(rawValue: rawValue) }
    public func resolved(automaticDivision: RepeatDivision) -> RepeatDivision {
        repeatDivision ?? automaticDivision
    }
}

public enum DivisionModulationPath: String, CaseIterable, Codable, Sendable {
    case sameFeel = "Same Feel"
    case allDivisions = "All Divisions"
}

public enum SettingsMode: String, CaseIterable, Codable, Sendable {
    case master = "Master"
    case individual = "Individual"
}

public enum DrumGestureKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case flam = "Flam"
    case diddle = "Diddle"
    case crescendo = "Crescendo"
    case decrescendo = "Decrescendo"
    case roll = "Roll"
    case buzz = "Buzz"
    case drag = "Drag"
    case fillBurst = "Fill Burst"

    public var id: String { rawValue }
}

public struct DrumGestureMapping: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var ccNumber: Int

    public init(enabled: Bool = false, ccNumber: Int = 20) {
        self.enabled = enabled
        self.ccNumber = min(max(ccNumber, 0), 127)
    }
}

public struct DrumGestureConfiguration: Hashable, Codable, Sendable {
    public var rate: RepeatDivision
    public var lengthSteps: Int
    public var intensity: Double
    public var mappings: [DrumGestureKind: DrumGestureMapping]

    public init(rate: RepeatDivision = .sixteenth, lengthSteps: Int = 8, intensity: Double = 1, mappings: [DrumGestureKind: DrumGestureMapping] = [:]) {
        self.rate = rate
        self.lengthSteps = min(max(lengthSteps, 1), 32)
        self.intensity = min(max(intensity, 0), 1)
        self.mappings = mappings
    }

    public func mapping(_ kind: DrumGestureKind) -> DrumGestureMapping {
        mappings[kind] ?? DrumGestureMapping(ccNumber: 20 + (DrumGestureKind.allCases.firstIndex(of: kind) ?? 0))
    }

    public mutating func updateMapping(_ kind: DrumGestureKind, _ change: (inout DrumGestureMapping) -> Void) {
        var mapping = mapping(kind)
        change(&mapping)
        mappings[kind] = mapping
    }
}

public enum VelocityMode: String, CaseIterable, Codable, Sendable {
    case received = "Received"
    case fixed = "Fixed"
    case humanized = "Humanized"
}

public enum ModulationMode: String, CaseIterable, Codable, Sendable {
    case off = "Off"
    case lfo = "LFO"
    case random = "Random"
    case probability = "Probability"
}

public enum ModulationDirection: String, CaseIterable, Codable, Sendable {
    case down = "Down"
    case up = "Up"
    case both = "Both"
}

public enum ModulationClock: String, CaseIterable, Codable, Sendable {
    case sync = "Sync"
    case free = "Free"
}

public enum LFOShape: String, CaseIterable, Codable, Sendable {
    case sine = "Sine"
    case triangle = "Triangle"
    case sawUp = "Saw Up"
    case sawDown = "Saw Down"
    case square = "Square"
    case gate = "On / Off"
    case custom = "Draw"
}

/// One independent modulation lane. Each pad owns a lane for division, swing,
/// and velocity, so no pad's movement affects another pad.
public struct Modulator: Hashable, Codable, Sendable {
    public var mode: ModulationMode
    /// Sync: cycles per project beat. Free: cycles per second (Hz).
    public var rate: Double
    public var depth: Double
    public var direction: ModulationDirection
    public var clock: ModulationClock
    public var shape: LFOShape
    /// Moves the peak/valley or pulse split without changing the cycle length.
    public var symmetry: Double
    /// -1 is rounded/soft, +1 is pinched/sharp.
    public var curve: Double
    public var phase: Double
    /// -1 favors dips, +1 favors peaks. End points are absolute.
    public var probabilityBias: Double
    /// One cycle of a user-drawn waveform, normalized to -1...1.
    public var customPoints: [Double]

    public init(
        mode: ModulationMode = .off,
        rate: Double = 0.5,
        depth: Double = 1,
        direction: ModulationDirection = .both,
        clock: ModulationClock = .sync,
        shape: LFOShape = .sine,
        symmetry: Double = 0.5,
        curve: Double = 0,
        phase: Double = 0,
        probabilityBias: Double = 0,
        customPoints: [Double] = Modulator.defaultCustomPoints
    ) {
        self.mode = mode
        self.rate = rate
        self.depth = depth
        self.direction = direction
        self.clock = clock
        self.shape = shape
        self.symmetry = symmetry
        self.curve = curve
        self.phase = phase
        self.probabilityBias = probabilityBias
        self.customPoints = Self.normalizedCustomPoints(customPoints)
    }

    private enum CodingKeys: String, CodingKey {
        case mode, rate, depth, direction, clock, shape, symmetry, curve, phase
        case probabilityBias, customPoints
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(ModulationMode.self, forKey: .mode) ?? .off
        rate = try values.decodeIfPresent(Double.self, forKey: .rate) ?? 0.5
        depth = try values.decodeIfPresent(Double.self, forKey: .depth) ?? 1
        direction = try values.decodeIfPresent(ModulationDirection.self, forKey: .direction) ?? .both
        clock = try values.decodeIfPresent(ModulationClock.self, forKey: .clock) ?? .sync
        shape = try values.decodeIfPresent(LFOShape.self, forKey: .shape) ?? .sine
        symmetry = try values.decodeIfPresent(Double.self, forKey: .symmetry) ?? 0.5
        curve = try values.decodeIfPresent(Double.self, forKey: .curve) ?? 0
        phase = try values.decodeIfPresent(Double.self, forKey: .phase) ?? 0
        probabilityBias = try values.decodeIfPresent(Double.self, forKey: .probabilityBias) ?? 0
        customPoints = Self.normalizedCustomPoints(try values.decodeIfPresent([Double].self, forKey: .customPoints) ?? Self.defaultCustomPoints)
    }

    /// Deterministic modulation suitable for both the preview and MIDI render
    /// engines. Synced lanes use project beats; free lanes use elapsed seconds.
    public func value(at beat: Double, bpm: Double = 120, eventIndex: Int, seed: Int) -> Double {
        guard mode != .off, depth > 0 else { return 0 }
        let safeRate = min(max(rate, 0.01), 20)
        let cycle = clock == .sync ? beat * safeRate : beat * 60 / max(bpm, 1) * safeRate
        let position = playheadPosition(forCycle: cycle, seed: seed)
        let raw: Double
        switch mode {
        case .off:
            raw = 0
        case .lfo:
            raw = waveform(at: position)
        case .random:
            let step = Int(floor(cycle + phase))
            let blend = position * position * (3 - 2 * position)
            let first = random(seed: seed, step: step)
            raw = first + (random(seed: seed, step: step + 1) - first) * blend
        case .probability:
            raw = waveform(at: position)
        }

        let directed: Double
        switch direction {
        case .down: directed = -abs(raw)
        case .up: directed = abs(raw)
        case .both: directed = raw
        }
        return directed * depth
    }

    public func cycle(at beat: Double, bpm: Double = 120) -> Double {
        let safeRate = min(max(rate, 0.01), 20)
        return (clock == .sync ? beat : beat * 60 / max(bpm, 1)) * safeRate + phase
    }

    public func playheadPosition(at beat: Double, bpm: Double = 120, seed: Int) -> Double {
        playheadPosition(forCycle: cycle(at: beat, bpm: bpm) - phase, seed: seed)
    }

    public func displayWaveValue(at position: Double) -> Double {
        let raw = waveform(at: normalized(position))
        switch direction {
        case .down: return -abs(raw)
        case .up: return abs(raw)
        case .both: return raw
        }
    }

    public func displayValue(atCycle cycle: Double, seed: Int) -> Double {
        let position = normalized(cycle)
        let raw: Double
        if mode == .random {
            let step = Int(floor(cycle))
            let blend = position * position * (3 - 2 * position)
            let first = random(seed: seed, step: step)
            raw = first + (random(seed: seed, step: step + 1) - first) * blend
        } else {
            raw = waveform(at: position)
        }
        switch direction {
        case .down: return -abs(raw)
        case .up: return abs(raw)
        case .both: return raw
        }
    }

    private func playheadPosition(forCycle cycle: Double, seed: Int) -> Double {
        guard mode == .probability else { return normalized(cycle + phase) }
        let step = Int(floor(cycle + phase))
        let peakChance = min(max((probabilityBias + 1) * 0.5, 0), 1)
        let choosePeak = randomUnit(seed: seed &+ 401, step: step) < peakChance
        var selected = randomUnit(seed: seed &+ 503, step: step)
        var selectedValue = waveform(at: selected)
        for candidateIndex in 1..<8 {
            let candidate = randomUnit(seed: seed &+ 503 &+ candidateIndex &* 37, step: step)
            let value = waveform(at: candidate)
            if (choosePeak && value > selectedValue) || (!choosePeak && value < selectedValue) {
                selected = candidate
                selectedValue = value
            }
        }
        return selected
    }

    private func waveform(at position: Double) -> Double {
        let split = min(max(symmetry, 0.05), 0.95)
        let warped = position < split
            ? 0.5 * position / split
            : 0.5 + 0.5 * (position - split) / (1 - split)
        let raw: Double
        switch shape {
        case .sine: raw = sin(2 * .pi * warped)
        case .triangle: raw = 1 - 4 * abs(warped - 0.5)
        case .sawUp: raw = 2 * position - 1
        case .sawDown: raw = 1 - 2 * position
        case .square: raw = position < split ? 1 : -1
        case .gate: raw = position < split ? 1 : 0
        case .custom:
            let points = Self.normalizedCustomPoints(customPoints)
            let scaled = position * Double(points.count)
            let lower = Int(floor(scaled)) % points.count
            let upper = (lower + 1) % points.count
            let blend = scaled - floor(scaled)
            raw = points[lower] + (points[upper] - points[lower]) * blend
        }
        guard shape != .square, shape != .gate else { return raw }
        let exponent = pow(2, min(max(curve, -1), 1) * 2)
        return copysign(pow(abs(raw), exponent), raw)
    }

    private func normalized(_ value: Double) -> Double {
        let fraction = value - floor(value)
        return fraction < 0 ? fraction + 1 : fraction
    }

    private func random(seed: Int, step: Int) -> Double {
        var x = UInt64(bitPattern: Int64(seed &* 1_103_515_245 &+ step &* 12_345))
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        return Double(x &* 2_685_821_657_736_338_717 % 10_000) / 5_000 - 1
    }

    private func randomUnit(seed: Int, step: Int) -> Double {
        (random(seed: seed, step: step) + 1) * 0.5
    }

    public static let customPointCount = 16
    public static let defaultCustomPoints: [Double] = (0..<customPointCount).map {
        sin(2 * .pi * Double($0) / Double(customPointCount))
    }

    private static func normalizedCustomPoints(_ points: [Double]) -> [Double] {
        guard !points.isEmpty else { return defaultCustomPoints }
        if points.count == customPointCount { return points.map { min(max($0, -1), 1) } }
        return (0..<customPointCount).map { index in
            let source = Double(index) / Double(customPointCount) * Double(points.count)
            let lower = Int(floor(source)) % points.count
            let upper = (lower + 1) % points.count
            let blend = source - floor(source)
            return min(max(points[lower] + (points[upper] - points[lower]) * blend, -1), 1)
        }
    }
}

public struct PadConfiguration: Hashable, Codable, Sendable {
    public var playbackMode: PadPlaybackMode
    public var patternID: Int
    public var patternSeed: Int
    public var patternLocked: Bool
    public var patternRoleOverride: DrumPatternRole?
    public var patternVariation: Double
    public var patternAutoFill: Double
    public var patternFluctuation: Double
    public var patternProbability: Double
    public var patternComplexity: Double
    public var division: RepeatDivision
    public var repeatFillEnabled: Bool
    /// Length of the phrase-ending window, from a short turn to a full beat.
    public var repeatFillAmount: Double
    public var repeatFillDensity: Double
    public var repeatFillProbability: Double
    public var repeatFillEveryBars: Int
    public var repeatFillSpeedSteps: Int
    public var repeatFillBalance: Double
    /// The independent grid whose odd steps are delayed by swing.
    public var swingDivision: SwingDivision
    /// 50 is straight; 66.7 is classic triplet swing; values are clamped to 50...75.
    public var swingPercent: Double
    public var velocityMode: VelocityMode
    public var fixedVelocity: Int
    public var humanizeAmount: Int
    public var velocityHumanizeEnabled: Bool
    public var humanizeProbability: Double
    public var humanizeBias: Double
    public var divisionModulator: Modulator
    public var divisionModulationPath: DivisionModulationPath
    public var swingModulator: Modulator
    public var velocityModulator: Modulator

    public init(
        playbackMode: PadPlaybackMode = .repeatNote,
        patternID: Int = 0,
        patternSeed: Int = 1,
        patternLocked: Bool = false,
        patternRoleOverride: DrumPatternRole? = nil,
        patternVariation: Double = 0,
        patternAutoFill: Double = 0,
        patternFluctuation: Double = 0,
        patternProbability: Double = 1,
        patternComplexity: Double = 0.55,
        division: RepeatDivision = .sixteenth,
        repeatFillEnabled: Bool = false,
        repeatFillAmount: Double = 0.35,
        repeatFillDensity: Double = 0.42,
        repeatFillProbability: Double = 0.48,
        repeatFillEveryBars: Int = 2,
        repeatFillSpeedSteps: Int = 1,
        repeatFillBalance: Double = 0.65,
        swingDivision: SwingDivision = .automatic,
        swingPercent: Double = 50,
        velocityMode: VelocityMode = .received,
        fixedVelocity: Int = 100,
        humanizeAmount: Int = 10,
        velocityHumanizeEnabled: Bool = false,
        humanizeProbability: Double = 1,
        humanizeBias: Double = 0,
        divisionModulator: Modulator = .init(),
        divisionModulationPath: DivisionModulationPath = .sameFeel,
        swingModulator: Modulator = .init(),
        velocityModulator: Modulator = .init()
    ) {
        self.playbackMode = playbackMode
        self.patternID = patternID
        self.patternSeed = patternSeed
        self.patternLocked = patternLocked
        self.patternRoleOverride = patternRoleOverride
        self.patternVariation = patternVariation
        self.patternAutoFill = patternAutoFill
        self.patternFluctuation = patternFluctuation
        self.patternProbability = patternProbability
        self.patternComplexity = patternComplexity
        self.division = division
        self.repeatFillEnabled = repeatFillEnabled
        self.repeatFillAmount = min(max(repeatFillAmount, 0), 1)
        self.repeatFillDensity = min(max(repeatFillDensity, 0), 1)
        self.repeatFillProbability = min(max(repeatFillProbability, 0), 1)
        self.repeatFillEveryBars = [1, 2, 4, 8].contains(repeatFillEveryBars) ? repeatFillEveryBars : 2
        self.repeatFillSpeedSteps = min(max(repeatFillSpeedSteps, 1), 2)
        self.repeatFillBalance = min(max(repeatFillBalance, 0), 1)
        self.swingDivision = swingDivision
        self.swingPercent = swingPercent
        self.velocityMode = velocityMode
        self.fixedVelocity = fixedVelocity
        self.humanizeAmount = humanizeAmount
        self.velocityHumanizeEnabled = velocityHumanizeEnabled
        self.humanizeProbability = humanizeProbability
        self.humanizeBias = humanizeBias
        self.divisionModulator = divisionModulator
        self.divisionModulationPath = divisionModulationPath
        self.swingModulator = swingModulator
        self.velocityModulator = velocityModulator
    }

    private enum CodingKeys: String, CodingKey {
        case playbackMode, patternID, patternSeed, patternLocked, patternRoleOverride
        case patternVariation, patternAutoFill, patternFluctuation, patternProbability, patternComplexity
        case division, repeatFillEnabled, repeatFillAmount, repeatFillDensity, repeatFillProbability
        case repeatFillEveryBars, repeatFillSpeedSteps, repeatFillBalance
        case swingDivision, swingPercent, velocityMode, fixedVelocity, humanizeAmount
        case velocityHumanizeEnabled, humanizeProbability, humanizeBias
        case divisionModulator, divisionModulationPath, swingModulator, velocityModulator
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        playbackMode = try values.decodeIfPresent(PadPlaybackMode.self, forKey: .playbackMode) ?? .repeatNote
        patternID = try values.decodeIfPresent(Int.self, forKey: .patternID) ?? 0
        patternSeed = try values.decodeIfPresent(Int.self, forKey: .patternSeed) ?? 1
        patternLocked = try values.decodeIfPresent(Bool.self, forKey: .patternLocked) ?? false
        patternRoleOverride = try values.decodeIfPresent(DrumPatternRole.self, forKey: .patternRoleOverride)
        patternVariation = try values.decodeIfPresent(Double.self, forKey: .patternVariation) ?? 0
        patternAutoFill = try values.decodeIfPresent(Double.self, forKey: .patternAutoFill) ?? 0
        patternFluctuation = try values.decodeIfPresent(Double.self, forKey: .patternFluctuation) ?? 0
        patternProbability = try values.decodeIfPresent(Double.self, forKey: .patternProbability) ?? 1
        patternComplexity = try values.decodeIfPresent(Double.self, forKey: .patternComplexity) ?? 0.55
        division = try values.decodeIfPresent(RepeatDivision.self, forKey: .division) ?? .sixteenth
        repeatFillEnabled = try values.decodeIfPresent(Bool.self, forKey: .repeatFillEnabled) ?? false
        repeatFillAmount = min(max(try values.decodeIfPresent(Double.self, forKey: .repeatFillAmount) ?? 0.35, 0), 1)
        repeatFillDensity = min(max(try values.decodeIfPresent(Double.self, forKey: .repeatFillDensity) ?? 0.42, 0), 1)
        repeatFillProbability = min(max(try values.decodeIfPresent(Double.self, forKey: .repeatFillProbability) ?? 0.48, 0), 1)
        let decodedEveryBars = try values.decodeIfPresent(Int.self, forKey: .repeatFillEveryBars) ?? 2
        repeatFillEveryBars = [1, 2, 4, 8].contains(decodedEveryBars) ? decodedEveryBars : 2
        repeatFillSpeedSteps = min(max(try values.decodeIfPresent(Int.self, forKey: .repeatFillSpeedSteps) ?? 1, 1), 2)
        repeatFillBalance = min(max(try values.decodeIfPresent(Double.self, forKey: .repeatFillBalance) ?? 0.65, 0), 1)
        swingDivision = try values.decodeIfPresent(SwingDivision.self, forKey: .swingDivision) ?? .automatic
        swingPercent = try values.decodeIfPresent(Double.self, forKey: .swingPercent) ?? 50
        velocityMode = try values.decodeIfPresent(VelocityMode.self, forKey: .velocityMode) ?? .received
        fixedVelocity = try values.decodeIfPresent(Int.self, forKey: .fixedVelocity) ?? 100
        humanizeAmount = try values.decodeIfPresent(Int.self, forKey: .humanizeAmount) ?? 10
        velocityHumanizeEnabled = try values.decodeIfPresent(Bool.self, forKey: .velocityHumanizeEnabled) ?? false
        humanizeProbability = try values.decodeIfPresent(Double.self, forKey: .humanizeProbability) ?? 1
        humanizeBias = try values.decodeIfPresent(Double.self, forKey: .humanizeBias) ?? 0
        divisionModulator = try values.decodeIfPresent(Modulator.self, forKey: .divisionModulator) ?? .init()
        divisionModulationPath = try values.decodeIfPresent(DivisionModulationPath.self, forKey: .divisionModulationPath) ?? .sameFeel
        swingModulator = try values.decodeIfPresent(Modulator.self, forKey: .swingModulator) ?? .init()
        velocityModulator = try values.decodeIfPresent(Modulator.self, forKey: .velocityModulator) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(playbackMode, forKey: .playbackMode)
        try values.encode(patternID, forKey: .patternID)
        try values.encode(patternSeed, forKey: .patternSeed)
        try values.encode(patternLocked, forKey: .patternLocked)
        try values.encodeIfPresent(patternRoleOverride, forKey: .patternRoleOverride)
        try values.encode(patternVariation, forKey: .patternVariation)
        try values.encode(patternAutoFill, forKey: .patternAutoFill)
        try values.encode(patternFluctuation, forKey: .patternFluctuation)
        try values.encode(patternProbability, forKey: .patternProbability)
        try values.encode(patternComplexity, forKey: .patternComplexity)
        try values.encode(division, forKey: .division)
        try values.encode(repeatFillEnabled, forKey: .repeatFillEnabled)
        try values.encode(repeatFillAmount, forKey: .repeatFillAmount)
        try values.encode(repeatFillDensity, forKey: .repeatFillDensity)
        try values.encode(repeatFillProbability, forKey: .repeatFillProbability)
        try values.encode(repeatFillEveryBars, forKey: .repeatFillEveryBars)
        try values.encode(repeatFillSpeedSteps, forKey: .repeatFillSpeedSteps)
        try values.encode(repeatFillBalance, forKey: .repeatFillBalance)
        try values.encode(swingDivision, forKey: .swingDivision)
        try values.encode(swingPercent, forKey: .swingPercent)
        try values.encode(velocityMode, forKey: .velocityMode)
        try values.encode(fixedVelocity, forKey: .fixedVelocity)
        try values.encode(humanizeAmount, forKey: .humanizeAmount)
        try values.encode(velocityHumanizeEnabled, forKey: .velocityHumanizeEnabled)
        try values.encode(humanizeProbability, forKey: .humanizeProbability)
        try values.encode(humanizeBias, forKey: .humanizeBias)
        try values.encode(divisionModulator, forKey: .divisionModulator)
        try values.encode(divisionModulationPath, forKey: .divisionModulationPath)
        try values.encode(swingModulator, forKey: .swingModulator)
        try values.encode(velocityModulator, forKey: .velocityModulator)
    }
}

public enum CCDestination: String, CaseIterable, Codable, Sendable, Identifiable {
    case swing = "Swing All"
    case velocity = "Velocity All"
    case divisionDepth = "Division Depth"
    case swingDepth = "Swing Depth"
    case velocityDepth = "Velocity Depth"
    case humanize = "Humanize Amount"

    public var id: String { rawValue }
}

public struct CCMapping: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var ccNumber: Int

    public init(enabled: Bool = false, ccNumber: Int = 1) {
        self.enabled = enabled
        self.ccNumber = min(max(ccNumber, 0), 127)
    }
}

public enum MomentaryCCAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case swingUp = "Swing +5%"
    case swingDown = "Swing −5%"
    case straightUp1 = "Straight +1"
    case straightDown1 = "Straight −1"
    case straightUp2 = "Straight +2"
    case straightDown2 = "Straight −2"
    case tripletUp1 = "Triplet +1"
    case tripletDown1 = "Triplet −1"
    case tripletUp2 = "Triplet +2"
    case tripletDown2 = "Triplet −2"
    case allUp1 = "All Divisions +1"
    case allDown1 = "All Divisions −1"
    case allUp2 = "All Divisions +2"
    case allDown2 = "All Divisions −2"

    public var id: String { rawValue }
}

public struct MomentaryCCMapping: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var ccNumber: Int

    public init(enabled: Bool = false, ccNumber: Int = 1) {
        self.enabled = enabled
        self.ccNumber = min(max(ccNumber, 0), 127)
    }
}

public struct LiveCCConfiguration: Hashable, Codable, Sendable {
    public var mappings: [CCDestination: CCMapping]
    public var momentaryMappings: [MomentaryCCAction: MomentaryCCMapping]

    public init(
        mappings: [CCDestination: CCMapping] = [:],
        momentaryMappings: [MomentaryCCAction: MomentaryCCMapping] = [:]
    ) {
        self.mappings = mappings
        self.momentaryMappings = momentaryMappings
    }

    private enum CodingKeys: String, CodingKey {
        case mappings, momentaryMappings
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mappings = try values.decodeIfPresent([CCDestination: CCMapping].self, forKey: .mappings) ?? [:]
        momentaryMappings = try values.decodeIfPresent([MomentaryCCAction: MomentaryCCMapping].self, forKey: .momentaryMappings) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mappings, forKey: .mappings)
        try values.encode(momentaryMappings, forKey: .momentaryMappings)
    }

    public func mapping(_ destination: CCDestination) -> CCMapping {
        mappings[destination] ?? CCMapping()
    }

    public mutating func updateMapping(_ destination: CCDestination, _ change: (inout CCMapping) -> Void) {
        var mapping = mapping(destination)
        change(&mapping)
        mappings[destination] = mapping
    }

    public func momentaryMapping(_ action: MomentaryCCAction) -> MomentaryCCMapping {
        momentaryMappings[action] ?? MomentaryCCMapping(ccNumber: 70 + (MomentaryCCAction.allCases.firstIndex(of: action) ?? 0))
    }

    public mutating func updateMomentaryMapping(_ action: MomentaryCCAction, _ change: (inout MomentaryCCMapping) -> Void) {
        var mapping = momentaryMapping(action)
        change(&mapping)
        momentaryMappings[action] = mapping
    }
}

public struct RepeatizerConfiguration: Hashable, Codable, Sendable {
    public var tempoMode: TempoMode
    public var manualBPM: Double
    public var timeScale: GlobalTimeScale
    public var timingHumanizeEnabled: Bool
    public var timingHumanizeMilliseconds: Double
    public var timingHumanizeProbability: Double
    public var timingHumanizeBias: Double
    public var settingsMode: SettingsMode
    public var masterSettings: PadConfiguration
    public var captureShortTaps: Bool
    public var tapLive: Bool
    public var tapLiveBuffer: RepeatDivision
    public var tapLiveQuantizeMode: LiveTapQuantizeMode
    public var tapLiveStraightDivision: RepeatDivision
    public var tapLiveTripletDivision: RepeatDivision
    public var drumGestures: DrumGestureConfiguration
    public var pads: [Int: PadConfiguration]
    public var visibleNotes: [Int]
    public var masterNote: Int?
    public var followerNotes: Set<Int>
    public var liveCC: LiveCCConfiguration

    public init(
        tempoMode: TempoMode = .hostSync,
        manualBPM: Double = 120,
        timeScale: GlobalTimeScale = .normal,
        timingHumanizeEnabled: Bool = false,
        timingHumanizeMilliseconds: Double = 8,
        timingHumanizeProbability: Double = 1,
        timingHumanizeBias: Double = 0,
        settingsMode: SettingsMode = .individual,
        masterSettings: PadConfiguration = .init(),
        captureShortTaps: Bool = true,
        tapLive: Bool = false,
        tapLiveBuffer: RepeatDivision = .quarter,
        tapLiveQuantizeMode: LiveTapQuantizeMode = .free,
        tapLiveStraightDivision: RepeatDivision = .sixteenth,
        tapLiveTripletDivision: RepeatDivision = .sixteenthTriplet,
        drumGestures: DrumGestureConfiguration = .init(),
        pads: [Int: PadConfiguration] = [:],
        visibleNotes: [Int]? = nil,
        masterNote: Int? = nil,
        followerNotes: Set<Int> = [],
        liveCC: LiveCCConfiguration = .init()
    ) {
        self.tempoMode = tempoMode
        self.manualBPM = manualBPM
        self.timeScale = timeScale
        self.timingHumanizeEnabled = timingHumanizeEnabled
        self.timingHumanizeMilliseconds = min(max(timingHumanizeMilliseconds, 0), 30)
        self.timingHumanizeProbability = min(max(timingHumanizeProbability, 0), 1)
        self.timingHumanizeBias = min(max(timingHumanizeBias, -1), 1)
        self.settingsMode = settingsMode
        self.masterSettings = masterSettings
        self.captureShortTaps = captureShortTaps
        self.tapLive = tapLive
        self.tapLiveBuffer = tapLiveBuffer
        self.tapLiveQuantizeMode = tapLiveQuantizeMode
        self.tapLiveStraightDivision = tapLiveStraightDivision.isTriplet ? .sixteenth : tapLiveStraightDivision
        self.tapLiveTripletDivision = tapLiveTripletDivision.isTriplet ? tapLiveTripletDivision : .sixteenthTriplet
        self.drumGestures = drumGestures
        self.pads = pads
        self.visibleNotes = Self.normalized(visibleNotes ?? pads.keys.sorted())
        self.masterNote = masterNote
        self.followerNotes = followerNotes
        self.liveCC = liveCC
    }

    private enum CodingKeys: String, CodingKey {
        case tempoMode, manualBPM, timeScale, timingHumanizeEnabled, timingHumanizeMilliseconds
        case timingHumanizeProbability, timingHumanizeBias
        case settingsMode, masterSettings, captureShortTaps, tapLive, tapLiveBuffer
        case tapLiveQuantizeMode, tapLiveStraightDivision, tapLiveTripletDivision, drumGestures
        case pads, visibleNotes, masterNote, followerNotes, liveCC
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tempoMode = try values.decodeIfPresent(TempoMode.self, forKey: .tempoMode) ?? .hostSync
        manualBPM = try values.decodeIfPresent(Double.self, forKey: .manualBPM) ?? 120
        timeScale = try values.decodeIfPresent(GlobalTimeScale.self, forKey: .timeScale) ?? .normal
        timingHumanizeEnabled = try values.decodeIfPresent(Bool.self, forKey: .timingHumanizeEnabled) ?? false
        timingHumanizeMilliseconds = min(max(try values.decodeIfPresent(Double.self, forKey: .timingHumanizeMilliseconds) ?? 8, 0), 30)
        timingHumanizeProbability = min(max(try values.decodeIfPresent(Double.self, forKey: .timingHumanizeProbability) ?? 1, 0), 1)
        timingHumanizeBias = min(max(try values.decodeIfPresent(Double.self, forKey: .timingHumanizeBias) ?? 0, -1), 1)
        settingsMode = try values.decodeIfPresent(SettingsMode.self, forKey: .settingsMode) ?? .individual
        masterSettings = try values.decodeIfPresent(PadConfiguration.self, forKey: .masterSettings) ?? .init()
        captureShortTaps = try values.decodeIfPresent(Bool.self, forKey: .captureShortTaps) ?? true
        tapLive = try values.decodeIfPresent(Bool.self, forKey: .tapLive) ?? false
        tapLiveBuffer = try values.decodeIfPresent(RepeatDivision.self, forKey: .tapLiveBuffer) ?? .quarter
        tapLiveQuantizeMode = try values.decodeIfPresent(LiveTapQuantizeMode.self, forKey: .tapLiveQuantizeMode) ?? .free
        tapLiveStraightDivision = try values.decodeIfPresent(RepeatDivision.self, forKey: .tapLiveStraightDivision) ?? .sixteenth
        if tapLiveStraightDivision.isTriplet { tapLiveStraightDivision = .sixteenth }
        tapLiveTripletDivision = try values.decodeIfPresent(RepeatDivision.self, forKey: .tapLiveTripletDivision) ?? .sixteenthTriplet
        if !tapLiveTripletDivision.isTriplet { tapLiveTripletDivision = .sixteenthTriplet }
        drumGestures = try values.decodeIfPresent(DrumGestureConfiguration.self, forKey: .drumGestures) ?? .init()
        pads = try values.decodeIfPresent([Int: PadConfiguration].self, forKey: .pads) ?? [:]
        visibleNotes = Self.normalized(try values.decodeIfPresent([Int].self, forKey: .visibleNotes) ?? pads.keys.sorted())
        masterNote = try values.decodeIfPresent(Int.self, forKey: .masterNote)
        followerNotes = try values.decodeIfPresent(Set<Int>.self, forKey: .followerNotes) ?? []
        liveCC = try values.decodeIfPresent(LiveCCConfiguration.self, forKey: .liveCC) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(tempoMode, forKey: .tempoMode)
        try values.encode(manualBPM, forKey: .manualBPM)
        try values.encode(timeScale, forKey: .timeScale)
        try values.encode(timingHumanizeEnabled, forKey: .timingHumanizeEnabled)
        try values.encode(timingHumanizeMilliseconds, forKey: .timingHumanizeMilliseconds)
        try values.encode(timingHumanizeProbability, forKey: .timingHumanizeProbability)
        try values.encode(timingHumanizeBias, forKey: .timingHumanizeBias)
        try values.encode(settingsMode, forKey: .settingsMode)
        try values.encode(masterSettings, forKey: .masterSettings)
        try values.encode(captureShortTaps, forKey: .captureShortTaps)
        try values.encode(tapLive, forKey: .tapLive)
        try values.encode(tapLiveBuffer, forKey: .tapLiveBuffer)
        try values.encode(tapLiveQuantizeMode, forKey: .tapLiveQuantizeMode)
        try values.encode(tapLiveStraightDivision, forKey: .tapLiveStraightDivision)
        try values.encode(tapLiveTripletDivision, forKey: .tapLiveTripletDivision)
        try values.encode(drumGestures, forKey: .drumGestures)
        try values.encode(pads, forKey: .pads)
        try values.encode(visibleNotes, forKey: .visibleNotes)
        try values.encodeIfPresent(masterNote, forKey: .masterNote)
        try values.encode(followerNotes, forKey: .followerNotes)
        try values.encode(liveCC, forKey: .liveCC)
    }

    public func pad(_ note: Int) -> PadConfiguration {
        pads[note] ?? PadConfiguration()
    }

    public func effectivePad(_ note: Int) -> PadConfiguration {
        let identity = pad(note)
        guard settingsMode == .master else { return Self.resolvingPatternRole(identity, note: note) }
        // Master mode shares performance controls while retaining a role-aware
        // pattern identity for every drum pad. A kick and a hi-hat therefore
        // follow the same global complexity/variation settings without being
        // forced to play the same rhythm lane.
        var result = masterSettings
        result.patternID = identity.patternID
        result.patternSeed = identity.patternSeed
        result.patternLocked = identity.patternLocked
        result.patternRoleOverride = identity.patternRoleOverride
        return Self.resolvingPatternRole(result, note: note)
    }

    private static func resolvingPatternRole(_ pad: PadConfiguration, note: Int) -> PadConfiguration {
        var result = pad
        let role = result.patternRoleOverride ?? DrumPatternLibrary.inferredRole(forMIDINote: note)
        if DrumPatternLibrary.pattern(result.patternID).role != role {
            result.patternID = DrumPatternLibrary.patternID(style: .foundation, role: role, variant: 0)
        }
        return result
    }

    public mutating func updateActivePad(_ note: Int, _ change: (inout PadConfiguration) -> Void) {
        if settingsMode == .master { change(&masterSettings) }
        else { updatePad(note, change) }
    }

    public mutating func updatePad(_ note: Int, _ change: (inout PadConfiguration) -> Void) {
        guard (0...127).contains(note), !followerNotes.contains(note) else { return }
        var value = pad(note)
        change(&value)
        pads[note] = value
        if masterNote == note {
            for follower in followerNotes { pads[follower] = value }
        }
    }

    public mutating func updatePatternIdentity(_ note: Int, _ change: (inout PadConfiguration) -> Void) {
        updatePad(note, change)
    }

    public mutating func setMaster(_ note: Int?) {
        guard let note else {
            masterNote = nil
            followerNotes.removeAll()
            return
        }
        guard (0...127).contains(note) else { return }
        addVisiblePad(note)
        masterNote = note
        followerNotes.remove(note)
        let master = pad(note)
        for follower in followerNotes { pads[follower] = master }
    }

    public mutating func setFollower(_ note: Int, follows: Bool) {
        guard (0...127).contains(note), note != masterNote else { return }
        if follows, let masterNote {
            addVisiblePad(note)
            pads[note] = pad(masterNote)
            followerNotes.insert(note)
        } else {
            followerNotes.remove(note)
        }
    }

    public mutating func setAllVisiblePadsFollowing(_ follows: Bool) {
        guard let masterNote else {
            if !follows { followerNotes.removeAll() }
            return
        }
        for note in visibleNotes where note != masterNote {
            setFollower(note, follows: follows)
        }
    }

    public mutating func addVisiblePad(_ note: Int) {
        guard (0...127).contains(note) else { return }
        pads[note] = pad(note)
        visibleNotes = Self.normalized(visibleNotes + [note])
    }

    public mutating func removeVisiblePad(_ note: Int) {
        visibleNotes.removeAll { $0 == note }
        followerNotes.remove(note)
        if masterNote == note {
            masterNote = nil
            followerNotes.removeAll()
        }
    }

    private static func normalized(_ notes: [Int]) -> [Int] {
        Array(Set(notes.filter { (0...127).contains($0) })).sorted()
    }
}

public enum GMDrumPad: Int, CaseIterable, Identifiable, Sendable {
    case kick = 36, kick2 = 37, snare = 38, clap = 39, snare2 = 40, lowTom = 41, closedHat = 42, highTom = 43
    case pedalHat = 44, midTom = 45, openHat = 46, lowMidTom = 47, highMidTom = 48, crash = 49, highTom2 = 50, ride = 51

    public var id: Int { rawValue }
    public var name: String { GMDrumMap.name(for: rawValue) }
}

public enum GMDrumMap {
    public static let coreNotes = Array(36...51)

    public static func name(for note: Int) -> String {
        switch note {
        case 35: "Acoustic Bass Drum"
        case 36: "Bass Drum 1"
        case 37: "Side Stick"
        case 38: "Acoustic Snare"
        case 39: "Hand Clap"
        case 40: "Electric Snare"
        case 41: "Low Floor Tom"
        case 42: "Closed Hi-Hat"
        case 43: "High Floor Tom"
        case 44: "Pedal Hi-Hat"
        case 45: "Low Tom"
        case 46: "Open Hi-Hat"
        case 47: "Low-Mid Tom"
        case 48: "Hi-Mid Tom"
        case 49: "Crash Cymbal 1"
        case 50: "High Tom"
        case 51: "Ride Cymbal 1"
        case 52: "Chinese Cymbal"
        case 53: "Ride Bell"
        case 54: "Tambourine"
        case 55: "Splash Cymbal"
        case 56: "Cowbell"
        case 57: "Crash Cymbal 2"
        case 58: "Vibraslap"
        case 59: "Ride Cymbal 2"
        case 60: "Hi Bongo"
        case 61: "Low Bongo"
        case 62: "Mute Hi Conga"
        case 63: "Open Hi Conga"
        case 64: "Low Conga"
        case 65: "High Timbale"
        case 66: "Low Timbale"
        case 67: "High Agogo"
        case 68: "Low Agogo"
        case 69: "Cabasa"
        case 70: "Maracas"
        case 71: "Short Whistle"
        case 72: "Long Whistle"
        case 73: "Short Guiro"
        case 74: "Long Guiro"
        case 75: "Claves"
        case 76: "Hi Wood Block"
        case 77: "Low Wood Block"
        case 78: "Mute Cuica"
        case 79: "Open Cuica"
        case 80: "Mute Triangle"
        case 81: "Open Triangle"
        default: "MIDI Note \(note)"
        }
    }
}

public enum PerformancePresetKind: String, CaseIterable, Codable, Sendable {
    case foundation = "Foundation"
    case groove = "Groove"
    case rolls = "Rolls"
    case fills = "Fills"
}

public struct RepeatizerPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: PerformancePresetKind
    public let detail: String
    public let pads: [Int: PadConfiguration]
    public let visibleNotes: [Int]
    public let settingsMode: SettingsMode
    public let masterNote: Int?
    public let followerNotes: Set<Int>

    public init(
        id: String,
        name: String,
        kind: PerformancePresetKind,
        detail: String,
        pads: [Int: PadConfiguration],
        visibleNotes: [Int]? = nil,
        settingsMode: SettingsMode = .individual,
        masterNote: Int? = nil,
        followerNotes: Set<Int> = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.detail = detail
        self.pads = pads
        self.visibleNotes = visibleNotes ?? pads.keys.sorted()
        self.settingsMode = settingsMode
        self.masterNote = masterNote
        self.followerNotes = followerNotes
    }

    public var menuName: String { "\(kind.rawValue) · \(name)" }

    public var configuration: RepeatizerConfiguration {
        RepeatizerConfiguration(settingsMode: settingsMode, pads: pads, visibleNotes: visibleNotes, masterNote: masterNote, followerNotes: followerNotes)
    }
}

public enum RepeatizerPresets {
    private static func kit(_ overrides: [Int: PadConfiguration] = [:]) -> [Int: PadConfiguration] {
        var result = Dictionary(uniqueKeysWithValues: GMDrumMap.coreNotes.map { ($0, PadConfiguration()) })
        for (note, value) in overrides { result[note] = value }
        return result
    }

    public static let gmStandard = RepeatizerPreset(
        id: "gm-standard",
        name: "Clean Slate",
        kind: .foundation,
        detail: "Straight sixteenth-note repeat lanes across the core GM kit.",
        pads: kit(),
        settingsMode: .master
    )

    public static let boomBapPocket = RepeatizerPreset(
        id: "boom-bap-pocket",
        name: "Boom Bap Pocket",
        kind: .groove,
        detail: "Loose swung hats, weighty kick repeats, and humanized ghost-note snares.",
        pads: kit([
            36: PadConfiguration(division: .eighth, swingPercent: 62, velocityMode: .humanized, humanizeAmount: 7),
            38: PadConfiguration(division: .eighth, swingPercent: 62, velocityMode: .humanized, humanizeAmount: 13),
            40: PadConfiguration(division: .sixteenth, swingPercent: 62, velocityMode: .humanized, humanizeAmount: 18),
            42: PadConfiguration(division: .sixteenth, swingPercent: 62, velocityMode: .humanized, humanizeAmount: 15),
            44: PadConfiguration(division: .sixteenth, swingPercent: 62, velocityMode: .humanized, humanizeAmount: 15)
        ]),
        masterNote: 42,
        followerNotes: [44]
    )

    public static let neoSoulPush = RepeatizerPreset(
        id: "neo-soul-push",
        name: "Neo-Soul Push",
        kind: .groove,
        detail: "Deep triplet swing with soft velocity motion for behind-the-beat performances.",
        pads: kit([
            36: PadConfiguration(division: .eighth, swingPercent: 66.7, velocityMode: .humanized, humanizeAmount: 11),
            38: PadConfiguration(division: .eighthTriplet, swingPercent: 66.7, velocityMode: .humanized, humanizeAmount: 15),
            39: PadConfiguration(division: .quarterTriplet, swingPercent: 66.7, velocityMode: .humanized, humanizeAmount: 9),
            42: PadConfiguration(division: .sixteenth, swingPercent: 66.7, velocityMode: .humanized, humanizeAmount: 18),
            46: PadConfiguration(division: .eighth, swingPercent: 66.7, velocityMode: .humanized, humanizeAmount: 10)
        ])
    )

    public static let houseDrive = RepeatizerPreset(
        id: "house-drive",
        name: "House Drive",
        kind: .groove,
        detail: "Firm quarter-note foundation with lightly swung hats and open-hat lift.",
        pads: kit([
            36: PadConfiguration(division: .quarter, swingPercent: 52, velocityMode: .fixed, fixedVelocity: 116),
            39: PadConfiguration(division: .half, swingPercent: 52, velocityMode: .fixed, fixedVelocity: 104),
            42: PadConfiguration(division: .sixteenth, swingPercent: 56, velocityMode: .humanized, humanizeAmount: 7),
            46: PadConfiguration(division: .eighth, swingPercent: 56, velocityMode: .humanized, humanizeAmount: 6),
            51: PadConfiguration(division: .eighth, swingPercent: 54, velocityMode: .humanized, humanizeAmount: 8)
        ])
    )

    public static let afroPercussion = RepeatizerPreset(
        id: "afro-percussion",
        name: "Afro Percussion Weave",
        kind: .groove,
        detail: "Interlocking triplet and straight lanes for layered hand-percussion playing.",
        pads: kit([
            37: PadConfiguration(division: .eighthTriplet, swingPercent: 58, velocityMode: .humanized, humanizeAmount: 15),
            39: PadConfiguration(division: .quarterTriplet, swingPercent: 58, velocityMode: .humanized, humanizeAmount: 12),
            41: PadConfiguration(division: .eighth, swingPercent: 58, velocityMode: .humanized, humanizeAmount: 13),
            45: PadConfiguration(division: .sixteenthTriplet, swingPercent: 58, velocityMode: .humanized, humanizeAmount: 16),
            47: PadConfiguration(division: .eighthTriplet, swingPercent: 58, velocityMode: .humanized, humanizeAmount: 15)
        ])
    )

    public static let trapHatLab = RepeatizerPreset(
        id: "trap-hat-lab",
        name: "Trap Hat Lab",
        kind: .rolls,
        detail: "Fast hat rolls with random division jumps and controlled velocity movement.",
        pads: kit([
            38: PadConfiguration(division: .sixteenthTriplet, swingPercent: 50, velocityMode: .received),
            42: PadConfiguration(division: .thirtySecond, swingPercent: 50, velocityMode: .humanized, humanizeAmount: 12, divisionModulator: Modulator(mode: .random, rate: 0.5, depth: 2, direction: .both), velocityModulator: Modulator(mode: .lfo, rate: 0.5, depth: 0.8, direction: .down)),
            44: PadConfiguration(division: .thirtySecond, swingPercent: 50, velocityMode: .humanized, humanizeAmount: 12, divisionModulator: Modulator(mode: .random, rate: 0.5, depth: 2, direction: .both), velocityModulator: Modulator(mode: .lfo, rate: 0.5, depth: 0.8, direction: .down)),
            46: PadConfiguration(division: .sixteenth, swingPercent: 50, velocityMode: .humanized, humanizeAmount: 8)
        ]),
        masterNote: 42,
        followerNotes: [44]
    )

    public static let drillStutters = RepeatizerPreset(
        id: "drill-stutters",
        name: "Drill Stutters",
        kind: .rolls,
        detail: "Triplet-biased hats and sharp snare bursts for tense stop-start phrases.",
        pads: kit([
            36: PadConfiguration(division: .eighthTriplet, swingPercent: 54, velocityMode: .fixed, fixedVelocity: 112),
            38: PadConfiguration(division: .thirtySecondTriplet, swingPercent: 54, velocityMode: .humanized, humanizeAmount: 9, divisionModulator: Modulator(mode: .random, rate: 1, depth: 1, direction: .down)),
            40: PadConfiguration(division: .sixteenthTriplet, swingPercent: 54, velocityMode: .humanized, humanizeAmount: 13),
            42: PadConfiguration(division: .thirtySecondTriplet, swingPercent: 54, velocityMode: .humanized, humanizeAmount: 11, swingModulator: Modulator(mode: .random, rate: 0.5, depth: 0.7, direction: .both))
        ])
    )

    public static let drumAndBassFill = RepeatizerPreset(
        id: "dnb-fill",
        name: "D&B Ghost Fill",
        kind: .fills,
        detail: "Rapid snare ghosts and descending tom lanes for held-note breakbeat fills.",
        pads: kit([
            38: PadConfiguration(division: .thirtySecond, swingPercent: 53, velocityMode: .humanized, humanizeAmount: 20, velocityModulator: Modulator(mode: .random, rate: 1, depth: 0.7, direction: .down)),
            40: PadConfiguration(division: .sixteenthTriplet, swingPercent: 53, velocityMode: .humanized, humanizeAmount: 17),
            41: PadConfiguration(division: .sixteenth, swingPercent: 53, velocityMode: .humanized, humanizeAmount: 13),
            45: PadConfiguration(division: .sixteenthTriplet, swingPercent: 53, velocityMode: .humanized, humanizeAmount: 14),
            48: PadConfiguration(division: .thirtySecondTriplet, swingPercent: 53, velocityMode: .humanized, humanizeAmount: 15)
        ])
    )

    public static let latinTomRun = RepeatizerPreset(
        id: "latin-tom-run",
        name: "Latin Tom Run",
        kind: .fills,
        detail: "Rolling tom and side-stick lanes with lively velocity arcs.",
        pads: kit([
            37: PadConfiguration(division: .eighthTriplet, swingPercent: 60, velocityMode: .humanized, humanizeAmount: 10),
            41: PadConfiguration(division: .sixteenthTriplet, swingPercent: 60, velocityMode: .humanized, humanizeAmount: 12, velocityModulator: Modulator(mode: .lfo, rate: 0.5, depth: 0.8, direction: .both)),
            43: PadConfiguration(division: .sixteenthTriplet, swingPercent: 60, velocityMode: .humanized, humanizeAmount: 12, velocityModulator: Modulator(mode: .lfo, rate: 0.5, depth: 0.8, direction: .both)),
            45: PadConfiguration(division: .thirtySecondTriplet, swingPercent: 60, velocityMode: .humanized, humanizeAmount: 14),
            48: PadConfiguration(division: .thirtySecondTriplet, swingPercent: 60, velocityMode: .humanized, humanizeAmount: 14)
        ])
    )

    public static let glitchFill = RepeatizerPreset(
        id: "glitch-fill",
        name: "Glitch Fill",
        kind: .fills,
        detail: "Unstable subdivisions and swing motion for short, performable transition bursts.",
        pads: kit([
            38: PadConfiguration(division: .sixteenth, swingPercent: 55, velocityMode: .humanized, humanizeAmount: 16, divisionModulator: Modulator(mode: .random, rate: 2, depth: 2, direction: .both), swingModulator: Modulator(mode: .random, rate: 1, depth: 1, direction: .both)),
            39: PadConfiguration(division: .thirtySecond, swingPercent: 50, velocityMode: .fixed, fixedVelocity: 105, divisionModulator: Modulator(mode: .lfo, rate: 1, depth: 2, direction: .both)),
            42: PadConfiguration(division: .thirtySecondTriplet, swingPercent: 57, velocityMode: .humanized, humanizeAmount: 19, divisionModulator: Modulator(mode: .random, rate: 2, depth: 2, direction: .both)),
            49: PadConfiguration(division: .eighthTriplet, swingPercent: 50, velocityMode: .fixed, fixedVelocity: 118)
        ])
    )

    public static let all: [RepeatizerPreset] = [
        gmStandard,
        boomBapPocket, neoSoulPush, houseDrive, afroPercussion,
        trapHatLab, drillStutters,
        drumAndBassFill, latinTomRun, glitchFill
    ]
}

public struct MIDIInputEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case noteOn, noteOff, controlChange }
    public var kind: Kind
    public var note: Int
    public var velocity: Int
    public var channel: Int
    public var beat: Double

    public init(_ kind: Kind, note: Int, velocity: Int = 0, channel: Int = 9, beat: Double) {
        self.kind = kind
        self.note = note
        self.velocity = velocity
        self.channel = channel
        self.beat = beat
    }
}

public struct MIDIOutputEvent: Sendable, Hashable, Comparable {
    public enum Kind: Sendable, Hashable { case noteOn, noteOff }
    public var kind: Kind
    public var note: Int
    public var velocity: Int
    public var channel: Int
    public var beat: Double

    public static func < (lhs: MIDIOutputEvent, rhs: MIDIOutputEvent) -> Bool {
        lhs.beat == rhs.beat ? (lhs.kind == .noteOff && rhs.kind == .noteOn) : lhs.beat < rhs.beat
    }
}

/// Testable timeline engine used by the Audio Unit. The AU converts render-frame
/// timing to beats; this engine owns the musical decisions and is safe to test
/// without a running DAW.
public struct RepeatEngine: Sendable {
    private struct HeldNote: Sendable {
        var velocity: Int
        var channel: Int
        var nextBeat: Double
        var repeatIndex: Int
        var isSwungSide: Bool
        var patternGlobalStep: Int
        var patternPointValid: Bool
        var releaseAfterFirst: Bool
        var earliestRepeatBeat: Double
        var liveTapBeat: Double
        var liveTapPending: Bool
        var stopAfterLiveTap: Bool
    }

    private struct PendingOff: Sendable {
        var note: Int
        var channel: Int
        var beat: Double
    }

    public var configuration: RepeatizerConfiguration
    private var held: [Int: HeldNote] = [:]
    private var pendingOffs: [PendingOff] = []
    private var ccValues: [Int: Int] = [:]

    public init(configuration: RepeatizerConfiguration = .init()) {
        self.configuration = configuration
    }

    /// Processes all input events in the supplied musical range and returns the
    /// generated MIDI. The fixed 0.03-beat note-off is intentionally internal;
    /// there is no exposed gate/note-length feature in this first product scope.
    public mutating func process(_ input: [MIDIInputEvent], from startBeat: Double, to endBeat: Double) -> [MIDIOutputEvent] {
        precondition(endBeat >= startBeat)
        var output: [MIDIOutputEvent] = []
        var cursor = startBeat
        for event in input.sorted(by: { $0.beat < $1.beat }) where event.beat <= endBeat {
            let clampedBeat = max(cursor, event.beat)
            output += render(until: clampedBeat)
            cursor = clampedBeat
            switch event.kind {
            case .noteOn where event.velocity > 0:
                start(note: event.note, velocity: event.velocity, channel: event.channel, at: clampedBeat)
                if configuration.tapLive, configuration.tapLiveQuantizeMode == .free {
                    output.append(MIDIOutputEvent(
                        kind: .noteOn,
                        note: event.note,
                        velocity: event.velocity,
                        channel: event.channel,
                        beat: clampedBeat
                    ))
                }
            case .noteOn, .noteOff:
                if var state = held[event.note] {
                    if configuration.tapLive, state.liveTapPending {
                        state.stopAfterLiveTap = true
                        held[event.note] = state
                    } else if !configuration.tapLive,
                              configuration.captureShortTaps,
                              configuration.effectivePad(event.note).playbackMode == .repeatNote,
                              state.repeatIndex == 0 {
                        state.releaseAfterFirst = true
                        held[event.note] = state
                    } else {
                        held.removeValue(forKey: event.note)
                    }
                } else {
                    held.removeValue(forKey: event.note)
                }
                if held[event.note]?.liveTapPending != true {
                    output.append(MIDIOutputEvent(kind: .noteOff, note: event.note, velocity: 0, channel: event.channel, beat: clampedBeat))
                }
            case .controlChange:
                ccValues[event.note] = min(max(event.velocity, 0), 127)
                regridDivisionCC(at: clampedBeat, cc: event.note)
            }
        }
        output += render(until: endBeat)
        return output.sorted()
    }

    private mutating func start(note: Int, velocity: Int, channel: Int, at beat: Double) {
        let settings = configuration.effectivePad(note)
        let liveTapBeat = configuration.tapLive ? quantizedLiveTapBeat(atOrAfter: beat) : beat
        let earliestRepeatBeat = configuration.tapLive
            ? tapLiveResumeBeat(after: liveTapBeat)
            : beat
        let firstBeat: Double
        let firstIsSwung: Bool
        let firstPatternStep: Int
        let firstPatternPointValid: Bool
        if settings.playbackMode == .pattern {
            let point = nextPatternPoint(for: settings, atOrAfter: earliestRepeatBeat, eventIndex: 0, note: note)
            firstBeat = point.beat
            firstIsSwung = point.globalStep % 2 != 0
            firstPatternStep = point.globalStep
            firstPatternPointValid = point.valid
        } else {
            let grid = nextGridPoint(for: settings, atOrAfter: earliestRepeatBeat, eventIndex: 0, note: note)
            firstBeat = grid.beat
            firstIsSwung = grid.isSwungSide
            firstPatternStep = 0
            firstPatternPointValid = false
        }
        held[note] = HeldNote(
            velocity: velocity,
            channel: channel,
            nextBeat: firstBeat,
            repeatIndex: 0,
            isSwungSide: firstIsSwung,
            patternGlobalStep: firstPatternStep,
            patternPointValid: firstPatternPointValid,
            releaseAfterFirst: false,
            earliestRepeatBeat: earliestRepeatBeat,
            liveTapBeat: liveTapBeat,
            liveTapPending: configuration.tapLive && configuration.tapLiveQuantizeMode != .free,
            stopAfterLiveTap: false
        )
    }

    private func quantizedLiveTapBeat(atOrAfter beat: Double) -> Double {
        func next(_ division: RepeatDivision) -> Double {
            let unit = division.beats * configuration.timeScale.intervalMultiplier
            return ceil((beat - 0.0000001) / unit) * unit
        }
        switch configuration.tapLiveQuantizeMode {
        case .free: return beat
        case .straight: return next(configuration.tapLiveStraightDivision)
        case .triplet: return next(configuration.tapLiveTripletDivision)
        case .both:
            return min(next(configuration.tapLiveStraightDivision), next(configuration.tapLiveTripletDivision))
        }
    }

    private func tapLiveResumeBeat(after liveBeat: Double) -> Double {
        liveBeat + configuration.tapLiveBuffer.beats * configuration.timeScale.intervalMultiplier
    }

    private mutating func render(until endBeat: Double) -> [MIDIOutputEvent] {
        var output: [MIDIOutputEvent] = []
        let dueOffs = pendingOffs.enumerated().filter { $0.element.beat <= endBeat }
        for item in dueOffs.reversed() {
            let off = item.element
            output.append(MIDIOutputEvent(kind: .noteOff, note: off.note, velocity: 0, channel: off.channel, beat: off.beat))
            pendingOffs.remove(at: item.offset)
        }

        for note in held.keys.sorted() {
            guard var state = held[note] else { continue }
            if state.liveTapPending {
                guard state.liveTapBeat <= endBeat else {
                    held[note] = state
                    continue
                }
                output.append(MIDIOutputEvent(
                    kind: .noteOn, note: note, velocity: state.velocity,
                    channel: state.channel, beat: state.liveTapBeat
                ))
                state.liveTapPending = false
                if state.stopAfterLiveTap {
                    pendingOffs.append(PendingOff(note: note, channel: state.channel, beat: state.liveTapBeat + 0.03))
                    held.removeValue(forKey: note)
                    continue
                }
            }

            while true {
                let settings = configuration.effectivePad(note)
                let isPattern = settings.playbackMode == .pattern
                let outputBeat = timingHumanizedBeat(
                    state.nextBeat,
                    settings: settings,
                    note: note,
                    eventIndex: state.repeatIndex
                )
                guard outputBeat <= endBeat else { break }
                if !isPattern || state.patternPointValid {
                    let velocity = velocityFor(settings, source: state.velocity, beat: state.nextBeat, eventIndex: state.repeatIndex, note: note)
                    let protectedBeat = max(outputBeat, state.earliestRepeatBeat)
                    output.append(MIDIOutputEvent(kind: .noteOn, note: note, velocity: velocity, channel: state.channel, beat: protectedBeat))
                    pendingOffs.append(PendingOff(note: note, channel: state.channel, beat: protectedBeat + 0.03))
                }

                if isPattern {
                    let point = nextPatternPoint(
                        for: settings,
                        atOrAfter: state.nextBeat + 0.000001,
                        eventIndex: state.repeatIndex + 1,
                        note: note
                    )
                    state.nextBeat = point.beat
                    state.patternGlobalStep = point.globalStep
                    state.patternPointValid = point.valid
                    state.isSwungSide = point.globalStep % 2 != 0
                } else {
                    let grid = nextGridPoint(
                        for: settings,
                        atOrAfter: state.nextBeat + 0.000001,
                        eventIndex: state.repeatIndex + 1,
                        note: note
                    )
                    state.nextBeat = grid.beat
                    state.isSwungSide = grid.isSwungSide
                }
                state.repeatIndex += 1
                if state.releaseAfterFirst { break }
            }
            if state.releaseAfterFirst, state.repeatIndex > 0 { held.removeValue(forKey: note) }
            else { held[note] = state }
        }
        return output
    }

    private func nextGridPoint(for settings: PadConfiguration, atOrAfter beat: Double, eventIndex: Int, note: Int) -> (beat: Double, isSwungSide: Bool) {
        let division = resolvedDivision(settings, movement: 0)
        let baseBeats = division.beats * configuration.timeScale.intervalMultiplier
        let amount = min(max(settings.repeatFillAmount, 0), 1)
        let fillSteps = min(max(settings.repeatFillSpeedSteps, 1), 2)
        let fillDivision = settings.repeatFillEnabled && amount > 0.001
            ? division.moved(by: fillSteps, path: .sameFeel)
            : division
        let searchBeats = fillDivision.beats * configuration.timeScale.intervalMultiplier
        let approximateStep = Int(floor(beat / searchBeats)) - 2
        for offset in 0..<128 {
            let globalStep = approximateStep + offset
            let straightBeat = Double(globalStep) * searchBeats
            let basePosition = straightBeat / baseBeats
            let isBaseHit = abs(basePosition - basePosition.rounded()) < 0.0000001
            let phase = straightBeat - floor(straightBeat / 4) * 4
            let fillZoneStart = 4 - (0.25 + amount * 0.75)
            let barIndex = Int(floor(straightBeat / 4))
            let everyBars = [1, 2, 4, 8].contains(settings.repeatFillEveryBars)
                ? settings.repeatFillEveryBars : 2
            let cadenceActive = positiveModulo(barIndex, everyBars) == everyBars - 1
            let balance = min(max(settings.repeatFillBalance, 0), 1)
            let activationChance = min(max(settings.repeatFillProbability, 0), 1)
                * ((1 - balance) + balance * repeatFillRoleWeight(note))
            let phraseActive = cadenceActive
                && patternRandomUnit(note: note, globalStep: barIndex, seed: 709, salt: 71) <= activationChance
            let inFillZone = settings.repeatFillEnabled && amount > 0.001 && phraseActive
                && phase >= fillZoneStart - 0.0000001 && phase < 4 - 0.0000001
            let selectedSteps = fillSteps == 2
                && patternRandomUnit(note: note, globalStep: barIndex, seed: 811, salt: 73) > 0.55 ? 2 : 1
            let selectedFillDivision = division.moved(by: selectedSteps, path: .sameFeel)
            let selectedFillBeats = selectedFillDivision.beats
                * configuration.timeScale.intervalMultiplier
            let selectedPosition = straightBeat / selectedFillBeats
            let belongsToSelectedSpeed = abs(selectedPosition - selectedPosition.rounded()) < 0.0000001
            let phraseVariation = 0.65
                + patternRandomUnit(note: note, globalStep: barIndex, seed: 919, salt: 79) * 0.70
            let fillChance = settings.repeatFillDensity >= 0.999
                ? 1 : min(max(settings.repeatFillDensity * phraseVariation, 0), 1)
            let extraHit = inFillZone && !isBaseHit && belongsToSelectedSpeed
                && patternRandomUnit(note: note, globalStep: globalStep, seed: 1_019, salt: 83) <= fillChance
            guard isBaseHit || extraHit else { continue }
            let automaticDivision = extraHit ? selectedFillDivision : division
            let candidate = swungBeat(straightBeat, settings: settings, automaticDivision: automaticDivision)
            if candidate >= beat - 0.0000001 {
                return (candidate, abs(candidate - straightBeat) > 0.0000001)
            }
        }
        return (beat + baseBeats, false)
    }

    private func repeatFillRoleWeight(_ note: Int) -> Double {
        switch DrumPatternLibrary.inferredRole(forMIDINote: note) {
        case .kick: 0.48
        case .snare: 0.88
        case .closedHat, .openHat: 0.58
        case .tom: 0.94
        case .cymbal: 0.38
        case .percussion: 0.72
        case .universal: 0.62
        }
    }

    private func nextPatternPoint(
        for settings: PadConfiguration,
        atOrAfter beat: Double,
        eventIndex: Int,
        note: Int
    ) -> (beat: Double, globalStep: Int, valid: Bool) {
        let pattern = DrumPatternLibrary.pattern(settings.patternID)
        let stepBeats = pattern.stepDivision.beats * configuration.timeScale.intervalMultiplier
        let approximateStep = Int(floor(beat / stepBeats)) - 2
        let searchLimit = max(pattern.lengthSteps * 8, 64)

        for offset in 0..<searchLimit {
            let globalStep = approximateStep + offset
            let straightBeat = Double(globalStep) * stepBeats
            let candidateBeat = swungBeat(straightBeat, settings: settings, automaticDivision: pattern.stepDivision)
            guard candidateBeat >= beat - 0.0000001 else { continue }
            if patternHit(pattern, settings: settings, note: note, globalStep: globalStep) {
                return (candidateBeat, globalStep, true)
            }
        }

        let cycleBeats = max(Double(pattern.lengthSteps) * stepBeats, stepBeats)
        var retryBeat = ceil((beat + 0.000001) / cycleBeats) * cycleBeats
        if retryBeat <= beat + 0.000001 { retryBeat += cycleBeats }
        return (retryBeat, Int(floor(retryBeat / stepBeats)), false)
    }

    private func patternHit(
        _ pattern: DrumPatternDefinition,
        settings: PadConfiguration,
        note: Int,
        globalStep: Int
    ) -> Bool {
        let step = positiveModulo(globalStep, pattern.lengthSteps)
        let cycle = Int(floor(Double(globalStep) / Double(pattern.lengthSteps)))
        let bit = UInt64(1) << UInt64(step)
        let fluctuationWave = sin(Double(cycle &+ settings.patternSeed) * 0.754877666 + Double(note) * 0.173)
        let complexity = min(max(settings.patternComplexity + fluctuationWave * settings.patternFluctuation * 0.5, 0), 1)

        var hit = pattern.coreMask & bit != 0
        if pattern.detailMask & bit != 0,
           patternRandomUnit(note: note, globalStep: globalStep, seed: settings.patternSeed, salt: 11) <= complexity {
            hit = true
        }
        if pattern.variationMask & bit != 0,
           patternRandomUnit(note: note, globalStep: globalStep, seed: settings.patternSeed, salt: 23) < min(max(settings.patternVariation, 0), 1) {
            hit.toggle()
        }
        let fillActive = patternRandomUnit(note: note, globalStep: cycle, seed: settings.patternSeed, salt: 37)
            < min(max(settings.patternAutoFill, 0), 1)
        if fillActive, pattern.fillMask & bit != 0 { hit = true }
        guard hit else { return false }
        return patternRandomUnit(note: note, globalStep: globalStep, seed: settings.patternSeed, salt: 53)
            <= min(max(settings.patternProbability, 0), 1)
    }

    private func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        guard divisor > 0 else { return 0 }
        let remainder = value % divisor
        return remainder < 0 ? remainder + divisor : remainder
    }

    private func patternRandomUnit(note: Int, globalStep: Int, seed: Int, salt: Int) -> Double {
        var value = UInt64(bitPattern: Int64(note &* 48_271 &+ globalStep &* 6_969 &+ seed &* 1_013 &+ salt &* 65_537))
        value ^= value >> 12
        value ^= value << 25
        value ^= value >> 27
        return Double((value &* 2_685_821_657_736_338_717) >> 11) / Double(UInt64(1) << 53)
    }

    private func swungBeat(
        _ straightBeat: Double,
        settings: PadConfiguration,
        automaticDivision: RepeatDivision
    ) -> Double {
        let unit = settings.swingDivision.resolved(automaticDivision: automaticDivision).beats
            * configuration.timeScale.intervalMultiplier
        let position = straightBeat / unit
        let index = Int(position.rounded())
        guard abs(position - Double(index)) < 0.0000001, !index.isMultiple(of: 2) else { return straightBeat }
        let pairIndex = Int(floor(Double(index) / 2.0))
        let pairStart = Double(pairIndex * 2) * unit
        return pairStart + unit * 2 * resolvedSwing(settings, movement: 0) / 100
    }

    private func timingHumanizedBeat(
        _ beat: Double,
        settings: PadConfiguration,
        note: Int,
        eventIndex: Int
    ) -> Double {
        guard configuration.timingHumanizeEnabled,
              configuration.timingHumanizeMilliseconds > 0 else { return beat }
        let chance = (deterministicRandom(note: note + 5_003, eventIndex: eventIndex) + 1) * 0.5
        guard chance <= min(max(configuration.timingHumanizeProbability, 0), 1) else { return beat }
        let bpm = min(max(configuration.manualBPM, 30), 300)
        let requestedBeats = configuration.timingHumanizeMilliseconds / 1_000 * bpm / 60
        let interval: Double
        if settings.playbackMode == .pattern {
            interval = DrumPatternLibrary.pattern(settings.patternID).stepDivision.beats
                * configuration.timeScale.intervalMultiplier
        } else {
            let division = resolvedDivision(settings, movement: 0)
            let fillSteps = min(max(settings.repeatFillSpeedSteps, 1), 2)
            let fastest = settings.repeatFillEnabled
                ? division.moved(by: fillSteps, path: .sameFeel)
                : division
            interval = fastest.beats * configuration.timeScale.intervalMultiplier
        }
        let maximum = min(requestedBeats, interval * 0.4)
        let movement = min(max(
            deterministicRandom(note: note + 4_001, eventIndex: eventIndex)
                + configuration.timingHumanizeBias,
            -1
        ), 1)
        return beat + movement * maximum
    }

    private func velocityFor(_ settings: PadConfiguration, source: Int, beat: Double, eventIndex: Int, note: Int) -> Int {
        let base: Int
        let fixedMapping = configuration.liveCC.mapping(.velocity)
        if fixedMapping.enabled {
            base = 1 + Int((Double(ccValues[fixedMapping.ccNumber] ?? 0) / 127 * 126).rounded())
        } else {
            switch settings.velocityMode {
            case .received: base = source
            case .fixed: base = settings.fixedVelocity
            case .humanized: base = source
            }
        }
        var humanize = 0
        let usesHumanize = settings.velocityHumanizeEnabled || settings.velocityMode == .humanized
        let chance = (deterministicRandom(note: note &+ 1_003, eventIndex: eventIndex) + 1) * 0.5
        if usesHumanize, chance <= min(max(settings.humanizeProbability, 0), 1) {
            let random = deterministicRandom(note: note, eventIndex: eventIndex)
            let biased = min(max(random + settings.humanizeBias, -1), 1)
            humanize = Int((biased * Double(settings.humanizeAmount)).rounded())
        }
        return min(max(base + humanize, 1), 127)
    }

    private func resolvedDivision(_ settings: PadConfiguration, movement: Double) -> RepeatDivision {
        var division = settings.division
        let slider = configuration.liveCC.mapping(.divisionDepth)
        if slider.enabled {
            let index = Int((Double(ccValues[slider.ccNumber] ?? 0) / 127 * 9).rounded())
            division = RepeatDivision(rawValue: min(max(index, 0), 9)) ?? division
        }
        let evenMovement = (momentaryActive(.straightUp1) ? 1 : 0)
            - (momentaryActive(.straightDown1) ? 1 : 0)
        let oddMovement = (momentaryActive(.tripletUp1) ? 1 : 0)
            - (momentaryActive(.tripletDown1) ? 1 : 0)
        if evenMovement != 0 { division = division.moved(toTripletFamily: false, direction: evenMovement) }
        if oddMovement != 0 { division = division.moved(toTripletFamily: true, direction: oddMovement) }
        return division
    }

    private func resolvedSwing(_ settings: PadConfiguration, movement: Double) -> Double {
        if let mapped = mappedSwing() { return 50 + mapped * 25 }
        return min(max(settings.swingPercent + movement * 12.5, 50), 75)
    }

    private func mappedSwing() -> Double? {
        let mapping = configuration.liveCC.mapping(.swing)
        guard mapping.enabled else { return nil }
        return Double(ccValues[mapping.ccNumber] ?? 0) / 127
    }

    private func momentaryActive(_ action: MomentaryCCAction) -> Bool {
        let mapping = configuration.liveCC.momentaryMapping(action)
        return mapping.enabled && (ccValues[mapping.ccNumber] ?? 0) > 0
    }

    private mutating func regridDivisionCC(at beat: Double, cc: Int) {
        let allowed: [MomentaryCCAction] = [.straightUp1, .straightDown1, .tripletUp1, .tripletDown1]
        let slider = configuration.liveCC.mapping(.divisionDepth)
        guard slider.enabled && slider.ccNumber == cc || allowed.contains(where: {
            let mapping = configuration.liveCC.momentaryMapping($0)
            return mapping.enabled && mapping.ccNumber == cc
        }) else { return }

        for note in held.keys.sorted() {
            guard var state = held[note] else { continue }
            let settings = configuration.effectivePad(note)
            if settings.playbackMode == .pattern {
                let point = nextPatternPoint(
                    for: settings,
                    atOrAfter: max(beat, state.earliestRepeatBeat),
                    eventIndex: state.repeatIndex,
                    note: note
                )
                state.nextBeat = point.beat
                state.patternGlobalStep = point.globalStep
                state.patternPointValid = point.valid
                state.isSwungSide = point.globalStep % 2 != 0
            } else {
                let grid = nextGridPoint(
                    for: settings,
                    atOrAfter: max(beat, state.earliestRepeatBeat),
                    eventIndex: state.repeatIndex,
                    note: note
                )
                state.nextBeat = grid.beat
                state.isSwungSide = grid.isSwungSide
            }
            held[note] = state
        }
    }

    private func deterministicRandom(note: Int, eventIndex: Int) -> Double {
        var x = UInt64(bitPattern: Int64(note &* 48_271 &+ eventIndex &* 6_969))
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        return Double(x % 20_001) / 10_000 - 1
    }
}
