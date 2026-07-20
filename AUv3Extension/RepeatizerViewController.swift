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
        // AU hosts are allowed to invoke the factory on the main thread. A
        // blind DispatchQueue.main.sync in that case deadlocks the extension
        // until the host's component-open timeout expires.
        if Thread.isMainThread {
            return try MainActor.assumeIsolated {
                try makeAudioUnit(with: componentDescription)
            }
        }
        return try DispatchQueue.main.sync {
            try makeAudioUnit(with: componentDescription)
        }
    }

    private func makeAudioUnit(with componentDescription: AudioComponentDescription) throws -> RepeatizerAudioUnit {
        let unit = try RepeatizerAudioUnit(componentDescription: componentDescription, options: [])
        audioUnit = unit
        if isViewLoaded {
            installView(for: unit)
        }
        return unit
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
