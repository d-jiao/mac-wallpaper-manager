import AppKit

@main
enum WallpaperManagerApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only: no Dock icon, no main window.
        app.setActivationPolicy(.accessory)
        // `NSApplication.delegate` is a weak reference, so keep the delegate alive while the app runs.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
