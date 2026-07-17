import AppKit
import AudioToolbox
import AVFoundation
import CoreAudioKit
import Darwin

private func compositedWindowImage(_ windowID: CGWindowID) -> CGImage? {
    // The public ScreenCaptureKit path requires screen-recording permission even
    // for this process's own test window. The legacy WindowServer symbol still
    // exists on current macOS and can capture our own window without a TCC prompt.
    guard let framework = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else { return nil }
    defer { dlclose(framework) }
    guard let symbol = dlsym(framework, "CGWindowListCreateImage") else { return nil }
    typealias CaptureFunction = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
    let capture = unsafeBitCast(symbol, to: CaptureFunction.self)
    let options = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution])
    return capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, windowID, options.rawValue)?.takeRetainedValue()
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
var probeWindow: NSWindow?

let description = AudioComponentDescription(
    componentType: 0x61756D69,        // aumi
    componentSubType: 0x5270747A,     // Rptz
    componentManufacturer: 0x5250545A, // RPTZ
    componentFlags: 0,
    componentFlagsMask: 0
)

AUAudioUnit.instantiate(with: description, options: [.loadOutOfProcess]) { audioUnit, error in
    guard let audioUnit else {
        print("AU_INSTANTIATION_FAILED: \(error?.localizedDescription ?? "unknown error")")
        app.terminate(nil)
        return
    }
    audioUnit.requestViewController { viewController in
        DispatchQueue.main.async {
            guard let viewController else {
                print("AU_VIEW_FAILED")
                app.terminate(nil)
                return
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = viewController
            window.setContentSize(NSSize(width: 760, height: 700))
            window.layoutIfNeeded()
            window.level = .floating
            window.center()
            window.makeKeyAndOrderFront(nil)
            probeWindow = window
            app.activate(ignoringOtherApps: true)
            print("AU_VIEW_READY: \(Int(viewController.view.bounds.width))x\(Int(viewController.view.bounds.height))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // AUv3 views are remote layer-backed; cacheDisplay can return a
                // solid black image even when the window is correctly composed.
                if let image = compositedWindowImage(CGWindowID(window.windowNumber)) {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        let path = FileManager.default.currentDirectoryPath + "/work/RepeatizerUI.png"
                        try? png.write(to: URL(fileURLWithPath: path))
                        print("AU_VIEW_CAPTURED: \(path)")
                    }
                } else {
                    print("AU_VIEW_CAPTURE_FAILED")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    print("AU_VIEW_STABLE")
                    app.terminate(nil)
                }
            }
        }
    }
}

app.run()
