import CoreAudioKit
import SwiftUI

@MainActor
public final class RepeatizerViewController: AUViewController, AUAudioUnitFactory {
    private var audioUnit: RepeatizerAudioUnit?
    private var host: NSHostingController<RepeatizerPluginView>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 980, height: 580)
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.018, green: 0.02, blue: 0.024, alpha: 1).cgColor
        if let audioUnit { installView(for: audioUnit) }
    }

    nonisolated public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        // Audio Unit factories are commonly called from the extension's XPC
        // worker queue. Never synchronously bounce that request to the main
        // actor: a host can already be waiting on the main thread for this
        // method to return, producing a component-open timeout and a black UI.
        let unit = try RepeatizerAudioUnit(componentDescription: componentDescription, options: [])
        Task { @MainActor [weak self] in
            self?.connect(unit)
        }
        return unit
    }

    private func connect(_ unit: RepeatizerAudioUnit) {
        audioUnit = unit
        if isViewLoaded {
            installView(for: unit)
        }
    }

    private func installView(for audioUnit: RepeatizerAudioUnit) {
        guard isViewLoaded else { return }
        guard host == nil else { return }
        let hosting = NSHostingController(rootView: RepeatizerPluginView(audioUnit: audioUnit))
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host = hosting
    }
}
