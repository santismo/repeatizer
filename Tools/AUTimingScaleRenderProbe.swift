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
        print("AU_TIMING_INSTANTIATION_FAILED: \(error?.localizedDescription ?? "unknown")")
        exit(1)
    }
    guard var state = audioUnit.fullState,
          let data = state["repeatizer.configuration"] as? Data,
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var master = json["masterSettings"] as? [String: Any] else {
        print("AU_TIMING_STATE_FAILED")
        exit(1)
    }

    json["settingsMode"] = "Master"
    json["tempoMode"] = "Sync"
    json["timeScale"] = "Half"
    master["playbackMode"] = "Repeat"
    master["division"] = 5             // 1/16; half-time interval becomes 0.5 beat
    master["swingDivision"] = 3        // independent 1/8; half-time unit becomes 1 beat
    master["swingPercent"] = 66.6667
    json["masterSettings"] = master
    state["repeatizer.configuration"] = try! JSONSerialization.data(withJSONObject: json)
    audioUnit.fullState = state

    var noteOnTimes: [AUEventSampleTime] = []
    var hostBeat = 0.0
    audioUnit.hostMIDIProtocol = ._1_0
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

        func send(_ sample: AUEventSampleTime, _ bytes: [UInt8]) {
            bytes.withUnsafeBufferPointer { schedule(sample, 0, $0.count, $0.baseAddress!) }
        }
        send(1_000, [0x90, 42, 100])
        send(46_000, [0x80, 42, 0])

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        for block in 0..<400 {
            timestamp.mSampleTime = Double(block * 128)
            hostBeat = timestamp.mSampleTime / 44_100 * 2
            let status = render(&flags, &timestamp, 128, 0, buffer.mutableAudioBufferList, nil)
            guard status == noErr else {
                print("AU_TIMING_RENDER_FAILED: \(status)")
                exit(1)
            }
        }
        audioUnit.deallocateRenderResources()

        // The realtime kernel stores swing in tenths of a percent, so 66.6667%
        // is represented as 66.7% and lands at sample 29,415.
        let expected: [AUEventSampleTime] = [11_025, 29_415, 33_075, 44_100]
        guard noteOnTimes.count == expected.count,
              zip(noteOnTimes, expected).allSatisfy({ abs($0 - $1) <= 2 }) else {
            print("AU_TIMING_GRID_FAILED: \(noteOnTimes)")
            exit(1)
        }
        print("AU_TIMING_SCALE_STABLE: half-time repeats and independent 1/8 swing grid rendered at \(noteOnTimes)")
        exit(0)
    } catch {
        print("AU_TIMING_ALLOCATION_FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("AU_TIMING_TIMEOUT")
    exit(1)
}
app.run()
