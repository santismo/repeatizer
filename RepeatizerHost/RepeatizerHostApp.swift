import SwiftUI

@main
struct RepeatizerHostApp: App {
    var body: some Scene {
        // This is only the required AUv3 container. LSUIElement keeps it out of
        // the Dock and this empty Settings scene deliberately creates no window.
        Settings {
            EmptyView()
        }
    }
}
