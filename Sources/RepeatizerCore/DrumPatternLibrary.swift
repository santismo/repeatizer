import Foundation

public enum PadPlaybackMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case repeatNote = "Repeat"
    case pattern = "Pattern"

    public var id: String { rawValue }
}

public enum DrumPatternRole: String, CaseIterable, Codable, Sendable, Identifiable {
    case kick = "Kick"
    case snare = "Snare / Clap"
    case closedHat = "Closed Hat"
    case openHat = "Open Hat"
    case tom = "Toms"
    case cymbal = "Cymbals"
    case percussion = "Percussion"
    case universal = "Universal / Custom"

    public var id: String { rawValue }

    fileprivate var shortName: String {
        switch self {
        case .kick: "Kick"
        case .snare: "Snare"
        case .closedHat: "Closed Hat"
        case .openHat: "Open Hat"
        case .tom: "Tom"
        case .cymbal: "Cymbal"
        case .percussion: "Percussion"
        case .universal: "Rudiment"
        }
    }
}

public enum DrumPatternStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case foundation = "Foundation"
    case boomBap = "Boom Bap"
    case neoSoul = "Neo-Soul"
    case funk = "Funk"
    case jazz = "Jazz"
    case house = "House"
    case techno = "Techno"
    case trap = "Trap"
    case drill = "Drill"
    case drumAndBass = "Drum & Bass"
    case breakbeat = "Breakbeat"
    case afro = "Afro"
    case latin = "Latin"
    case reggae = "Reggae / Dub"
    case ambient = "Ambient"
    case experimental = "Experimental"
    case rock = "Rock"
    case indieRock = "Indie Rock"
    case hardRock = "Hard Rock"
    case punk = "Punk"
    case progressiveRock = "Progressive Rock"
    case metal = "Metal"
    case progressiveMetal = "Progressive Metal"
    case bebop = "Bebop"
    case jazzFusion = "Jazz Fusion"
    case latinJazz = "Latin Jazz"
    case edm = "EDM"
    case trance = "Trance"
    case breakcore = "Breakcore"
    case afrobeat = "Afrobeat"
    case westAfrican = "West African"
    case salsa = "Salsa"
    case bossaNova = "Bossa Nova"
    case samba = "Samba"
    case blues = "Blues"
    case gospel = "Gospel"

    public var id: String { rawValue }

    public var compatibleStyles: [DrumPatternStyle] {
        let group: [DrumPatternStyle]
        switch self {
        case .foundation: group = [.foundation, .funk, .rock, .blues]
        case .boomBap, .neoSoul, .trap, .drill: group = [.boomBap, .neoSoul, .trap, .drill, .funk]
        case .funk, .gospel: group = [.funk, .neoSoul, .gospel, .jazzFusion, .blues]
        case .jazz, .bebop, .jazzFusion: group = [.jazz, .bebop, .jazzFusion, .latinJazz, .bossaNova]
        case .latinJazz, .latin, .salsa, .bossaNova, .samba:
            group = [.latinJazz, .latin, .salsa, .bossaNova, .samba]
        case .house, .techno, .edm, .trance: group = [.house, .techno, .edm, .trance]
        case .drumAndBass, .breakbeat, .breakcore: group = [.drumAndBass, .breakbeat, .breakcore]
        case .rock, .indieRock, .hardRock, .punk, .progressiveRock:
            group = [.rock, .indieRock, .hardRock, .punk, .progressiveRock]
        case .metal, .progressiveMetal: group = [.metal, .progressiveMetal, .hardRock, .progressiveRock]
        case .afro, .afrobeat, .westAfrican: group = [.afro, .afrobeat, .westAfrican, .latin]
        case .reggae: group = [.reggae, .afrobeat, .blues]
        case .blues: group = [.blues, .rock, .gospel, .foundation]
        case .ambient, .experimental: group = [.ambient, .experimental, .breakcore]
        }
        return group
    }
}

/// An immutable, role-tagged rhythm lane. Core, detail, variation, and fill
/// masks are separate so the live engine can change complexity without cloning
/// or allocating pattern data on the audio thread.
public struct DrumPatternDefinition: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let style: DrumPatternStyle
    public let role: DrumPatternRole
    public let stepDivision: RepeatDivision
    public let lengthSteps: Int
    public let coreMask: UInt64
    public let detailMask: UInt64
    public let variationMask: UInt64
    public let fillMask: UInt64

    public var menuName: String { "\(style.rawValue) · \(name)" }
    public var lengthBeats: Double { Double(lengthSteps) * stepDivision.beats }
    public var baseMask: UInt64 { coreMask | detailMask }
    public var rhythmicSignature: String {
        "\(stepDivision.rawValue):\(lengthSteps):\(coreMask):\(detailMask):\(variationMask):\(fillMask)"
    }

    public func contains(_ mask: UInt64, step: Int) -> Bool {
        guard lengthSteps > 0 else { return false }
        let normalized = ((step % lengthSteps) + lengthSteps) % lengthSteps
        return mask & (UInt64(1) << UInt64(normalized)) != 0
    }
}

public enum DrumPatternLibrary {
    public static let variantCount = 32
    public static let all: [DrumPatternDefinition] = buildLibrary()

    private static let byID: [Int: DrumPatternDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    private struct CatalogKey: Hashable { let role: DrumPatternRole; let style: DrumPatternStyle }
    private static let byRole = Dictionary(grouping: all, by: \.role)
    private static let byRoleAndStyle = Dictionary(grouping: all) { CatalogKey(role: $0.role, style: $0.style) }

    public static func pattern(_ id: Int) -> DrumPatternDefinition {
        byID[id] ?? all[0]
    }

    public static func patterns(for role: DrumPatternRole, style: DrumPatternStyle? = nil) -> [DrumPatternDefinition] {
        guard let style else { return byRole[role] ?? [] }
        return byRoleAndStyle[CatalogKey(role: role, style: style)] ?? []
    }

    public static func patternID(style: DrumPatternStyle, role: DrumPatternRole, variant: Int) -> Int {
        let styleIndex = DrumPatternStyle.allCases.firstIndex(of: style) ?? 0
        let roleIndex = DrumPatternRole.allCases.firstIndex(of: role) ?? 0
        return styleIndex * DrumPatternRole.allCases.count * variantCount
            + roleIndex * variantCount
            + ((variant % variantCount) + variantCount) % variantCount
    }

    public static func inferredRole(forMIDINote note: Int) -> DrumPatternRole {
        switch note {
        case 35, 36: .kick
        case 37, 38, 39, 40: .snare
        case 42, 44: .closedHat
        case 46: .openHat
        case 41, 43, 45, 47, 48, 50: .tom
        case 49, 51, 52, 53, 55, 57, 59: .cymbal
        case 54, 56, 58, 60...81: .percussion
        default: .universal
        }
    }

    public static func defaultPatternID(forMIDINote note: Int) -> Int {
        patternID(style: .foundation, role: inferredRole(forMIDINote: note), variant: 0)
    }

    private struct VariantSpec {
        let steps: Int
        let division: RepeatDivision
        let title: String
    }

    private struct StyleProfile {
        let energy: Int
        let syncopation: Double
        let detail: Double
        let fill: Int
    }

    private static func profile(for style: DrumPatternStyle) -> StyleProfile {
        switch style {
        case .foundation: .init(energy: 0, syncopation: 0.15, detail: 0.30, fill: 0)
        case .boomBap: .init(energy: 1, syncopation: 0.48, detail: 0.45, fill: 1)
        case .neoSoul: .init(energy: 0, syncopation: 0.62, detail: 0.62, fill: 0)
        case .funk: .init(energy: 2, syncopation: 0.75, detail: 0.72, fill: 2)
        case .jazz, .bebop: .init(energy: 1, syncopation: 0.84, detail: 0.78, fill: 1)
        case .jazzFusion, .latinJazz: .init(energy: 2, syncopation: 0.80, detail: 0.75, fill: 2)
        case .house: .init(energy: 2, syncopation: 0.20, detail: 0.34, fill: 1)
        case .techno: .init(energy: 3, syncopation: 0.26, detail: 0.42, fill: 2)
        case .edm, .trance: .init(energy: 3, syncopation: 0.18, detail: 0.45, fill: 3)
        case .trap, .drill: .init(energy: 4, syncopation: 0.88, detail: 0.76, fill: 3)
        case .drumAndBass: .init(energy: 4, syncopation: 0.82, detail: 0.72, fill: 4)
        case .breakbeat: .init(energy: 3, syncopation: 0.74, detail: 0.68, fill: 3)
        case .breakcore: .init(energy: 6, syncopation: 0.96, detail: 0.92, fill: 6)
        case .afro, .afrobeat, .westAfrican: .init(energy: 2, syncopation: 0.91, detail: 0.82, fill: 2)
        case .latin, .salsa, .samba: .init(energy: 3, syncopation: 0.88, detail: 0.80, fill: 3)
        case .bossaNova: .init(energy: 0, syncopation: 0.72, detail: 0.62, fill: 0)
        case .reggae: .init(energy: 0, syncopation: 0.68, detail: 0.48, fill: 0)
        case .rock, .indieRock: .init(energy: 2, syncopation: 0.34, detail: 0.42, fill: 2)
        case .hardRock, .punk: .init(energy: 4, syncopation: 0.30, detail: 0.54, fill: 4)
        case .progressiveRock: .init(energy: 3, syncopation: 0.72, detail: 0.68, fill: 4)
        case .metal: .init(energy: 5, syncopation: 0.46, detail: 0.68, fill: 5)
        case .progressiveMetal: .init(energy: 5, syncopation: 0.82, detail: 0.82, fill: 6)
        case .blues: .init(energy: 1, syncopation: 0.48, detail: 0.42, fill: 1)
        case .gospel: .init(energy: 3, syncopation: 0.76, detail: 0.72, fill: 3)
        case .ambient: .init(energy: -1, syncopation: 0.40, detail: 0.24, fill: -1)
        case .experimental: .init(energy: 5, syncopation: 0.98, detail: 0.88, fill: 5)
        }
    }

    private static let variantSpecs: [VariantSpec] = [
        .init(steps: 16, division: .sixteenth, title: "Anchor"),
        .init(steps: 32, division: .sixteenth, title: "Two-Bar Pocket"),
        .init(steps: 24, division: .sixteenthTriplet, title: "Triplet Rudiment"),
        .init(steps: 48, division: .sixteenthTriplet, title: "Triplet Journey"),
        .init(steps: 32, division: .thirtySecond, title: "Rudimental Burst"),
        .init(steps: 64, division: .thirtySecond, title: "Extended Rush"),
        .init(steps: 16, division: .sixteenth, title: "Syncopated Turn"),
        .init(steps: 32, division: .sixteenth, title: "Evolving Phrase"),
        .init(steps: 8, division: .eighth, title: "Open Pocket"),
        .init(steps: 16, division: .eighth, title: "Long Pocket"),
        .init(steps: 12, division: .eighthTriplet, title: "Shuffled Pulse"),
        .init(steps: 24, division: .eighthTriplet, title: "Shuffled Journey"),
        .init(steps: 16, division: .thirtySecond, title: "Compact Burst"),
        .init(steps: 24, division: .thirtySecond, title: "Three-Beat Burst"),
        .init(steps: 48, division: .thirtySecond, title: "Six-Beat Rush"),
        .init(steps: 64, division: .sixtyFourth, title: "Micro Roll"),
        .init(steps: 32, division: .sixtyFourth, title: "Micro Pocket"),
        .init(steps: 48, division: .sixtyFourth, title: "Micro Trip"),
        .init(steps: 64, division: .thirtySecondTriplet, title: "Odd Triplet Arc"),
        .init(steps: 48, division: .thirtySecondTriplet, title: "Four-Beat Triplet Roll"),
        .init(steps: 24, division: .thirtySecondTriplet, title: "Two-Beat Triplet Roll"),
        .init(steps: 32, division: .sixteenthTriplet, title: "Five-Beat Triplet Turn"),
        .init(steps: 40, division: .sixteenth, title: "Ten-Beat Cycle"),
        .init(steps: 20, division: .sixteenth, title: "Five-Beat Cycle"),
        .init(steps: 28, division: .sixteenth, title: "Seven-Beat Cycle"),
        .init(steps: 12, division: .sixteenth, title: "Three-Beat Cycle"),
        .init(steps: 36, division: .sixteenth, title: "Nine-Beat Cycle"),
        .init(steps: 56, division: .sixteenth, title: "Fourteen-Beat Cycle"),
        .init(steps: 40, division: .thirtySecond, title: "Five-Beat Rush"),
        .init(steps: 56, division: .thirtySecond, title: "Seven-Beat Rush"),
        .init(steps: 36, division: .sixteenthTriplet, title: "Six-Beat Triplet Cycle"),
        .init(steps: 60, division: .thirtySecondTriplet, title: "Five-Beat Triplet Cycle")
    ]

    private static func buildLibrary() -> [DrumPatternDefinition] {
        var result: [DrumPatternDefinition] = []
        result.reserveCapacity(DrumPatternStyle.allCases.count * DrumPatternRole.allCases.count * variantCount)
        var signatures = Set<String>()

        for (styleIndex, style) in DrumPatternStyle.allCases.enumerated() {
            for (roleIndex, role) in DrumPatternRole.allCases.enumerated() {
                for (variantIndex, spec) in variantSpecs.enumerated() {
                    let id = styleIndex * DrumPatternRole.allCases.count * variantCount
                        + roleIndex * variantCount + variantIndex
                    var generator = SplitMix64(seed: UInt64(id + 1) &* 0x9E3779B97F4A7C15)
                    var masks = makeMasks(
                        style: style,
                        styleIndex: styleIndex,
                        role: role,
                        roleIndex: roleIndex,
                        variantIndex: variantIndex,
                        steps: spec.steps,
                        stepBeats: spec.division.beats,
                        generator: &generator
                    )

                    var signature = signatureFor(spec: spec, masks: masks)
                    var collisionPass = 0
                    while signatures.contains(signature) {
                        let bit = (id &* 17 &+ collisionPass &* 11 &+ 3) % spec.steps
                        masks.detail ^= UInt64(1) << UInt64(bit)
                        if masks.core | masks.detail == 0 { masks.core = 1 }
                        collisionPass += 1
                        signature = signatureFor(spec: spec, masks: masks)
                    }
                    signatures.insert(signature)

                    result.append(DrumPatternDefinition(
                        id: id,
                        name: "\(role.shortName) · \(spec.title) \(styleIndex + 1)-\(variantIndex + 1)",
                        style: style,
                        role: role,
                        stepDivision: spec.division,
                        lengthSteps: spec.steps,
                        coreMask: masks.core,
                        detailMask: masks.detail,
                        variationMask: masks.variation,
                        fillMask: masks.fill
                    ))
                }
            }
        }
        return result
    }

    private static func signatureFor(
        spec: VariantSpec,
        masks: (core: UInt64, detail: UInt64, variation: UInt64, fill: UInt64)
    ) -> String {
        "\(spec.division.rawValue):\(spec.steps):\(masks.core):\(masks.detail):\(masks.variation):\(masks.fill)"
    }

    private static func makeMasks(
        style: DrumPatternStyle,
        styleIndex: Int,
        role: DrumPatternRole,
        roleIndex: Int,
        variantIndex: Int,
        steps: Int,
        stepBeats: Double,
        generator: inout SplitMix64
    ) -> (core: UInt64, detail: UInt64, variation: UInt64, fill: UInt64) {
        let densityBase: [Int] = [4, 4, 10, 4, 5, 3, 7, 8]
        let styleProfile = profile(for: style)
        let styleEnergy = styleProfile.energy
        let scale = Double(steps) / 16.0
        let requestedPulses = Int((Double(max(1, densityBase[roleIndex] + styleEnergy + variantIndex % 3)) * scale).rounded())
        let pulses = min(max(requestedPulses, 1), max(1, steps * 3 / 4))
        let rotation = (styleIndex * 3 + roleIndex * 5 + variantIndex * 7 + Int(styleProfile.syncopation * 11)) % steps
        var base = euclideanMask(pulses: pulses, steps: steps, rotation: rotation)
        var anchors: UInt64 = 0

        let lengthBeats = Double(steps) * stepBeats
        func setBeat(_ beat: Double, in mask: inout UInt64) {
            let wrapped = beat.truncatingRemainder(dividingBy: lengthBeats)
            let step = Int((max(wrapped, 0) / stepBeats).rounded()) % steps
            mask |= UInt64(1) << UInt64(step)
        }
        let bars = max(1, Int((lengthBeats / 4).rounded()))
        for bar in 0..<bars {
            let offset = Double(bar * 4)
            switch role {
            case .kick:
                setBeat(offset, in: &anchors)
                if [.house, .techno, .edm, .trance].contains(style) {
                    for beat in 0..<4 { setBeat(offset + Double(beat), in: &anchors) }
                }
                if [.rock, .indieRock, .hardRock, .punk, .progressiveRock, .metal, .progressiveMetal].contains(style) {
                    setBeat(offset + 2, in: &anchors)
                    if [.metal, .progressiveMetal].contains(style) {
                        setBeat(offset + 0.5, in: &anchors)
                        setBeat(offset + 2.5, in: &anchors)
                    }
                }
            case .snare:
                setBeat(offset + 1, in: &anchors)
                setBeat(offset + 3, in: &anchors)
            case .closedHat:
                for eighth in 0..<8 where eighth.isMultiple(of: style == .ambient ? 2 : 1) {
                    setBeat(offset + Double(eighth) * 0.5, in: &anchors)
                }
            case .openHat:
                for beat in 0..<4 { setBeat(offset + Double(beat) + 0.5, in: &anchors) }
            case .tom:
                setBeat(offset + 2.5, in: &anchors)
                setBeat(offset + 3.5, in: &anchors)
            case .cymbal:
                setBeat(offset, in: &anchors)
                if [.jazz, .bebop, .jazzFusion, .latinJazz].contains(style) {
                    setBeat(offset + 1, in: &anchors)
                    setBeat(offset + 1.5, in: &anchors)
                    setBeat(offset + 2, in: &anchors)
                    setBeat(offset + 3, in: &anchors)
                    setBeat(offset + 3.5, in: &anchors)
                }
            case .percussion:
                setBeat(offset + 0.75, in: &anchors)
                setBeat(offset + 2.25, in: &anchors)
                if [.afro, .afrobeat, .westAfrican, .latin, .latinJazz, .salsa, .samba].contains(style) {
                    setBeat(offset + 1.5, in: &anchors)
                    setBeat(offset + 3.25, in: &anchors)
                }
            case .universal:
                setBeat(offset, in: &anchors)
                setBeat(offset + 1.5, in: &anchors)
                setBeat(offset + 3, in: &anchors)
            }
        }

        if role == .tom || [.drumAndBass, .breakbeat, .breakcore, .metal, .progressiveMetal].contains(style) {
            let tailStart = steps * 3 / 4
            for step in tailStart..<steps where (step + variantIndex).isMultiple(of: max(1, 3 - variantIndex % 2)) {
                base |= UInt64(1) << UInt64(step)
            }
        }

        var core = anchors
        var detail: UInt64 = 0
        for step in 0..<steps {
            let bit = UInt64(1) << UInt64(step)
            guard base & bit != 0, anchors & bit == 0 else { continue }
            if generator.unit() < 0.48 { core |= bit } else { detail |= bit }
        }
        if core == 0 { core = UInt64(1) << UInt64(rotation) }

        let extraDetails = max(2, Int(Double(pulses) * (0.25 + styleProfile.detail * 0.45)))
        for _ in 0..<extraDetails {
            let step = generator.int(steps)
            let bit = UInt64(1) << UInt64(step)
            if core & bit == 0 { detail |= bit }
        }

        var variation: UInt64 = 0
        let variationCount = max(3, Int(Double(steps) * (0.12 + Double((styleIndex + variantIndex) % 5) * 0.025)))
        for _ in 0..<variationCount {
            let step = generator.int(steps)
            if step != 0 { variation |= UInt64(1) << UInt64(step) }
        }

        var fill: UInt64 = 0
        let fillStart = steps * 3 / 4
        let fillPulses = min(max(3 + styleProfile.fill + variantIndex % 4, 2), steps - fillStart)
        let tailPattern = euclideanMask(pulses: fillPulses, steps: steps - fillStart, rotation: variantIndex + roleIndex)
        for localStep in 0..<(steps - fillStart) where tailPattern & (UInt64(1) << UInt64(localStep)) != 0 {
            fill |= UInt64(1) << UInt64(fillStart + localStep)
        }
        return (core, detail, variation, fill)
    }

    private static func euclideanMask(pulses: Int, steps: Int, rotation: Int) -> UInt64 {
        guard pulses > 0, steps > 0 else { return 0 }
        var mask: UInt64 = 0
        for step in 0..<steps {
            let rotated = (step + rotation) % steps
            if (rotated * pulses) % steps < pulses {
                mask |= UInt64(1) << UInt64(step)
            }
        }
        return mask
    }

    private struct SplitMix64 {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }

        mutating func unit() -> Double {
            Double(next() >> 11) / Double(UInt64(1) << 53)
        }

        mutating func int(_ upperBound: Int) -> Int {
            guard upperBound > 0 else { return 0 }
            return Int(next() % UInt64(upperBound))
        }
    }
}
