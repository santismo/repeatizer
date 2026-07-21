#import <AudioToolbox/AudioToolbox.h>

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <vector>

#include "../AUv3Extension/Engine/RepeatizerKernel.hpp"

namespace
{
void require (bool condition, const char* message)
{
    if (condition)
        return;
    std::cerr << "Repeatizer kernel tempo test failed: " << message << '\n';
    std::exit (1);
}

void attachNoOpOutput (RepeatizerKernel& kernel)
{
    kernel.setMIDIOutputEventBlock (^(AUEventSampleTime, UInt8, const MIDIEventList*) {
        return OSStatus (noErr);
    });
}

bool near (double value, double expected, double tolerance = 0.001)
{
    return std::abs (value - expected) <= tolerance;
}

struct CapturedEvent
{
    AUEventSampleTime sample = 0;
    int status = 0;
    int note = 0;
};

void attachCaptureOutput (RepeatizerKernel& kernel, std::vector<CapturedEvent>& events)
{
    auto* destination = &events;
    kernel.setMIDIOutputEventBlock (^(AUEventSampleTime sample, UInt8, const MIDIEventList* list) {
        const auto& eventList = *list;
        const auto* packet = &eventList.packet[0];
        for (UInt32 packetIndex = 0; packetIndex < eventList.numPackets; ++packetIndex)
        {
            for (UInt32 wordIndex = 0; wordIndex < packet->wordCount; ++wordIndex)
            {
                const auto word = packet->words[wordIndex];
                if ((word >> 28) == 0x2)
                    destination->push_back ({ sample, int ((word >> 16) & 0xf0), int ((word >> 8) & 0x7f) });
            }
            packet = MIDIEventPacketNext (packet);
        }
        return OSStatus (noErr);
    });
}
}

int main()
{
    constexpr double sampleRate = 48000.0;
    constexpr int nudgeCC = 2;

    // Manual mode: a fixed controller must hold its offset, and returning to
    // center must change rate without jumping the accumulated internal beat.
    RepeatizerKernel manual;
    manual.initialize (sampleRate);
    attachNoOpOutput (manual);
    manual.setTempoMode (false);
    manual.setManualBPM (120.0);
    manual.configureTempoNudge (true, nudgeCC, 20.0);
    manual.handleDirectMIDI (0, 0xB0, nudgeCC, 127);
    manual.process (0, 480);
    require (near (manual.currentBPM(), 140.0), "CC 127 must hold manual tempo at base plus range");

    manual.handleDirectMIDI (48000, 0xB0, nudgeCC, 64);
    manual.process (48000, 480);
    require (near (manual.currentBPM(), 120.0), "CC 64 must restore the manual base tempo");
    require (near (manual.currentBeat(), 140.0 / 60.0), "manual tempo changes must preserve continuous phase");

    manual.handleDirectMIDI (96000, 0xB0, nudgeCC, 127);
    manual.process (96000, 480);
    manual.process (144000, 480);
    require (near (manual.currentBPM(), 140.0), "a non-spring controller must retain its last offset");

    manual.handleDirectMIDI (192000, 0xB0, nudgeCC, 0);
    manual.process (192000, 480);
    require (near (manual.currentBPM(), 100.0), "CC 0 must subtract the full configured range");

    // Host mode: Logic's raw project beat advances at 120 BPM, while the
    // private Repeatizer phase advances at the effective 140 BPM until the CC
    // returns to center. It must not be reset to the host beat every block.
    RepeatizerKernel synced;
    synced.initialize (sampleRate);
    attachNoOpOutput (synced);
    synced.setTempoMode (true);
    synced.configureTempoNudge (true, nudgeCC, 20.0);
    synced.setDirectRenderContext (0, 120.0, 0.0, true);
    synced.handleDirectMIDI (0, 0xB0, nudgeCC, 127);
    synced.process (0, 480);

    synced.setDirectRenderContext (48000, 120.0, 2.0, true);
    synced.process (48000, 480);
    require (near (synced.currentBPM(), 140.0), "host tempo must be the base for the positive offset");
    require (near (synced.currentBeat(), 140.0 / 60.0), "synced nudge must accumulate faster than the host beat");

    synced.setDirectRenderContext (96000, 120.0, 4.0, true);
    synced.handleDirectMIDI (96000, 0xB0, nudgeCC, 64);
    synced.process (96000, 480);
    require (near (synced.currentBPM(), 120.0), "center must restore the host base rate");
    require (near (synced.currentBeat(), 280.0 / 60.0), "centering must retain the phase accumulated by the nudge");

    synced.setDirectRenderContext (144000, 120.0, 6.0, true);
    synced.process (144000, 480);
    require (near (synced.currentBeat(), 400.0 / 60.0), "neutral synced playback must continue from the shifted phase");

    synced.setDirectRenderContext (192000, 120.0, 20.0, true);
    synced.process (192000, 480);
    require (near (synced.currentBeat(), 20.0), "a real host transport jump must re-anchor Repeatizer");

    // A tempo CC change between a generated note-on and its pending note-off
    // must retain the musical gate. The off and the next repeated on should
    // meet at the same boundary, in off-before-on order, with no overlap.
    RepeatizerKernel liveGate;
    std::vector<CapturedEvent> events;
    liveGate.initialize (sampleRate);
    attachCaptureOutput (liveGate, events);
    liveGate.setTempoMode (false);
    liveGate.setManualBPM (120.0);
    liveGate.configureTempoNudge (true, nudgeCC, 60.0);
    liveGate.handleDirectMIDI (0, 0x90, 60, 100);
    liveGate.process (0, 2400); // first note-on; its 1/16 gate ends at beat 0.25
    liveGate.handleDirectMIDI (2400, 0xB0, nudgeCC, 127);
    liveGate.process (2400, 4800); // tempo rises to 180 BPM before the pending off

    int sounding = 0;
    int maximumSounding = 0;
    int noteOnCount = 0;
    int noteOffCount = 0;
    for (const auto& event : events)
    {
        if (event.note != 60) { continue; }
        if (event.status == 0x90)
        {
            ++noteOnCount;
            ++sounding;
            maximumSounding = std::max (maximumSounding, sounding);
        }
        else if (event.status == 0x80)
        {
            ++noteOffCount;
            sounding = std::max (0, sounding - 1);
        }
    }
    require (noteOnCount == 2, "tempo move must produce the next repeat on the adjusted grid");
    require (noteOffCount == 1, "tempo move must preserve the previous repeat's pending note-off");
    require (maximumSounding == 1, "tempo move must never overlap two generated notes on the same pitch");
    require (events.size() >= 3 && events[1].status == 0x80 && events[2].status == 0x90,
             "the old gate must close before the new repeat opens at a shared boundary");
    require (events.size() >= 3 && events[1].sample == events[2].sample,
             "the preserved note-off must follow the newly adjusted tempo exactly");

    return 0;
}
