import AppKit
import AudioToolbox
import AVFoundation
import Foundation

let description = AudioComponentDescription(
    componentType: kAudioUnitType_MIDIProcessor,
    componentSubType: 0x5270747A,
    componentManufacturer: 0x5250545A,
    componentFlags: 0,
    componentFlagsMask: 0
)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

AUAudioUnit.instantiate(with: description, options: [.loadOutOfProcess]) { audioUnit, error in
    guard let audioUnit else {
        print("AU_PATTERN_INSTANTIATION_FAILED: \(error?.localizedDescription ?? "unknown")")
        exit(1)
    }
    guard var state = audioUnit.fullState,
          let data = state["repeatizer.configuration"] as? Data,
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var master = json["masterSettings"] as? [String: Any],
          var pads = json["pads"] as? [String: Any],
          var kick = pads["36"] as? [String: Any] else {
        print("AU_PATTERN_STATE_FAILED")
        exit(1)
    }

    json["settingsMode"] = "Master"
    json["tempoMode"] = "Sync"
    json["captureShortTaps"] = true
    master["playbackMode"] = "Pattern"
    master["patternVariation"] = 0.0
    master["patternAutoFill"] = 0.0
    master["patternFluctuation"] = 0.0
    master["patternProbability"] = 1.0
    master["patternComplexity"] = 1.0
    master["swingPercent"] = 50.0
    kick["patternID"] = 1
    kick["patternSeed"] = 17
    pads["36"] = kick
    json["pads"] = pads
    json["masterSettings"] = master
    state["repeatizer.configuration"] = try! JSONSerialization.data(withJSONObject: json)
    audioUnit.fullState = state

    var noteOnTimes: [AUEventSampleTime] = []
    var hostBeat = 0.0
    audioUnit.hostMIDIProtocol = ._1_0
    audioUnit.midiOutputEventListBlock = { sampleTime, _, list in
        guard list.pointee.numPackets > 0 else { return noErr }
        let word = list.pointee.packet.words.0
        let messageType = word >> 28
        let status = Int((word >> 16) & 0xF0)
        let velocity = Int(word & 0x7F)
        if messageType == 0x2, status == 0x90, velocity > 0 { noteOnTimes.append(sampleTime) }
        return noErr
    }
    audioUnit.musicalContextBlock = { tempo, numerator, denominator, beat, nextBeat, downbeat in
        tempo?.pointee = 120
        numerator?.pointee = 4
        denominator?.pointee = 4
        beat?.pointee = hostBeat
        nextBeat?.pointee = 0
        downbeat?.pointee = 0
        return true
    }

    do {
        try audioUnit.allocateRenderResources()
        let render = audioUnit.renderBlock
        let schedule = audioUnit.scheduleMIDIEventBlock!
        let format = audioUnit.outputBusses[0].format
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!

        func scheduleMessage(_ sample: AUEventSampleTime, _ bytes: [UInt8]) {
            bytes.withUnsafeBufferPointer { schedule(sample, 0, $0.count, $0.baseAddress!) }
        }
        scheduleMessage(2_205, [0x90, 36, 100])  // beat 0.10
        scheduleMessage(41_895, [0x80, 36, 0])   // beat 1.90
        scheduleMessage(46_305, [0x90, 36, 100]) // beat 2.10
        scheduleMessage(85_995, [0x80, 36, 0])   // beat 3.90

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        for block in 0..<700 {
            timestamp.mSampleTime = Double(block * 128)
            hostBeat = timestamp.mSampleTime / 44_100 * 2
            let status = render(&flags, &timestamp, 128, 0, buffer.mutableAudioBufferList, nil)
            guard status == noErr else {
                print("AU_PATTERN_RENDER_FAILED: \(status)")
                exit(1)
            }
        }
        audioUnit.deallocateRenderResources()

        let firstWindow = noteOnTimes.filter { (2_205...41_895).contains($0) }
        let secondWindow = noteOnTimes.filter { (46_305...85_995).contains($0) }
        let outsideWindow = noteOnTimes.filter {
            !(2_205...41_895).contains($0) && !(46_305...85_995).contains($0)
        }
        let allOnPatternGrid = noteOnTimes.allSatisfy { sample in
            let step = Double(sample) / 5_512.5
            return abs(step - step.rounded()) < 0.001
        }
        guard !firstWindow.isEmpty, !secondWindow.isEmpty, outsideWindow.isEmpty, allOnPatternGrid else {
            print("AU_PATTERN_TIMING_FAILED: \(noteOnTimes)")
            exit(1)
        }
        print("AU_PATTERN_STABLE: \(noteOnTimes.count) project-grid pattern hits; release windows remained silent")
        exit(0)
    } catch {
        print("AU_PATTERN_ALLOCATION_FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("AU_PATTERN_TIMEOUT")
    exit(1)
}
app.run()
