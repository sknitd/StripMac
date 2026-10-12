import AppKit

// Top-level code runs on the main thread; say so, since AppDelegate is @MainActor.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate   // weak: keep our reference alive for as long as the app runs
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
