# Repeatizer

Repeatizer is a macOS AUv3 MIDI effect for Logic Pro. In **Drums** view, hold a drum note to turn it into a rhythmic repeat lane, then shape its division, swing, velocity, fills, pattern behavior, and global clock. In **Instrument** view, the held-note strip stays minimal while chord mode provides 44 genre styles with eight rhythm patterns each, live pattern changes, variation, complexity, fills, fluctuation, probability, Smart Play, and full velocity/timing humanize controls. Arp modes run continuously with up/down/up-down/random order, shuffled random passes, selectable gate length, and octave expansion up or down.

## Download and install

1. Quit Logic Pro completely.
2. Download **`Repeatizer-1.14.0-macOS.zip`** from the [latest release](https://github.com/santismo/repeatizer/releases/latest).
3. Unzip it and move **Repeatizer.app** into **Applications**, replacing an older Repeatizer app if macOS asks.
4. Control-click **Repeatizer.app** and choose **Open** once. This registers the included Audio Unit with macOS.
5. Open Logic Pro. In **Logic Pro > Settings > Plug-in Manager**, locate **Repeatizer: Repeatizer** and enable it if needed.
6. On a Software Instrument track, add it from **MIDI FX > Audio Units > Repeatizer: Repeatizer**.

If the plug-in does not appear immediately, quit and reopen Logic Pro after opening Repeatizer.app once.

## Build from source

Requirements: macOS 14 or later, Xcode 16 or later, and an Apple Development signing identity.

```bash
git clone https://github.com/santismo/repeatizer.git
cd repeatizer
swift test
./scripts/build-and-install.sh
```

The install script builds the signed Release app, installs it to `/Applications/Repeatizer.app`, and registers the AUv3 extension. Quit Logic Pro before running it, then reopen Logic afterward.

To build from Xcode instead, open `Repeatizer.xcodeproj`, select the **Repeatizer** scheme, and run the app once after building so macOS registers the extension.

## Development checks

```bash
swift test
```

The test suite covers the core repeat engine, timing, clock behavior, pattern modes, live capture, and MIDI CC controls.

## License

MIT License © 2026 Santismo. See [LICENSE](LICENSE).
