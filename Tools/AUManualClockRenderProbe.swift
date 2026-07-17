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
        print("AU_MANUAL_CLOCK_INSTANTIATION_FAILED: \(error?.localizedDescription ?? "unknown")")
        exit(1)
    }

    func state(manualBPM: Double) -> [String: Any]? {
        guard var state = audioUnit.fullState,
              let data = state["repeatizer.configuration"] as? Data,
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var master = json["masterSettings"] as? [String: Any] else { return nil }
        json["settingsMode"] = "Master"
        json["tempoMode"] = "Manual"
        json["manualBPM"] = manualBPM
        json["timeScale"] = "Normal"
        json["tapLive"] = false
        json["timingHumanizeEnabled"] = false
        master["playbackMode"] = "Repeat"
        master["division"] = 5
        master["swingDivision"] = -1
        master["swingPercent"] = 50.0
        json["masterSettings"] = master
        state["repeatizer.configuration"] = try? JSONSerialization.data(withJSONObject: json)
        return state
    }

    guard let initialState = state(manualBPM: 90) else {
        print("AU_MANUAL_CLOCK_STATE_FAILED")
        exit(1)
    }
    audioUnit.fullState = initialState
    audioUnit.hostMIDIProtocol = ._1_0
    var noteOnTimes: [AUEventSampleTime] = []
    audioUnit.midiOutputEventListBlock = { sampleTime, _, list in
        guard list.pointee.numPackets > 0 else { return noErr }
        let word = list.pointee.packet.words.0
        if word >> 28 == 0x2,
           Int((word >> 16) & 0xF0) == 0x90,
           Int(word & 0x7F) > 0 {
            noteOnTimes.append(sampleTime)
        }
        return noErr
    }

    do {
        try audioUnit.allocateRenderResources()
        let render = audioUnit.renderBlock
        let schedule = audioUnit.scheduleMIDIEventBlock!
        let format = audioUnit.outputBusses[0].format
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        let noteOn: [UInt8] = [0x90, 42, 100]
        noteOn.withUnsafeBufferPointer { schedule(2_205, 0, $0.count, $0.baseAddress!) }
        let noteOff: [UInt8] = [0x80, 42, 0]
        noteOff.withUnsafeBufferPointer { schedule(25_000, 0, $0.count, $0.baseAddress!) }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        for block in 0..<220 {
            if block == 80, let fasterState = state(manualBPM: 180) {
                // A live tempo edit must preserve phase and re-grid once. It
                // must not dump missed repeats or require toggling clock modes.
                audioUnit.fullState = fasterState
            }
            timestamp.mSampleTime = Double(block * 128)
            let status = render(&flags, &timestamp, 128, 0, buffer.mutableAudioBufferList, nil)
            guard status == noErr else {
                print("AU_MANUAL_CLOCK_RENDER_FAILED: \(status)")
                exit(1)
            }
        }
        audioUnit.deallocateRenderResources()

        guard let first = noteOnTimes.first,
              abs(first - 7_350) <= 2,
              noteOnTimes.count >= 4,
              zip(noteOnTimes.dropFirst(), noteOnTimes).allSatisfy({ $0 - $1 > 1_000 }) else {
            print("AU_MANUAL_CLOCK_GRID_FAILED: \(noteOnTimes)")
            exit(1)
        }
        print("AU_MANUAL_CLOCK_STABLE: manual mode started immediately at 90 BPM, first grid \(first), and continued cleanly after a 180 BPM edit: \(noteOnTimes)")
        exit(0)
    } catch {
        print("AU_MANUAL_CLOCK_ALLOCATION_FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("AU_MANUAL_CLOCK_TIMEOUT")
    exit(1)
}
app.run()
