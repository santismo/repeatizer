import AppKit
import AudioToolbox
import AVFoundation
import CoreMIDI
import Foundation

let description = AudioComponentDescription(
    componentType: kAudioUnitType_MIDIProcessor,
    componentSubType: 0x5270747A,       // Rptz
    componentManufacturer: 0x5250545A, // RPTZ
    componentFlags: 0,
    componentFlagsMask: 0
)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

AUAudioUnit.instantiate(with: description, options: [.loadOutOfProcess]) { audioUnit, error in
    guard let audioUnit else {
        print("AU_RENDER_INSTANTIATION_FAILED: \(error?.localizedDescription ?? "unknown error")")
        exit(1)
        return
    }

    guard let savedState = audioUnit.fullState,
          savedState["repeatizer.configuration"] is Data else {
        print("AU_STATE_MISSING")
        exit(1)
    }
    audioUnit.fullState = savedState

    var outputSampleTimes: [AUEventSampleTime] = []
    var hostBeat = 0.0
    var hostClockReady = false
    var startupClockMisses = 0
    audioUnit.hostMIDIProtocol = ._1_0
    // The remote AU contract requires MIDI output before resource allocation.
    audioUnit.midiOutputEventListBlock = { sampleTime, _, eventList in
        if eventList.pointee.numPackets > 0 { outputSampleTimes.append(sampleTime) }
        return noErr
    }

    do {
        let render = audioUnit.renderBlock
        let schedule = audioUnit.scheduleMIDIEventBlock
        try audioUnit.allocateRenderResources()

        // Logic may make its project timing callback available only after the
        // AU has allocated. Repeatizer must forward that late clock setter.
        audioUnit.musicalContextBlock = { tempo, numerator, denominator, beat, nextBeat, downbeat in
            guard hostClockReady else {
                startupClockMisses += 1
                return false
            }
            tempo?.pointee = 120
            numerator?.pointee = 4
            denominator?.pointee = 4
            beat?.pointee = hostBeat
            nextBeat?.pointee = 0
            downbeat?.pointee = 0
            return true
        }

        let format = audioUnit.outputBusses[0].format
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128), let schedule else {
            print("AU_RENDER_SETUP_FAILED")
            audioUnit.deallocateRenderResources()
            exit(1)
            return
        }

        // Velocity 1 must remain a note-on after MIDI 1-to-2 conversion.
        let noteOn: [UInt8] = [0x90, 36, 1]
        noteOn.withUnsafeBufferPointer { bytes in
            // 2367 samples is both off the sixteenth-note grid at 120 BPM and
            // partway through a 128-frame render block. The first generated
            // note must still land on beat 0.25 (~5513 samples), not one
            // sub-render segment late.
            schedule(2367, 0, bytes.count, bytes.baseAddress!)
        }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        for blockIndex in 0..<64 {
            timestamp.mSampleTime = Double(blockIndex * 128)
            hostBeat = timestamp.mSampleTime / 44_100 * 2
            // Logic may install the callback before its project timing is ready.
            // Repeatizer must keep rendering from a fallback clock, then hand off
            // cleanly once the synchronized project clock becomes available.
            hostClockReady = blockIndex >= 48
            let status = render(&flags, &timestamp, 128, 0, buffer.mutableAudioBufferList, nil)
            guard status == noErr else {
                print("AU_RENDER_FAILED: \(status)")
                audioUnit.deallocateRenderResources()
                exit(1)
                return
            }
        }

        let noteOff: [UInt8] = [0x80, 36, 0]
        noteOff.withUnsafeBufferPointer { bytes in
            schedule(AUEventSampleTimeImmediate, 0, bytes.count, bytes.baseAddress!)
        }
        timestamp.mSampleTime = Double(64 * 128)
        hostBeat = timestamp.mSampleTime / 44_100 * 2
        let finalStatus = render(&flags, &timestamp, 128, 0, buffer.mutableAudioBufferList, nil)
        audioUnit.deallocateRenderResources()

        let firstOutput = outputSampleTimes.first ?? -1
        guard finalStatus == noErr, startupClockMisses > 0, (5_511...5_514).contains(firstOutput) else {
            print("AU_RENDER_GRID_FAILED: status=\(finalStatus) first=\(firstOutput) events=\(outputSampleTimes.count)")
            exit(1)
            return
        }
        print("AU_RENDER_STABLE: late project clock forwarded; startup clock missed \(startupClockMisses) times; off-grid input waited until sample \(firstOutput); \(outputSampleTimes.count) MIDI callbacks")
        exit(0)
    } catch {
        print("AU_RENDER_ALLOCATION_FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("AU_RENDER_TIMEOUT")
    exit(1)
}
app.run()
