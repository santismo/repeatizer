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
        print("AU_CC_INSTANTIATION_FAILED: \(error?.localizedDescription ?? "unknown")")
        exit(1)
    }
    guard var state = audioUnit.fullState,
          let data = state["repeatizer.configuration"] as? Data,
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var pads = json["pads"] as? [String: Any] else {
        print("AU_CC_STATE_FAILED")
        exit(1)
    }
    json["settingsMode"] = "Individual"
    let divisions = ["42": 5, "43": 5, "44": 5, "45": 5]
    for (note, division) in divisions {
        guard var pad = pads[note] as? [String: Any] else { continue }
        pad["playbackMode"] = "Repeat"
        pad["division"] = division
        pad["swingPercent"] = 50.0
        pads[note] = pad
    }
    json["pads"] = pads
    json["liveCC"] = [
        "mappings": [],
        "momentaryMappings": [
            "Straight +1", ["enabled": true, "ccNumber": 64],
            "Straight −1", ["enabled": true, "ccNumber": 65],
            "Triplet +1", ["enabled": true, "ccNumber": 66],
            "Triplet −1", ["enabled": true, "ccNumber": 67]
        ]
    ]
    state["repeatizer.configuration"] = try! JSONSerialization.data(withJSONObject: json)
    audioUnit.fullState = state

    var outputTimes: [Int: [AUEventSampleTime]] = [:]
    var hostBeat = 0.0
    audioUnit.hostMIDIProtocol = ._1_0
    audioUnit.midiOutputEventListBlock = { sampleTime, _, list in
        guard list.pointee.numPackets > 0 else { return noErr }
        let word = list.pointee.packet.words.0
        if word >> 28 == 0x2,
           Int((word >> 16) & 0xF0) == 0x90,
           Int(word & 0x7F) > 0 {
            let note = Int((word >> 8) & 0x7F)
            outputTimes[note, default: []].append(sampleTime)
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
        // One held-note window for each retained mapping. The four mappings are
        // global, but each CC is released before the next case begins.
        send(0, [0xB0, 64, 127])
        send(2_205, [0x90, 42, 100])
        send(15_435, [0x80, 42, 0]); send(15_435, [0xB0, 64, 0])

        send(22_050, [0xB0, 65, 127])
        send(24_255, [0x90, 43, 100])
        send(39_690, [0x80, 43, 0]); send(39_690, [0xB0, 65, 0])

        send(44_100, [0xB0, 66, 127])
        send(48_069, [0x90, 44, 100])
        send(59_535, [0x80, 44, 0]); send(59_535, [0xB0, 66, 0])

        send(66_150, [0xB0, 67, 127])
        send(70_119, [0x90, 45, 100])
        send(83_790, [0x80, 45, 0]); send(83_790, [0xB0, 67, 0])

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        for block in 0..<700 {
            timestamp.mSampleTime = Double(block * 128)
            hostBeat = timestamp.mSampleTime / 44_100 * 2
            let status = render(&flags, &timestamp, 128, 0, buffer.mutableAudioBufferList, nil)
            if status != noErr {
                print("AU_CC_RENDER_FAILED: \(status)")
                exit(1)
            }
        }
        audioUnit.deallocateRenderResources()
        let expected: [Int: AUEventSampleTime] = [
            42: 2_756,  // even +1: 1/16 -> 1/32
            43: 33_075, // even -1: 1/16 -> 1/8
            44: 51_450, // odd +1: straight 1/16 -> next faster 1/16T
            45: 73_500  // odd -1: straight 1/16 -> next slower 1/8T
        ]
        let valid = expected.allSatisfy { note, sample in
            guard let first = outputTimes[note]?.first else { return false }
            return abs(first - sample) <= 2
        }
        guard valid else {
            print("AU_CC_GRID_FAILED: \(outputTimes)")
            exit(1)
        }
        print("AU_CC_GATE_STABLE: even and odd division up/down mappings re-gridded independently: \(outputTimes.mapValues { $0.first ?? -1 })")
        exit(0)
    } catch {
        print("AU_CC_ALLOCATION_FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("AU_CC_TIMEOUT")
    exit(1)
}
app.run()
