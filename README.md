# Repeatizer

Repeatizer is a complete macOS MIDI effect for Logic Pro with repeat, pattern, and Instrument modes. Instrument mode provides chord and ascending, downward, or random arpeggiator playback, rhythm styles and variations, octave range, probability, gate, velocity, and humanization controls.

The interface uses the shared Logic-inspired Songizer visual system: system text, compact charcoal controls, recessed sliders, and meaningful state color. Fine-control sliders quantize their values without creating thousands of native tick marks, and requested drum patterns are generated on demand, keeping the editor responsive at first open. The AUv3 lives inside an invisible `LSUIElement` support container and does not present a separate app window.

## Install locally

Use the Songizer Suite installer for the normal release. For a local source build, the script below places the invisible support container in `~/Library/Application Support/Songizer/Repeatizer` and registers its AUv3 MIDI effect. Nothing is installed as a visible application.

## Build from source

Requirements: macOS 14 or later and Xcode 16 or later.

```bash
swift test
./scripts/build-and-install.sh
```

The script applies the hardened-runtime signature required by the sandboxed AUv3, then installs it as an invisible support container in Application Support. Quit and reopen Logic Pro after installing.

## Development checks

```bash
swift test
```

The test suite covers the repeat engine, Instrument Mode, timing, clock behavior, pattern modes, live capture, and MIDI CC controls.

## License

MIT License © 2026 Santismo. See [LICENSE](LICENSE).
