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
        print("AU_TAP_LIVE_INSTANTIATION_FAILED: \(error?.localizedDescription ?? "unknown")")
        exit(1)
    }
    guard var state = audioUnit.fullState,
          let data = state["repeatizer.configuration"] as? Data,
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var master = json["masterSettings"] as? [String: Any] else {
        print("AU_TAP_LIVE_STATE_FAILED")
        exit(1)
    }

    json["settingsMode"] = "Master"
    json["tempoMode"] = "Sync"
    json["timeScale"] = "Normal"
    json["captureShortTaps"] = true
    json["tapLive"] = true
    json["tapLiveBuffer"] = 3 // independent wait: 1/8
    json["tapLiveQuantizeMode"] = "Straight"
    json["tapLiveStraightDivision"] = 5 // live hit grid: 1/16
    json["tapLiveTripletDivision"] = 6
    master["playbackMode"] = "Repeat"
    master["division"] = 5
    master["swingDivision"] = -1
    master["swingPercent"] = 50.0
    master["velocityMode"] = "Fixed"
    master["fixedVelocity"] = 100
    master["velocityHumanizeEnabled"] = false
    json["masterSettings"] = master
    state["repeatizer.configuration"] = try! JSONSerialization.data(withJSONObject: json)
    audioUnit.fullState = state

    var noteOns: [(sample: AUEventSampleTime, velocity: Int)] = []
    var hostBeat = 0.0
    audioUnit.hostMIDIProtocol = ._1_0
    audioUnit.midiOutputEventListBlock = { sampleTime, _, list in
        guard list.pointee.numPackets > 0 else { return noErr }
        let word = list.pointee.packet.words.0
        if word >> 28 == 0x2,
           Int((word >> 16) & 0xF0) == 0x90 {
            let velocity = Int(word & 0x7F)
            if velocity > 0 { noteOns.append((sampleTime, velocity)) }
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
        send(2_205, [0x90, 42, 37])  // beat 0.10, deliberately off-grid
        send(24_255, [0x80, 42, 0])  // beat 1.10

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        for block in 0..<200 {
            timestamp.mSampleTime = Double(block * 128)
            hostBeat = timestamp.mSampleTime / 44_100 * 2
            let status = render(&flags, &timestamp, 128, 0, buffer.mutableAudioBufferList, nil)
            guard status == noErr else {
                print("AU_TAP_LIVE_RENDER_FAILED: \(status)")
                exit(1)
            }
        }
        audioUnit.deallocateRenderResources()

        // Live tap: 0.10 -> 0.25 on the chosen 1/16 grid.
        // Wait: 1/8 (0.5 beat) -> repeats resume at beat 0.75.
        // Repeat division remains its own 1/16 setting.
        let expectedSamples: [AUEventSampleTime] = [5_513, 16_538, 22_050]
        let samples = noteOns.map(\.sample)
        let velocities = noteOns.map(\.velocity)
        guard samples.count == expectedSamples.count,
              zip(samples, expectedSamples).allSatisfy({ abs($0 - $1) <= 2 }),
              velocities == [37, 100, 100] else {
            print("AU_TAP_LIVE_TIMING_FAILED: samples=\(samples) velocities=\(velocities)")
            exit(1)
        }
        print("AU_TAP_LIVE_STABLE: live hit quantized to sample \(samples[0]); independent 1/8 wait resumed 1/16 repeats at \(samples[1])")
        exit(0)
    } catch {
        print("AU_TAP_LIVE_ALLOCATION_FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("AU_TAP_LIVE_TIMEOUT")
    exit(1)
}
app.run()
