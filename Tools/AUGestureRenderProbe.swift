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
        print("AU_GESTURE_INSTANTIATION_FAILED: \(error?.localizedDescription ?? "unknown")")
        exit(1)
    }
    guard var state = audioUnit.fullState,
          let data = state["repeatizer.configuration"] as? Data,
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        print("AU_GESTURE_STATE_FAILED")
        exit(1)
    }
    json["drumGestures"] = [
        "rate": 5, // 1/16
        "lengthSteps": 8,
        "intensity": 1.0,
        "mappings": [
            "Diddle",
            ["enabled": true, "ccNumber": 20]
        ]
    ]
    state["repeatizer.configuration"] = try! JSONSerialization.data(withJSONObject: json)
    audioUnit.fullState = state

    var outputTimes: [AUEventSampleTime] = []
    var hostBeat = 0.0
    audioUnit.hostMIDIProtocol = ._1_0
    audioUnit.midiOutputEventListBlock = { sampleTime, _, list in
        if list.pointee.numPackets > 0 { outputTimes.append(sampleTime) }
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

        let gestureOn: [UInt8] = [0xB0, 20, 1]
        gestureOn.withUnsafeBufferPointer { schedule(0, 0, $0.count, $0.baseAddress!) }
        let noteOn: [UInt8] = [0x90, 38, 100]
        noteOn.withUnsafeBufferPointer { schedule(2304, 0, $0.count, $0.baseAddress!) }
        let gestureOff: [UInt8] = [0xB0, 20, 0]
        gestureOff.withUnsafeBufferPointer { schedule(8000, 0, $0.count, $0.baseAddress!) }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        for block in 0..<100 {
            timestamp.mSampleTime = Double(block * 128)
            hostBeat = timestamp.mSampleTime / 44_100 * 2
            let status = render(&flags, &timestamp, 128, 0, buffer.mutableAudioBufferList, nil)
            guard status == noErr else {
                print("AU_GESTURE_RENDER_FAILED: \(status)")
                exit(1)
            }
        }
        audioUnit.deallocateRenderResources()

        guard outputTimes.count == 4,
              (5_511...5_514).contains(outputTimes[0]),
              (6_172...6_176).contains(outputTimes[1]),
              (11_023...11_027).contains(outputTimes[2]),
              (11_685...11_689).contains(outputTimes[3]) else {
            print("AU_REMOVED_GESTURE_WAS_NOT_INERT: \(outputTimes)")
            exit(1)
        }
        print("AU_GESTURE_REMOVAL_STABLE: legacy CC20 gesture state was ignored; the pad stayed on its normal repeat grid")
        exit(0)
    } catch {
        print("AU_GESTURE_ALLOCATION_FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("AU_GESTURE_TIMEOUT")
    exit(1)
}
app.run()
