import SwiftUI
import RepeatizerCore

@main
struct RepeatizerPreviewApp: App {
    var body: some Scene {
        WindowGroup("Repeatizer") {
            RepeatizerMainView()
                .frame(minWidth: 1080, minHeight: 760)
        }
        .windowResizability(.contentMinSize)
    }
}

enum RepeatizerTheme: String, CaseIterable, Identifiable {
    case dark = "Dark"
    case light = "Light"
    case mix = "Mix"

    var id: String { rawValue }
    var background: Color {
        switch self {
        case .dark: Color(red: 0.055, green: 0.063, blue: 0.09)
        case .light: Color(red: 0.93, green: 0.94, blue: 0.96)
        case .mix: Color(red: 0.12, green: 0.14, blue: 0.19)
        }
    }
    var panel: Color {
        switch self {
        case .dark: Color(red: 0.095, green: 0.11, blue: 0.15)
        case .light: .white
        case .mix: Color(red: 0.18, green: 0.2, blue: 0.26)
        }
    }
    var primary: Color { self == .light ? Color(red: 0.08, green: 0.1, blue: 0.14) : .white }
    var secondary: Color { self == .light ? .gray : Color.white.opacity(0.58) }
    var accent: Color { Color(red: 0.32, green: 0.86, blue: 0.72) }
    var border: Color { self == .light ? Color.black.opacity(0.09) : Color.white.opacity(0.1) }
}

@MainActor
final class RepeatizerViewModel: ObservableObject {
    @Published var configuration = RepeatizerConfiguration(pads: RepeatizerPresets.gmStandard.pads)
    @Published var selectedNote = GMDrumPad.closedHat.rawValue
    @Published var selectedPreset = RepeatizerPresets.gmStandard.id
    @Published var theme: RepeatizerTheme = .dark

    var selectedPad: GMDrumPad? { GMDrumPad(rawValue: selectedNote) }
    var selectedConfiguration: PadConfiguration { configuration.pad(selectedNote) }

    func updatePad(_ body: (inout PadConfiguration) -> Void) {
        var pad = configuration.pad(selectedNote)
        body(&pad)
        configuration.pads[selectedNote] = pad
    }

    func applyPreset(_ id: String) {
        guard let preset = RepeatizerPresets.all.first(where: { $0.id == id }) else { return }
        configuration.pads = preset.pads
        selectedPreset = id
    }
}

struct RepeatizerMainView: View {
    @StateObject private var model = RepeatizerViewModel()

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            Header(model: model)
            Divider().overlay(theme.border)
            HStack(alignment: .top, spacing: 18) {
                PadGrid(model: model)
                    .frame(maxWidth: 420)
                PadEditor(model: model)
            }
            .padding(20)
        }
        .background(theme.background)
        .foregroundStyle(theme.primary)
        .preferredColorScheme(theme == .light ? .light : .dark)
    }
}

private struct Header: View {
    @ObservedObject var model: RepeatizerViewModel

    var body: some View {
        let theme = model.theme
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("REPEATIZER")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .tracking(1.5)
                Text("MIDI RHYTHM ENGINE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(theme.accent)
            }
            Spacer()
            Picker("Preset", selection: $model.selectedPreset) {
                ForEach(RepeatizerPresets.all) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .labelsHidden()
            .frame(width: 160)
            .onChange(of: model.selectedPreset) { _, id in model.applyPreset(id) }

            Picker("Clock", selection: $model.configuration.tempoMode) {
                ForEach(TempoMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)

            if model.configuration.tempoMode == .manual {
                HStack(spacing: 6) {
                    Text("BPM").font(.caption.weight(.bold)).foregroundStyle(theme.secondary)
                    TextField("BPM", value: $model.configuration.manualBPM, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                }
            } else {
                Text("HOST BPM")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 82)
            }

            Picker("Theme", selection: $model.theme) {
                ForEach(RepeatizerTheme.allCases) { theme in Text(theme.rawValue).tag(theme) }
            }
            .labelsHidden()
            .frame(width: 92)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
    }
}

private struct PadGrid: View {
    @ObservedObject var model: RepeatizerViewModel

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("GM DRUM PADS").sectionTitle()
                Spacer()
                Text("PER-PAD SETTINGS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(theme.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(GMDrumPad.allCases) { pad in
                    let config = model.configuration.pad(pad.rawValue)
                    Button {
                        model.selectedNote = pad.rawValue
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(pad.rawValue)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(theme.secondary)
                            Text(pad.name.uppercased())
                                .font(.caption2.weight(.heavy))
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            HStack(spacing: 4) {
                                Text(config.division.title)
                                Text("·")
                                Text("\(Int(config.swingPercent))%")
                            }
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(model.selectedNote == pad.rawValue ? theme.accent : theme.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                        .background(model.selectedNote == pad.rawValue ? theme.accent.opacity(0.12) : theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(model.selectedNote == pad.rawValue ? theme.accent : theme.border, lineWidth: model.selectedNote == pad.rawValue ? 1.5 : 1))
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Select a pad to independently shape its repeat division, live swing, velocity behavior, and modulation lanes.")
                .font(.caption)
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .panel(theme)
    }
}

private struct PadEditor: View {
    @ObservedObject var model: RepeatizerViewModel

    var body: some View {
        let theme = model.theme
        let pad = model.selectedPad
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pad?.name.uppercased() ?? "CUSTOM PAD")
                            .font(.title2.weight(.black))
                        Text("MIDI NOTE \(model.selectedNote) · INDEPENDENT REPEAT LANE")
                            .font(.caption.weight(.bold))
                            .tracking(0.7)
                            .foregroundStyle(theme.secondary)
                    }
                    Spacer()
                    Text("ACTIVE")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(theme.accent.opacity(0.12), in: Capsule())
                }

                TimingCard(model: model)
                VelocityCard(model: model)
                ModulationPanel(model: model)
            }
            .padding(16)
        }
        .panel(theme)
    }
}

private struct TimingCard: View {
    @ObservedObject var model: RepeatizerViewModel

    var body: some View {
        SectionCard(title: "TIMING", subtitle: "LIVE REPEAT GRID", theme: model.theme) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Repeat division").controlLabel(model.theme)
                Picker("Repeat division", selection: Binding(
                    get: { model.selectedConfiguration.division },
                    set: { selection in model.updatePad { $0.division = selection } }
                )) {
                    ForEach(RepeatDivision.allCases) { division in Text(division.title).tag(division) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Swing").controlLabel(model.theme)
                    Spacer()
                    Text("\(Int(model.selectedConfiguration.swingPercent.rounded()))%")
                        .font(.system(.body, design: .monospaced).weight(.bold))
                        .foregroundStyle(model.theme.accent)
                }
                Slider(value: Binding(
                    get: { model.selectedConfiguration.swingPercent },
                    set: { value in model.updatePad { $0.swingPercent = value } }
                ), in: 50...75, step: 0.1)
                .tint(model.theme.accent)
                HStack {
                    Text("50 STRAIGHT")
                    Spacer()
                    Text("75 HARD SWING")
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(model.theme.secondary)
            }
        }
    }
}

private struct VelocityCard: View {
    @ObservedObject var model: RepeatizerViewModel

    var body: some View {
        SectionCard(title: "VELOCITY", subtitle: "REPEAT DYNAMICS", theme: model.theme) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Velocity mode", selection: Binding(
                    get: { model.selectedConfiguration.velocityMode },
                    set: { selection in model.updatePad { $0.velocityMode = selection } }
                )) {
                    ForEach(VelocityMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)

                if model.selectedConfiguration.velocityMode == .fixed {
                    SliderRow(title: "Fixed velocity", value: Binding(
                        get: { Double(model.selectedConfiguration.fixedVelocity) },
                        set: { value in model.updatePad { $0.fixedVelocity = Int(value.rounded()) } }
                    ), range: 1...127, valueLabel: "\(model.selectedConfiguration.fixedVelocity)", theme: model.theme)
                }
                if model.selectedConfiguration.velocityMode == .humanized {
                    SliderRow(title: "Humanize", value: Binding(
                        get: { Double(model.selectedConfiguration.humanizeAmount) },
                        set: { value in model.updatePad { $0.humanizeAmount = Int(value.rounded()) } }
                    ), range: 0...32, valueLabel: "±\(model.selectedConfiguration.humanizeAmount)", theme: model.theme)
                }
                Text(velocityCopy)
                    .font(.caption)
                    .foregroundStyle(model.theme.secondary)
            }
        }
    }

    private var velocityCopy: String {
        switch model.selectedConfiguration.velocityMode {
        case .received: "Each generated hit retains the velocity received from the held pad."
        case .fixed: "Every generated hit uses the exact fixed velocity shown above."
        case .humanized: "Generated hits vary naturally around the incoming velocity."
        }
    }
}

private struct ModulationPanel: View {
    @ObservedObject var model: RepeatizerViewModel

    var body: some View {
        SectionCard(title: "PER-SETTING MODULATION", subtitle: "INDEPENDENT FOR THIS PAD", theme: model.theme) {
            VStack(spacing: 10) {
                ModulatorCard(title: "Division movement", detail: "Move one or two divisions up, down, or both.", modulator: Binding(
                    get: { model.selectedConfiguration.divisionModulator },
                    set: { value in model.updatePad { $0.divisionModulator = value } }
                ), theme: model.theme, maximumDepth: 2, depthLabel: "Steps")
                ModulatorCard(title: "Swing movement", detail: "Continuously alter the swing percentage while held.", modulator: Binding(
                    get: { model.selectedConfiguration.swingModulator },
                    set: { value in model.updatePad { $0.swingModulator = value } }
                ), theme: model.theme, maximumDepth: 2, depthLabel: "Amount")
                ModulatorCard(title: "Velocity movement", detail: "Add LFO or random velocity motion to generated hits.", modulator: Binding(
                    get: { model.selectedConfiguration.velocityModulator },
                    set: { value in model.updatePad { $0.velocityModulator = value } }
                ), theme: model.theme, maximumDepth: 2, depthLabel: "Amount")
            }
        }
    }
}

private struct ModulatorCard: View {
    let title: String
    let detail: String
    @Binding var modulator: Modulator
    let theme: RepeatizerTheme
    let maximumDepth: Double
    let depthLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.bold))
                    Text(detail).font(.caption).foregroundStyle(theme.secondary)
                }
                Spacer()
                Picker(title, selection: $modulator.mode) {
                    ForEach(ModulationMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            if modulator.mode != .off {
                HStack(spacing: 14) {
                    Picker("Direction", selection: $modulator.direction) {
                        ForEach(ModulationDirection.allCases, id: \.self) { direction in Text(direction.rawValue).tag(direction) }
                    }
                    .labelsHidden().frame(width: 92)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RATE \(modulator.rate, format: .number.precision(.fractionLength(2))) / beat")
                            .font(.caption2.weight(.bold)).foregroundStyle(theme.secondary)
                        Slider(value: $modulator.rate, in: 0.05...4, step: 0.05).tint(theme.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(depthLabel.uppercased()) \(modulator.depth, format: .number.precision(.fractionLength(1)))")
                            .font(.caption2.weight(.bold)).foregroundStyle(theme.secondary)
                        Slider(value: $modulator.depth, in: 0...maximumDepth, step: 0.1).tint(theme.accent)
                    }
                }
            }
        }
        .padding(12)
        .background(theme.background.opacity(theme == .light ? 0.65 : 0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let theme: RepeatizerTheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).sectionTitle()
                Text(subtitle).font(.caption2.weight(.bold)).foregroundStyle(theme.secondary)
            }
            content
        }
        .padding(15)
        .background(theme.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueLabel: String
    let theme: RepeatizerTheme

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).controlLabel(theme)
                Spacer()
                Text(valueLabel).font(.system(.body, design: .monospaced).weight(.bold)).foregroundStyle(theme.accent)
            }
            Slider(value: $value, in: range, step: 1).tint(theme.accent)
        }
    }
}

private extension View {
    func panel(_ theme: RepeatizerTheme) -> some View {
        background(theme.panel, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(theme.border, lineWidth: 1))
    }
}

private extension Text {
    func sectionTitle() -> some View {
        font(.caption.weight(.heavy)).tracking(1.1)
    }
    func controlLabel(_ theme: RepeatizerTheme) -> some View {
        font(.subheadline.weight(.semibold)).foregroundStyle(theme.primary)
    }
}
