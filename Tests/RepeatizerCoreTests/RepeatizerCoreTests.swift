import Foundation
import Testing
@testable import RepeatizerCore

@Suite("Repeatizer rhythm engine")
struct RepeatizerCoreTests {
    @Test("The clean-slate plugin preset starts in project-sync Master mode")
    func freshPluginDefaults() {
        let configuration = RepeatizerPresets.gmStandard.configuration
        #expect(configuration.settingsMode == .master)
        #expect(configuration.tempoMode == .hostSync)
        #expect(RepeatizerPresets.boomBapPocket.configuration.settingsMode == .individual)
    }

    @Test("Held notes repeat at their configured division")
    func repeatsHeldNote() {
        var engine = RepeatEngine(configuration: .init(pads: [42: .init(division: .sixteenth)]))
        let events = engine.process([.init(.noteOn, note: 42, velocity: 100, beat: 0)], from: 0, to: 0.75)
        let notes = events.filter { $0.kind == .noteOn }
        #expect(notes.map(\.beat) == [0, 0.25, 0.5, 0.75])
    }

    @Test("Generated notes hold for the active repeat division")
    func repeatGateFollowsDivision() {
        var engine = RepeatEngine(configuration: .init(pads: [60: .init(division: .eighth)]))
        let events = engine.process([.init(.noteOn, note: 60, velocity: 100, beat: 0)], from: 0, to: 1)
        let noteEvents = events.filter { $0.note == 60 }

        #expect(noteEvents.map(\.kind) == [.noteOn, .noteOff, .noteOn, .noteOff, .noteOn])
        #expect(noteEvents.map(\.beat) == [0, 0.5, 0.5, 1, 1])
    }

    @Test("Instrument mode arpeggiates held chord notes in ascending order")
    func instrumentArpeggiatesHeldChord() {
        let settings = InstrumentPerformanceSettings(
            playbackMode: .arpeggioUp,
            style: .straight,
            octaveRange: 0
        )
        var engine = RepeatEngine(configuration: .init(
            performanceSurface: .instrument,
            instrumentSettings: settings,
            masterSettings: .init(division: .eighth)
        ))
        let events = engine.process([
            .init(.noteOn, note: 60, velocity: 100, channel: 0, beat: 0),
            .init(.noteOn, note: 64, velocity: 100, channel: 0, beat: 0),
            .init(.noteOn, note: 67, velocity: 100, channel: 0, beat: 0)
        ], from: 0, to: 1.1)

        #expect(events.filter { $0.kind == .noteOn }.map(\.note) == [60, 64, 67])
        #expect(events.filter { $0.kind == .noteOn }.map(\.beat) == [0, 0.5, 1])
    }

    @Test("Arpeggiators bypass chord rhythm masks and can spread downward")
    func arpeggiatorsBypassChordPatternsAndUseDownOctaves() {
        let settings = InstrumentPerformanceSettings(
            playbackMode: .arpeggioUp,
            style: .house,
            patternVariant: 3,
            octaveRange: -1
        )
        var engine = RepeatEngine(configuration: .init(
            performanceSurface: .instrument,
            instrumentSettings: settings,
            masterSettings: .init(division: .eighth)
        ))
        let events = engine.process([.init(.noteOn, note: 60, velocity: 100, beat: 0)], from: 0, to: 1.1)
        #expect(events.filter { $0.kind == .noteOn }.map(\.note) == [48, 60, 48])
    }

    @Test("Random arpeggiator shuffles a complete voice pass before repeating")
    func randomArpeggiatorMakesCompletePass() {
        let settings = InstrumentPerformanceSettings(playbackMode: .arpeggioRandom, style: .ballad, seed: 73)
        var engine = RepeatEngine(configuration: .init(
            performanceSurface: .instrument,
            instrumentSettings: settings,
            masterSettings: .init(division: .eighth)
        ))
        let events = engine.process([
            .init(.noteOn, note: 60, velocity: 100, beat: 0),
            .init(.noteOn, note: 64, velocity: 100, beat: 0),
            .init(.noteOn, note: 67, velocity: 100, beat: 0)
        ], from: 0, to: 1.1)
        let notes = events.filter { $0.kind == .noteOn }.map(\.note)
        #expect(Set(notes) == Set([60, 64, 67]))
        #expect(notes.count == 3)
    }

    @Test("Instrument chord mode emits every held note together")
    func instrumentRepeatsHeldChord() {
        var engine = RepeatEngine(configuration: .init(
            performanceSurface: .instrument,
            masterSettings: .init(division: .quarter)
        ))
        let events = engine.process([
            .init(.noteOn, note: 60, velocity: 100, channel: 0, beat: 0),
            .init(.noteOn, note: 64, velocity: 100, channel: 0, beat: 0),
            .init(.noteOn, note: 67, velocity: 100, channel: 0, beat: 0)
        ], from: 0, to: 0)

        #expect(events.filter { $0.kind == .noteOn }.map(\.note) == [60, 64, 67])
    }

    @Test("Instrument genre patterns expose distinct rhythm variations")
    func instrumentPatternVariantsDiffer() {
        func noteBeats(patternVariant: Int) -> [Double] {
            let instrument = InstrumentPerformanceSettings(style: .house, patternVariant: patternVariant)
            var engine = RepeatEngine(configuration: .init(
                performanceSurface: .instrument,
                instrumentSettings: instrument,
                masterSettings: .init(division: .eighth)
            ))
            return engine.process([.init(.noteOn, note: 60, velocity: 100, channel: 0, beat: 0)], from: 0, to: 4.1)
                .filter { $0.kind == .noteOn }
                .map(\.beat)
        }

        #expect(noteBeats(patternVariant: 0) == [0, 2, 4])
        #expect(noteBeats(patternVariant: 1) == [1, 3])
    }

    @Test("Live chord patterns move to related rhythms after each phrase")
    func liveChordPatternsMove() {
        func beats(live: Bool) -> [Double] {
            let instrument = InstrumentPerformanceSettings(
                style: .house,
                patternVariant: 0,
                livePatternEnabled: live,
                livePatternPhraseLength: 1,
                seed: 19
            )
            var engine = RepeatEngine(configuration: .init(
                performanceSurface: .instrument,
                instrumentSettings: instrument,
                masterSettings: .init(division: .sixteenth)
            ))
            return engine.process([.init(.noteOn, note: 60, velocity: 100, beat: 0)], from: 0, to: 8.1)
                .filter { $0.kind == .noteOn }
                .map(\.beat)
        }

        #expect(beats(live: true) != beats(live: false))
    }

    @Test("A released repeat cannot leave an old gate that cuts off a retrigger")
    func releaseClearsScheduledGate() {
        var engine = RepeatEngine(configuration: .init(pads: [60: .init(division: .half)]))
        let events = engine.process([
            .init(.noteOn, note: 60, velocity: 100, beat: 0),
            .init(.noteOff, note: 60, beat: 0.2),
            .init(.noteOn, note: 60, velocity: 100, beat: 0.3)
        ], from: 0, to: 2.2)

        #expect(!events.contains { $0.kind == .noteOff && abs($0.beat - 2) < 0.000_001 })
    }

    @Test("The global time scale switches every repeat lane between half, normal, and double time")
    func globalTimeScale() {
        let pad = PadConfiguration(division: .sixteenth)
        let expected: [(GlobalTimeScale, [Double])] = [
            (.half, [0, 0.5, 1]),
            (.normal, [0, 0.25, 0.5, 0.75, 1]),
            (.double, [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1])
        ]

        for (scale, beats) in expected {
            var engine = RepeatEngine(configuration: .init(timeScale: scale, pads: [42: pad]))
            let events = engine.process([.init(.noteOn, note: 42, velocity: 100, beat: 0)], from: 0, to: 1)
            #expect(events.filter { $0.kind == .noteOn }.map(\.beat) == beats)
        }
    }

    @Test("An input note-off stops later repeats")
    func stopsOnRelease() {
        var engine = RepeatEngine(configuration: .init(pads: [42: .init(division: .sixteenth)]))
        let events = engine.process([
            .init(.noteOn, note: 42, velocity: 100, beat: 0),
            .init(.noteOff, note: 42, beat: 0.37)
        ], from: 0, to: 1)
        let notes = events.filter { $0.kind == .noteOn }
        #expect(notes.map(\.beat) == [0, 0.25])
    }

    @Test("A swung second repeat is delayed")
    func appliesSwing() {
        var engine = RepeatEngine(configuration: .init(pads: [42: .init(division: .eighth, swingPercent: 66.6667)]))
        let events = engine.process([.init(.noteOn, note: 42, velocity: 100, beat: 0)], from: 0, to: 1.4)
        let notes = events.filter { $0.kind == .noteOn }
        #expect(notes[1].beat == 0.666667)
    }

    @Test("An off-grid press waits for the next programmed division")
    func quantizesFirstHit() {
        var engine = RepeatEngine(configuration: .init(pads: [42: .init(division: .sixteenth)]))
        let events = engine.process([.init(.noteOn, note: 42, velocity: 100, beat: 0.10)], from: 0, to: 0.60)
        let notes = events.filter { $0.kind == .noteOn }
        #expect(notes.map(\.beat) == [0.25, 0.5])
    }

    @Test("Releasing before the next grid point produces no audible hit")
    func suppressesEarlyRelease() {
        var engine = RepeatEngine(configuration: .init(captureShortTaps: false, pads: [42: .init(division: .sixteenth)]))
        let events = engine.process([
            .init(.noteOn, note: 42, velocity: 100, beat: 0.10),
            .init(.noteOff, note: 42, beat: 0.20)
        ], from: 0, to: 0.60)
        #expect(events.filter { $0.kind == .noteOn }.isEmpty)
    }

    @Test("Capture Short Taps preserves one quantized hit")
    func capturesEarlyRelease() {
        var engine = RepeatEngine(configuration: .init(captureShortTaps: true, pads: [42: .init(division: .sixteenth)]))
        let events = engine.process([
            .init(.noteOn, note: 42, velocity: 1, beat: 0.10),
            .init(.noteOff, note: 42, beat: 0.20)
        ], from: 0, to: 0.80)
        let notes = events.filter { $0.kind == .noteOn }
        #expect(notes.map(\.beat) == [0.25])
        #expect(notes.map(\.velocity) == [1])
    }

    @Test("Tap Live passes the performed hit and resumes on-grid after its selected pause")
    func tapLiveUsesSelectableBuffer() {
        let pad = PadConfiguration(
            division: .sixteenth,
            velocityMode: .fixed,
            fixedVelocity: 100
        )
        var sixteenthPause = RepeatEngine(configuration: .init(
            captureShortTaps: true,
            tapLive: true,
            tapLiveBuffer: .sixteenth,
            pads: [42: pad]
        ))
        let sixteenthEvents = sixteenthPause.process([
            .init(.noteOn, note: 42, velocity: 37, beat: 0.10),
            .init(.noteOff, note: 42, beat: 0.80)
        ], from: 0, to: 1)
        let sixteenthNotes = sixteenthEvents.filter { $0.kind == .noteOn }
        #expect(sixteenthNotes.map(\.beat) == [0.10, 0.50, 0.75])
        #expect(sixteenthNotes.map(\.velocity) == [37, 100, 100])

        var eighthPause = RepeatEngine(configuration: .init(
            tapLive: true,
            tapLiveBuffer: .eighth,
            pads: [42: pad]
        ))
        let eighthEvents = eighthPause.process([
            .init(.noteOn, note: 42, velocity: 37, beat: 0.10),
            .init(.noteOff, note: 42, beat: 0.80)
        ], from: 0, to: 1)
        #expect(eighthEvents.filter { $0.kind == .noteOn }.map(\.beat) == [0.10, 0.75])
    }

    @Test("A short Tap Live press never creates a delayed captured hit")
    func tapLiveShortPressStaysLiveOnly() {
        var engine = RepeatEngine(configuration: .init(
            captureShortTaps: true,
            tapLive: true,
            tapLiveBuffer: .quarter,
            pads: [42: .init(division: .sixteenth)]
        ))
        let events = engine.process([
            .init(.noteOn, note: 42, velocity: 12, beat: 0.10),
            .init(.noteOff, note: 42, beat: 0.20)
        ], from: 0, to: 2)
        let noteOns = events.filter { $0.kind == .noteOn }
        #expect(noteOns.map(\.beat) == [0.10])
        #expect(noteOns.map(\.velocity) == [12])
    }

    @Test("Tap Live quantization, repeat timing, and wait length are independent")
    func tapLiveTimingControlsAreIndependent() {
        var engine = RepeatEngine(configuration: .init(
            tapLive: true,
            tapLiveBuffer: .eighth,
            tapLiveQuantizeMode: .straight,
            tapLiveStraightDivision: .sixteenth,
            pads: [42: .init(division: .sixteenth)]
        ))
        let events = engine.process([
            .init(.noteOn, note: 42, velocity: 91, beat: 0.10),
            .init(.noteOff, note: 42, beat: 1.10)
        ], from: 0, to: 1.25)
        let noteOns = events.filter { $0.kind == .noteOn }
        #expect(noteOns.map(\.beat) == [0.25, 0.75, 1.0])
        #expect(noteOns.first?.velocity == 91)
    }

    @Test("Tap Live Both mode chooses the next future straight or triplet grid point")
    func tapLiveBothGrids() {
        var engine = RepeatEngine(configuration: .init(
            tapLive: true,
            tapLiveBuffer: .quarter,
            tapLiveQuantizeMode: .both,
            tapLiveStraightDivision: .eighth,
            tapLiveTripletDivision: .eighthTriplet,
            pads: [42: .init(division: .sixteenth)]
        ))
        let events = engine.process([
            .init(.noteOn, note: 42, velocity: 80, beat: 0.10),
            .init(.noteOff, note: 42, beat: 0.20)
        ], from: 0, to: 1)
        let noteOns = events.filter { $0.kind == .noteOn }
        #expect(noteOns.count == 1)
        #expect(abs((noteOns.first?.beat ?? 0) - 1.0 / 3.0) < 0.000001)
    }

    @Test("Tap Live gives Pattern mode the same protected pause before project-grid playback")
    func tapLiveBuffersPatternPlayback() {
        let id = DrumPatternLibrary.patternID(style: .foundation, role: .kick, variant: 0)
        let pad = PadConfiguration(
            playbackMode: .pattern,
            patternID: id,
            patternVariation: 0,
            patternAutoFill: 0,
            patternFluctuation: 0,
            patternProbability: 1,
            patternComplexity: 1
        )
        var engine = RepeatEngine(configuration: .init(
            tapLive: true,
            tapLiveBuffer: .quarter,
            pads: [36: pad]
        ))
        let events = engine.process([
            .init(.noteOn, note: 36, velocity: 45, beat: 0.10),
            .init(.noteOff, note: 36, beat: 3.90)
        ], from: 0, to: 4)
        let noteOns = events.filter { $0.kind == .noteOn }
        #expect(noteOns.first?.beat == 0.10)
        #expect(noteOns.first?.velocity == 45)
        #expect(noteOns.count > 1)
        #expect(noteOns.dropFirst().allSatisfy { $0.beat >= 1.10 })
    }

    @Test("Master mode overrides every pad without replacing individual settings")
    func masterModeIsNonDestructive() {
        var configuration = RepeatizerConfiguration(
            settingsMode: .individual,
            masterSettings: .init(division: .eighth, swingPercent: 61),
            pads: [
                36: .init(division: .quarter, swingPercent: 52),
                42: .init(division: .sixteenthTriplet, swingPercent: 67)
            ]
        )
        #expect(configuration.effectivePad(36).division == .quarter)
        #expect(configuration.effectivePad(42).division == .sixteenthTriplet)

        configuration.settingsMode = .master
        #expect(configuration.effectivePad(36).division == .eighth)
        #expect(configuration.effectivePad(42).swingPercent == 61)

        configuration.updateActivePad(36) { $0.division = .thirtySecond }
        #expect(configuration.effectivePad(42).division == .thirtySecond)

        configuration.settingsMode = .individual
        #expect(configuration.effectivePad(36).division == .quarter)
        #expect(configuration.effectivePad(42).division == .sixteenthTriplet)
        #expect(configuration.pad(42).swingPercent == 67)
    }

    @Test("Followers copy master edits and retain them after unlinking")
    func masterFollowerCopy() {
        var configuration = RepeatizerConfiguration(pads: [42: .init(), 44: .init()])
        configuration.setMaster(42)
        configuration.setFollower(44, follows: true)
        configuration.updatePad(42) { $0.swingPercent = 64 }
        #expect(configuration.pad(44).swingPercent == 64)
        configuration.setFollower(44, follows: false)
        configuration.updatePad(42) { $0.swingPercent = 52 }
        #expect(configuration.pad(44).swingPercent == 64)
    }

    @Test("Same Feel division movement skips the opposite rhythmic family")
    func divisionMovementFamilies() {
        #expect(RepeatDivision.sixteenth.moved(by: 1, path: .sameFeel) == .thirtySecond)
        #expect(RepeatDivision.sixteenth.moved(by: -1, path: .sameFeel) == .eighth)
        #expect(RepeatDivision.sixteenthTriplet.moved(by: 1, path: .sameFeel) == .thirtySecondTriplet)
        #expect(RepeatDivision.sixteenthTriplet.moved(by: -1, path: .sameFeel) == .eighthTriplet)
        #expect(RepeatDivision.sixteenth.moved(by: 1, path: .allDivisions) == .sixteenthTriplet)
    }

    @Test("Older saved pads default to Same Feel movement")
    func decodesLegacyDivisionPath() throws {
        let json = #"{"division":5,"swingPercent":50,"velocityMode":"Received","fixedVelocity":100,"humanizeAmount":10,"divisionModulator":{"mode":"Off","rate":0.5,"depth":1,"direction":"Both"},"swingModulator":{"mode":"Off","rate":0.5,"depth":1,"direction":"Both"},"velocityModulator":{"mode":"Off","rate":0.5,"depth":1,"direction":"Both"}}"#
        let pad = try JSONDecoder().decode(PadConfiguration.self, from: Data(json.utf8))
        #expect(pad.divisionModulationPath == .sameFeel)
        #expect(pad.swingModulator.clock == .sync)
        #expect(pad.swingModulator.shape == .sine)
    }

    @Test("A moving swing LFO never emits a duplicate grid hit")
    func swingLFODoesNotDuplicateHits() {
        let pad = PadConfiguration(
            division: .sixteenth,
            swingPercent: 62,
            swingModulator: Modulator(mode: .lfo, rate: 0.73, depth: 2, direction: .both)
        )
        var engine = RepeatEngine(configuration: .init(pads: [42: pad]))
        let events = engine.process([.init(.noteOn, note: 42, velocity: 100, beat: 0)], from: 0, to: 4)
        let beats = events.filter { $0.kind == .noteOn }.map(\.beat)
        let spacings = zip(beats.dropFirst(), beats).map { $0.0 - $0.1 }
        #expect(spacings.allSatisfy { $0 >= 0.124 })
    }

    @Test("Synced and free LFO clocks use musical beats and seconds respectively")
    func lfoClockModes() {
        let synced = Modulator(mode: .lfo, rate: 0.25, clock: .sync)
        let free = Modulator(mode: .lfo, rate: 0.25, clock: .free)
        #expect(abs(synced.value(at: 1, bpm: 120, eventIndex: 0, seed: 1) - 1) < 0.0001)
        #expect(abs(free.value(at: 2, bpm: 120, eventIndex: 0, seed: 1) - 1) < 0.0001)
    }

    @Test("Square and on-off LFO shapes switch at the configured width")
    func steppedLFOShapes() {
        let square = Modulator(mode: .lfo, rate: 1, shape: .square, symmetry: 0.25)
        let gate = Modulator(mode: .lfo, rate: 1, shape: .gate, symmetry: 0.25)
        #expect(square.value(at: 0.1, eventIndex: 0, seed: 1) == 1)
        #expect(square.value(at: 0.4, eventIndex: 0, seed: 1) == -1)
        #expect(gate.value(at: 0.1, eventIndex: 0, seed: 1) == 1)
        #expect(gate.value(at: 0.4, eventIndex: 0, seed: 1) == 0)
    }

    @Test("All visible pads can follow and unfollow the master in one operation")
    func allPadFollowerToggle() {
        var configuration = RepeatizerConfiguration(pads: [36: .init(), 38: .init(), 42: .init()])
        configuration.setMaster(36)
        configuration.setAllVisiblePadsFollowing(true)
        #expect(configuration.followerNotes == [38, 42])
        configuration.setAllVisiblePadsFollowing(false)
        #expect(configuration.followerNotes.isEmpty)
    }

    @Test("Generated repeats are individual recordable MIDI note events")
    func generatedMIDIEventsAreDiscrete() {
        var engine = RepeatEngine(configuration: .init(pads: [36: .init(division: .sixteenth)]))
        let events = engine.process([
            .init(.noteOn, note: 36, velocity: 110, beat: 0),
            .init(.noteOff, note: 36, beat: 0.6)
        ], from: 0, to: 0.75)
        #expect(events.filter { $0.kind == .noteOn }.map(\.beat) == [0, 0.25, 0.5])
        #expect(events.filter { $0.kind == .noteOff }.count >= 3)
    }

    @Test("Probability position can favor waveform peaks or dips")
    func probabilityPositionBias() {
        let peaks = Modulator(mode: .probability, rate: 1, probabilityBias: 1)
        let dips = Modulator(mode: .probability, rate: 1, probabilityBias: -1)
        for beat in stride(from: 0.0, through: 8.0, by: 1.0) {
            let peakPosition = peaks.playheadPosition(at: beat, seed: 42)
            let dipPosition = dips.playheadPosition(at: beat, seed: 42)
            #expect(peaks.displayWaveValue(at: peakPosition) >= 0)
            #expect(dips.displayWaveValue(at: dipPosition) <= 0)
        }
    }

    @Test("A drawn waveform is saved and used as the LFO shape")
    func customWaveform() throws {
        let points = (0..<Modulator.customPointCount).map { $0 < 8 ? 1.0 : -1.0 }
        let modulator = Modulator(mode: .lfo, rate: 1, shape: .custom, customPoints: points)
        #expect(modulator.displayWaveValue(at: 0.1) == 1)
        #expect(modulator.displayWaveValue(at: 0.6) == -1)
        let restored = try JSONDecoder().decode(Modulator.self, from: JSONEncoder().encode(modulator))
        #expect(restored.customPoints == points)
    }

    @Test("A fixed velocity can remain locked while humanization is enabled")
    func fixedVelocityWithHumanize() {
        let pad = PadConfiguration(
            division: .sixteenth,
            velocityMode: .fixed,
            fixedVelocity: 100,
            humanizeAmount: 20,
            velocityHumanizeEnabled: true,
            humanizeProbability: 1
        )
        var engine = RepeatEngine(configuration: .init(pads: [36: pad]))
        let velocities = engine.process([.init(.noteOn, note: 36, velocity: 30, beat: 0)], from: 0, to: 2)
            .filter { $0.kind == .noteOn }.map(\.velocity)
        #expect(Set(velocities).count > 1)
        #expect(velocities.allSatisfy { (80...120).contains($0) })
    }

    @Test("Only the retained division CC responds while legacy drum gestures stay inert")
    func retainedDivisionCCAndInertGestures() {
        var liveCC = LiveCCConfiguration()
        liveCC.updateMomentaryMapping(.straightUp1) {
            $0 = .init(enabled: true, ccNumber: 64)
        }
        var gestures = DrumGestureConfiguration(rate: .sixteenth, lengthSteps: 8, intensity: 1)
        gestures.updateMapping(.diddle) {
            $0 = .init(enabled: true, ccNumber: 20)
        }
        var engine = RepeatEngine(configuration: .init(
            drumGestures: gestures,
            pads: [38: .init(division: .sixteenth)],
            liveCC: liveCC
        ))
        let events = engine.process([
            .init(.controlChange, note: 20, velocity: 1, beat: 0),
            .init(.noteOn, note: 38, velocity: 100, beat: 0),
            .init(.controlChange, note: 64, velocity: 127, beat: 0.30),
            .init(.controlChange, note: 20, velocity: 0, beat: 0.30),
            .init(.controlChange, note: 64, velocity: 0, beat: 0.46)
        ], from: 0, to: 0.75)
        let notes = events.filter { $0.kind == .noteOn }
        #expect(notes.map(\.beat) == [0, 0.25, 0.375, 0.5, 0.75])
        #expect(notes.map(\.velocity) == [100, 100, 100, 100, 100])
    }

    @Test("All four retained division CC mappings re-grid held notes")
    func allRetainedDivisionCCMappings() {
        let cases: [(MomentaryCCAction, RepeatDivision, Double, Double)] = [
            (.straightUp1, .sixteenth, 0.10, 0.125),
            (.straightDown1, .sixteenth, 0.10, 0.50),
            (.tripletUp1, .sixteenth, 0.10, 1.0 / 6.0),
            (.tripletDown1, .sixteenth, 0.10, 1.0 / 3.0)
        ]
        for (action, division, ccBeat, expectedNextBeat) in cases {
            var liveCC = LiveCCConfiguration()
            liveCC.updateMomentaryMapping(action) {
                $0 = .init(enabled: true, ccNumber: 71)
            }
            var engine = RepeatEngine(configuration: .init(
                pads: [42: .init(division: division)],
                liveCC: liveCC
            ))
            let events = engine.process([
                .init(.noteOn, note: 42, velocity: 100, beat: 0),
                .init(.controlChange, note: 71, velocity: 127, beat: ccBeat)
            ], from: 0, to: 0.75)
            let noteOns = events.filter { $0.kind == .noteOn }
            #expect(noteOns.count >= 2)
            let firstAfterCC = noteOns.first { $0.beat >= ccBeat - 0.000001 }
            #expect(abs((firstAfterCC?.beat ?? -1) - expectedNextBeat) < 0.000001)
        }
    }

    @Test("The retained swing CC maps continuously from straight to maximum swing")
    func retainedSwingCC() {
        var liveCC = LiveCCConfiguration()
        liveCC.updateMapping(.swing) { $0 = .init(enabled: true, ccNumber: 12) }
        var engine = RepeatEngine(configuration: .init(
            pads: [42: .init(division: .eighth, swingPercent: 50)], liveCC: liveCC
        ))
        let beats = engine.process([
            .init(.controlChange, note: 12, velocity: 127, beat: 0),
            .init(.noteOn, note: 42, velocity: 100, beat: 0)
        ], from: 0, to: 1).filter { $0.kind == .noteOn }.map(\.beat)
        #expect(beats == [0, 0.75, 1])
    }

    @Test("Legacy global state receives safe defaults for new performance features")
    func legacyGlobalConfigurationDefaults() throws {
        let json = #"{"tempoMode":"Sync","manualBPM":120,"pads":{},"visibleNotes":[],"followerNotes":[],"liveCC":{"divisionBoostEnabled":false,"divisionBoostCC":64,"divisionBoostSteps":1,"divisionBoostPath":"Same Feel","divisionBoostThreshold":64,"mappings":[]}}"#
        let configuration = try JSONDecoder().decode(RepeatizerConfiguration.self, from: Data(json.utf8))
        #expect(configuration.performanceSurface == .drums)
        #expect(configuration.instrumentSettings == .init())
        #expect(configuration.settingsMode == .individual)
        #expect(configuration.captureShortTaps)
        #expect(!configuration.tapLive)
        #expect(configuration.tapLiveBuffer == .quarter)
        #expect(configuration.tapLiveQuantizeMode == .free)
        #expect(configuration.tapLiveStraightDivision == .sixteenth)
        #expect(configuration.tapLiveTripletDivision == .sixteenthTriplet)
        #expect(!configuration.timingHumanizeEnabled)
        #expect(configuration.timingHumanizeMilliseconds == 8)
        #expect(configuration.timingHumanizeProbability == 1)
        #expect(configuration.timingHumanizeBias == 0)
        #expect(configuration.drumGestures.rate == .sixteenth)
        #expect(configuration.liveCC.momentaryMappings.isEmpty)
    }

    @Test("The expanded role-aware pattern library contains unique rhythm definitions")
    func patternLibraryIsLargeAndDistinct() {
        let patterns = DrumPatternLibrary.all
        let expectedCount = DrumPatternStyle.allCases.count
            * DrumPatternRole.allCases.count
            * DrumPatternLibrary.variantCount
        #expect(patterns.count == expectedCount)
        #expect(patterns.count > 9_000)
        #expect(Set(patterns.map(\.id)).count == expectedCount)
        #expect(Set(patterns.map(\.rhythmicSignature)).count == expectedCount)
        for style in DrumPatternStyle.allCases {
            for role in DrumPatternRole.allCases {
                let candidates = DrumPatternLibrary.patterns(for: role, style: style)
                #expect(candidates.count == DrumPatternLibrary.variantCount)
                #expect(Set(candidates.map { "\($0.stepDivision.rawValue):\($0.lengthSteps):\($0.baseMask)" }).count >= 6)
            }
        }
    }

    @Test("On-demand pattern lookup exactly preserves the complete legacy catalog")
    func onDemandPatternsMatchCompleteCatalog() {
        for expected in DrumPatternLibrary.all {
            #expect(DrumPatternLibrary.pattern(expected.id) == expected)
        }
    }

    @Test("Legacy pads remain in repeat mode with safe pattern defaults")
    func legacyPadPatternDefaults() throws {
        let json = #"{"division":5,"swingPercent":50,"velocityMode":"Received","fixedVelocity":100,"humanizeAmount":10,"divisionModulator":{"mode":"Off","rate":0.5,"depth":1,"direction":"Both"},"swingModulator":{"mode":"Off","rate":0.5,"depth":1,"direction":"Both"},"velocityModulator":{"mode":"Off","rate":0.5,"depth":1,"direction":"Both"}}"#
        let pad = try JSONDecoder().decode(PadConfiguration.self, from: Data(json.utf8))
        #expect(pad.playbackMode == .repeatNote)
        #expect(pad.swingDivision == .automatic)
        #expect(pad.patternProbability == 1)
        #expect(pad.patternComplexity == 0.55)
        #expect(!pad.patternLocked)
        #expect(!pad.repeatFillEnabled)
        #expect(pad.repeatFillAmount == 0.35)
        #expect(pad.repeatFillDensity == 0.42)
        #expect(pad.repeatFillProbability == 0.48)
        #expect(pad.repeatFillEveryBars == 2)
        #expect(pad.repeatFillSpeedSteps == 1)
        #expect(pad.repeatFillBalance == 0.65)
    }

    @Test("Master timing humanize stays bounded and never changes the repeat count")
    func masterTimingHumanizeIsBounded() {
        let configuration = RepeatizerConfiguration(
            timingHumanizeEnabled: true,
            timingHumanizeMilliseconds: 30,
            pads: [42: .init(division: .sixteenth)]
        )
        var engine = RepeatEngine(configuration: configuration)
        let beats = engine.process([
            .init(.noteOn, note: 42, velocity: 100, beat: 0)
        ], from: 0, to: 1.12).filter { $0.kind == .noteOn }.map(\.beat)
        #expect(beats.count == 5)
        for (index, beat) in beats.enumerated() {
            #expect(abs(beat - Double(index) * 0.25) <= 0.061)
        }
    }

    @Test("Timing humanize probability and early-late bias are independent master controls")
    func timingHumanizeProbabilityAndBias() {
        var disabledByProbability = RepeatEngine(configuration: .init(
            timingHumanizeEnabled: true,
            timingHumanizeMilliseconds: 30,
            timingHumanizeProbability: 0,
            timingHumanizeBias: 1,
            pads: [42: .init(division: .eighth)]
        ))
        let exact = disabledByProbability.process([
            .init(.noteOn, note: 42, velocity: 100, beat: 0)
        ], from: 0, to: 1).filter { $0.kind == .noteOn }.map(\.beat)
        #expect(exact == [0, 0.5, 1])

        var lateBiased = RepeatEngine(configuration: .init(
            timingHumanizeEnabled: true,
            timingHumanizeMilliseconds: 30,
            timingHumanizeProbability: 1,
            timingHumanizeBias: 1,
            pads: [42: .init(division: .eighth)]
        ))
        let late = lateBiased.process([
            .init(.noteOn, note: 42, velocity: 100, beat: 0)
        ], from: 0, to: 1.1).filter { $0.kind == .noteOn }.map(\.beat)
        #expect(late.count == 3)
        #expect(late.enumerated().allSatisfy { index, beat in beat >= Double(index) * 0.5 })
        #expect(late.enumerated().contains { index, beat in beat > Double(index) * 0.5 + 0.000001 })
    }

    @Test("Smart repeat fills preserve the base grid and add phrase-ending detail")
    func smartRepeatFillsPreserveBaseGrid() {
        var engine = RepeatEngine(configuration: .init(pads: [42: .init(
            division: .eighth,
            repeatFillEnabled: true,
            repeatFillAmount: 1,
            repeatFillDensity: 1,
            repeatFillProbability: 1,
            repeatFillEveryBars: 1,
            repeatFillSpeedSteps: 2,
            repeatFillBalance: 0
        )]))
        let beats = engine.process([
            .init(.noteOn, note: 42, velocity: 100, beat: 0)
        ], from: 0, to: 4).filter { $0.kind == .noteOn }.map(\.beat)
        let base = stride(from: 0.0, through: 4.0, by: 0.5)
        #expect(base.allSatisfy { expected in beats.contains { abs($0 - expected) < 0.000001 } })
        #expect(beats.count > 9)
        #expect(beats.contains { $0 > 3 && abs(($0 * 2).rounded() - $0 * 2) > 0.000001 })
    }

    @Test("The continuous division CC scrolls the full repeat-division list")
    func continuousDivisionCC() {
        var liveCC = LiveCCConfiguration()
        liveCC.updateMapping(.divisionDepth) { $0 = .init(enabled: true, ccNumber: 14) }
        var engine = RepeatEngine(configuration: .init(
            pads: [42: .init(division: .quarter)], liveCC: liveCC
        ))
        let beats = engine.process([
            .init(.controlChange, note: 14, velocity: 127, beat: 0),
            .init(.noteOn, note: 42, velocity: 100, beat: 0.01)
        ], from: 0, to: 0.14).filter { $0.kind == .noteOn }.map(\.beat)
        #expect(beats == [0.0625, 0.125])
    }

    @Test("The fixed-velocity CC locks velocity while preserving velocity humanize afterward")
    func fixedVelocityCC() {
        var liveCC = LiveCCConfiguration()
        liveCC.updateMapping(.velocity) { $0 = .init(enabled: true, ccNumber: 15) }
        var engine = RepeatEngine(configuration: .init(
            pads: [42: .init(division: .eighth, velocityHumanizeEnabled: false)],
            liveCC: liveCC
        ))
        let velocities = engine.process([
            .init(.controlChange, note: 15, velocity: 64, beat: 0),
            .init(.noteOn, note: 42, velocity: 10, beat: 0)
        ], from: 0, to: 1).filter { $0.kind == .noteOn }.map(\.velocity)
        #expect(!velocities.isEmpty)
        #expect(velocities.allSatisfy { $0 == 64 })
    }

    @Test("Master pattern controls preserve a role-appropriate lane for each drum")
    func masterPatternsPreserveDrumRoles() {
        let configuration = RepeatizerConfiguration(
            settingsMode: .master,
            masterSettings: .init(playbackMode: .pattern),
            pads: [36: .init(), 38: .init(), 42: .init()]
        )
        #expect(DrumPatternLibrary.pattern(configuration.effectivePad(36).patternID).role == .kick)
        #expect(DrumPatternLibrary.pattern(configuration.effectivePad(38).patternID).role == .snare)
        #expect(DrumPatternLibrary.pattern(configuration.effectivePad(42).patternID).role == .closedHat)
        #expect(configuration.effectivePad(42).playbackMode == .pattern)
    }

    @Test("Pattern lanes stop on release and rejoin the project-position phase")
    func patternPlaybackUsesProjectPhase() {
        let pattern = DrumPatternLibrary.patternID(style: .foundation, role: .kick, variant: 0)
        let pad = PadConfiguration(
            playbackMode: .pattern,
            patternID: pattern,
            patternSeed: 9,
            patternVariation: 0,
            patternAutoFill: 0,
            patternFluctuation: 0,
            patternProbability: 1,
            patternComplexity: 1,
            swingPercent: 50
        )
        var engine = RepeatEngine(configuration: .init(captureShortTaps: true, pads: [36: pad]))
        let events = engine.process([
            .init(.noteOn, note: 36, velocity: 100, beat: 0.10),
            .init(.noteOff, note: 36, beat: 0.61),
            .init(.noteOn, note: 36, velocity: 100, beat: 1.10),
            .init(.noteOff, note: 36, beat: 1.61)
        ], from: 0, to: 2)
        let actual = events.filter { $0.kind == .noteOn }.map(\.beat)
        let definition = DrumPatternLibrary.pattern(pattern)
        let expected = (0..<definition.lengthSteps).compactMap { step -> Double? in
            guard definition.contains(definition.baseMask, step: step) else { return nil }
            let beat = Double(step) * definition.stepDivision.beats
            return ((0.10...0.61).contains(beat) || (1.10...1.61).contains(beat)) ? beat : nil
        }
        #expect(actual == expected)
        #expect(actual.allSatisfy { !(0.61..<1.10).contains($0) })
    }

    @Test("Capture Taps never creates a late hit in Pattern mode")
    func captureTapsDoesNotExtendPatterns() {
        let id = DrumPatternLibrary.patternID(style: .foundation, role: .kick, variant: 0)
        let pad = PadConfiguration(playbackMode: .pattern, patternID: id, patternComplexity: 1)
        var engine = RepeatEngine(configuration: .init(captureShortTaps: true, pads: [36: pad]))
        let events = engine.process([
            .init(.noteOn, note: 36, velocity: 100, beat: 0.10),
            .init(.noteOff, note: 36, beat: 0.11)
        ], from: 0, to: 1)
        #expect(events.filter { $0.kind == .noteOn }.isEmpty)
    }

    @Test("Swing can use an independent grid from the repeat division")
    func independentSwingGrid() {
        let pad = PadConfiguration(
            division: .sixteenth,
            swingDivision: .eighth,
            swingPercent: 66.6667
        )
        var engine = RepeatEngine(configuration: .init(pads: [42: pad]))
        let beats = engine.process([.init(.noteOn, note: 42, velocity: 100, beat: 0)], from: 0, to: 1)
            .filter { $0.kind == .noteOn }
            .map(\.beat)
        #expect(beats == [0, 0.25, 0.666667, 0.75, 1])
    }

    @Test("Legacy modulation data no longer changes repeat timing or velocity")
    func legacyModulationIsDormant() {
        let pad = PadConfiguration(
            division: .sixteenth,
            velocityMode: .fixed,
            fixedVelocity: 100,
            divisionModulator: Modulator(mode: .random, rate: 8, depth: 8, direction: .both),
            swingModulator: Modulator(mode: .lfo, rate: 4, depth: 8, direction: .both),
            velocityModulator: Modulator(mode: .random, rate: 8, depth: 8, direction: .both)
        )
        var engine = RepeatEngine(configuration: .init(pads: [42: pad]))
        let notes = engine.process([.init(.noteOn, note: 42, velocity: 1, beat: 0)], from: 0, to: 0.75)
            .filter { $0.kind == .noteOn }
        #expect(notes.map(\.beat) == [0, 0.25, 0.5, 0.75])
        #expect(notes.map(\.velocity) == [100, 100, 100, 100])
    }
}
