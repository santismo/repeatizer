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
        print("AU_CONTINUOUS_CC_INSTANTIATION_FAILED: \(error?.localizedDescription ?? "unknown")")
        exit(1)
    }
    guard var state = audioUnit.fullState,
          let data = state["repeatizer.configuration"] as? Data,
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var pads = json["pads"] as? [String: Any],
          var pad = pads["42"] as? [String: Any] else {
        print("AU_CONTINUOUS_CC_STATE_FAILED")
        exit(1)
    }
    json["settingsMode"] = "Individual"
    pad["playbackMode"] = "Repeat"
    pad["division"] = 1
    pad["repeatFillEnabled"] = false
    pad["swingPercent"] = 50.0
    pad["velocityHumanizeEnabled"] = false
    pads["42"] = pad
    json["pads"] = pads
    json["liveCC"] = [
        "mappings": [
            "Division Depth", ["enabled": true, "ccNumber": 14],
            "Velocity All", ["enabled": true, "ccNumber": 15]
        ],
        "momentaryMappings": []
    ]
    state["repeatizer.configuration"] = try! JSONSerialization.data(withJSONObject: json)
    audioUnit.fullState = state

    var output: [(sample: AUEventSampleTime, velocity: Int)] = []
    var hostBeat = 0.0
    audioUnit.hostMIDIProtocol = ._1_0
    audioUnit.midiOutputEventListBlock = { sampleTime, _, list in
        guard list.pointee.numPackets > 0 else { return noErr }
        let word = list.pointee.packet.words.0
        if word >> 28 == 0x2,
           Int((word >> 16) & 0xF0) == 0x90,
           Int((word >> 8) & 0x7F) == 42,
           Int(word & 0x7F) > 0 {
            output.append((sampleTime, Int(word & 0x7F)))
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

        // Start on the slow end, then move the held note to 1/64 in real time.
        // CC 15 at 64 should lock output velocity to 64.
        send(0, [0xB0, 14, 0])
        send(0, [0xB0, 15, 64])
        send(2_205, [0x90, 42, 9])
        send(4_410, [0xB0, 14, 127])
        send(12_000, [0x80, 42, 0])

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        for block in 0..<160 {
            timestamp.mSampleTime = Double(block * 128)
            hostBeat = timestamp.mSampleTime / 44_100 * 2
            let status = render(&flags, &timestamp, 128, 0, buffer.mutableAudioBufferList, nil)
            if status != noErr {
                print("AU_CONTINUOUS_CC_RENDER_FAILED: \(status)")
                exit(1)
            }
        }
        audioUnit.deallocateRenderResources()
        guard let first = output.first,
              abs(first.sample - 5_513) <= 2,
              output.allSatisfy({ $0.velocity == 64 }) else {
            print("AU_CONTINUOUS_CC_FAILED: \(output)")
            exit(1)
        }
        print("AU_CONTINUOUS_CC_STABLE: division slider re-gridded the held note and fixed velocity stayed at 64: \(output)")
        exit(0)
    } catch {
        print("AU_CONTINUOUS_CC_ALLOCATION_FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("AU_CONTINUOUS_CC_TIMEOUT")
    exit(1)
}
app.run()
