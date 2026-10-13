import AppKit
import SwiftUI
import ServiceManagement

private let crashSignals: [Int32] = [SIGABRT, SIGILL, SIGTRAP, SIGSEGV, SIGBUS, SIGFPE]

/// Last-ditch attempt to put parked windows back before the process dies.
/// Accessibility calls are not async-signal-safe, so this is best effort and main-thread only.
private func releaseWindowsBeforeDying() {
    guard Thread.isMainThread else { return }
    MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.releaseWindows() }
}

private func crashSignalHandler(_ sig: Int32) {
    for s in crashSignals { signal(s, SIG_DFL) }
    releaseWindowsBeforeDying()
    raise(sig)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) lazy var engine = StripEngine()
    private var status: NSStatusItem!
    private var gestures: Gestures?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var trustTimer: Timer?
    private var toggleItem: NSMenuItem!
    private lazy var minimap = Minimap()

    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        installTerminationHandlers()
        if AX.trusted { startEngine() } else { showOnboarding() }
    }

    func applicationWillTerminate(_ n: Notification) { releaseWindows() }

    /// Puts every managed window back on-screen so nothing stays parked past the screen edge.
    func releaseWindows() {
        guard started else { return }
        engine.releaseWindows()
    }

    /// Quits cleanly (restoring windows) on SIGTERM/SIGINT/SIGHUP, and tries to restore
    /// windows on crashes and uncaught exceptions.
    private func installTerminationHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            src.resume()
            signalSources.append(src)
        }
        for sig in crashSignals { signal(sig, crashSignalHandler) }
        NSSetUncaughtExceptionHandler { _ in releaseWindowsBeforeDying() }
    }

    private func buildMenu() {
        // New status items are added at the far left of the icon area, which on a crowded notched
        // MacBook lands behind the notch and is hidden. Seed a position near the clock instead
        // (points from the right screen edge); after a ⌘-drag, macOS saves the user's choice here.
        let posKey = "NSStatusItem Preferred Position StripMac"
        if UserDefaults.standard.object(forKey: posKey) == nil { UserDefaults.standard.set(260, forKey: posKey) }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.autosaveName = "StripMac"
        status.button?.image = Self.stripGlyph()
        let m = NSMenu()
        toggleItem = NSMenuItem(title: "Stop Tiling", action: #selector(toggle), keyEquivalent: "")
        m.addItem(toggleItem)
        m.addItem(NSMenuItem(title: "Re-tile Now", action: #selector(retile), keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        m.addItem(NSMenuItem(title: "Accessibility Setup…", action: #selector(showOnboarding), keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit StripMac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for i in m.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
        status.menu = m
    }

    /// Menu-bar glyph: a solid focused column flanked by two outlined columns that run off the
    /// edges, with chevrons hinting that the strip scrolls. Template image, so it follows the menu bar tint.
    private static func stripGlyph() -> NSImage {
        let img = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
            NSColor.black.set()
            NSBezierPath(roundedRect: NSRect(x: 8.5, y: 2, width: 7, height: 14), xRadius: 1.8, yRadius: 1.8).fill()
            for x in [3.0, 17.0] {
                let side = NSBezierPath(roundedRect: NSRect(x: x, y: 4, width: 4, height: 10), xRadius: 1.2, yRadius: 1.2)
                side.lineWidth = 1.3
                side.stroke()
            }
            let chevrons = NSBezierPath()
            chevrons.move(to: NSPoint(x: 1.8, y: 7)); chevrons.line(to: NSPoint(x: 0.4, y: 9)); chevrons.line(to: NSPoint(x: 1.8, y: 11))
            chevrons.move(to: NSPoint(x: 22.2, y: 7)); chevrons.line(to: NSPoint(x: 23.6, y: 9)); chevrons.line(to: NSPoint(x: 22.2, y: 11))
            chevrons.lineWidth = 1.2
            chevrons.lineCapStyle = .round
            chevrons.lineJoinStyle = .round
            chevrons.stroke()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "StripMac"
        return img
    }

    private var started = false
    func startEngine() {
        guard !started else { return }
        started = true
        onboardingWindow?.close()
        engine.onLayout = { [weak self] in
            guard let self, Settings.shared.showMinimap else { return }
            self.minimap.show(engine: self.engine)
        }
        engine.onAccessChanged = { [weak self] granted in
            // Revoked while running: explain and wait; the engine resumes on its own once granted.
            if granted { self?.onboardingWindow?.close() } else { self?.showOnboarding() }
        }
        engine.start()
        let bindings = DefaultBindings.all(engine: engine, toggle: { [weak self] in self?.toggle() })
        bindings.forEach { Hotkeys.shared.register($0) }
        gestures = Gestures(engine: engine)
        gestures?.start()
    }

    @objc func toggle() {
        engine.enabled.toggle()
        toggleItem.title = engine.enabled ? "Stop Tiling" : "Start Tiling"
        gestures?.syncEnabled()
    }

    @objc func retile() { engine.retile() }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "StripMac Settings"
            w.isReleasedWhenClosed = false
            let names = DefaultBindings.all(engine: engine, toggle: {}).map { $0.name }
            w.contentView = NSHostingView(rootView: SettingsView(s: Settings.shared, hotkeys: Hotkeys.shared, bindings: names))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showOnboarding() {
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Welcome to StripMac"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView())
            w.delegate = self
            w.center()
            onboardingWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        // Only wait for the permission before tiling has started; opened later from the menu,
        // the window stays until the user closes it.
        guard !started else { return }
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                if AX.trusted { t.invalidate(); self?.startEngine() }
            }
        }
    }

    /// Drop the onboarding window once closed, so its view (and its 1 s status timer) goes away.
    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, w === onboardingWindow else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if self?.onboardingWindow === w { self?.onboardingWindow = nil }
            }
        }
    }
}

@MainActor
struct OnboardingView: View {
    @State private var trusted = AX.trusted
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your windows, on an endless strip.").font(.title2).bold()
            Text("StripMac lays every window side by side in full-height columns. Nothing overlaps and nothing gets squeezed — the strip just gets longer and you scroll.")
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("StripMac needs the Accessibility permission to move and resize windows. It is the only permission it uses, and nothing leaves your Mac.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(trusted ? .green : .orange)
                Text(trusted ? "Accessibility access granted" : "Accessibility access not granted yet")
            }
            HStack {
                Button("Grant Access…") { AX.promptForTrust() }.disabled(trusted)
                Button("Open System Settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
            Divider()
            Text("The five shortcuts to know").bold()
            Text("⌃⌥← / →  focus left / right\n⌃⌥⇧← / →  move window\n⌃⌥R  cycle widths\n⌃⌥F  full width\n⌃⌥ + two-finger horizontal scroll  swipe the strip")
                .font(.system(.body, design: .monospaced))
        }
        .padding(22)
        .frame(width: 460)
        .onReceive(timer) { _ in trusted = AX.trusted }
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var s: Settings
    @ObservedObject var hotkeys: Hotkeys
    let bindings: [String]
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var previewAllowed = WindowPreview.canCapture

    /// Why macOS would also react to a swipe with this many fingers, or nil if nothing clashes.
    static func systemClash(fingers: Int) -> String? {
        let tp = UserDefaults(suiteName: "com.apple.AppleMultitouchTrackpad")
        if fingers == 3, tp?.integer(forKey: "TrackpadThreeFingerDrag") == 1 {
            return "Three-finger drag is on, so three-finger swipes drag instead. Pick four fingers, or turn off three-finger drag."
        }
        let key = fingers == 3 ? "TrackpadThreeFingerHorizSwipeGesture" : "TrackpadFourFingerHorizSwipeGesture"
        guard tp?.integer(forKey: key) == 2 else { return nil }   // 2 = switches Spaces
        let other = fingers == 3 ? "four" : "three"
        return "macOS also switches Spaces with \(fingers == 3 ? "three" : "four") fingers, so both will react. Set Trackpad → More Gestures → \"Swipe between full-screen applications\" to \(other) fingers, or pick the other count here."
    }
    @State private var loginError: String?

    /// Reflects the real service status; the setter calls the service once and re-reads the
    /// status, so a failure can't bounce the toggle back and forth.
    private var launchAtLogin: Binding<Bool> {
        Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: { on in setLaunchAtLogin(on) })
    }

    private func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }

    var body: some View {
        TabView {
            Form {
                Slider(value: $s.gap, in: 0...40, step: 1) { Text("Gap: \(Int(s.gap)) pt") }
                Slider(value: $s.defaultWidth, in: 0.2...1.0, step: 0.05) { Text("New window width: \(Int(s.defaultWidth * 100))%") }
                TextField("Preset widths (fractions)", text: $s.presetsText)
                Picker("Strip display", selection: $s.stripDisplayID) {
                    Text("Primary display").tag(0)
                    ForEach(NSScreen.screens, id: \.displayID) { Text($0.localizedName).tag($0.displayID) }
                }
                Picker("Centre focused column", selection: $s.centerMode) {
                    ForEach(CenterMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle(isOn: $s.gesturesEnabled) {
                    Text("Scroll navigation (hold ⌃⌥ + scroll)")
                    Text("Trackpad or Magic Mouse: the strip follows your fingers and snaps to a column. Mouse wheel: one column per notch.")
                }
                Toggle(isOn: $s.trackpadSwipe) {
                    Text("Trackpad swipe")
                    Text("Swipe left or right to move one window. Past either end it switches to your full-screen apps, like the native swipe between Spaces.")
                }
                Picker("Fingers", selection: $s.swipeFingers) {
                    Text("Three").tag(3)
                    Text("Four").tag(4)
                }
                .pickerStyle(.segmented)
                .disabled(!s.trackpadSwipe)
                if s.trackpadSwipe, let clash = Self.systemClash(fingers: s.swipeFingers) {
                    HStack {
                        Text(clash).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Button("Open Trackpad Settings") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") { NSWorkspace.shared.open(u) }
                        }
                    }
                }
                Toggle(isOn: $s.showMinimap) {
                    Text("Show strip map while navigating")
                    Text("Hover to keep it open, click a window to jump to it, hover 2 s for a preview, press and hold 3 s to reorder. Each window shows its app's RAM use; × quits the app.")
                }
                if !previewAllowed {
                    HStack {
                        Text("Live window previews need Screen Recording permission.").foregroundStyle(.secondary)
                        Button("Allow…") {
                            if !CGRequestScreenCaptureAccess(),
                               let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(u)
                            }
                            previewAllowed = WindowPreview.canCapture
                        }
                    }
                }
                Toggle("Launch at login", isOn: launchAtLogin)
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Allow StripMac in Login Items to finish.").foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Text("Apps that float (bundle IDs, comma separated):")
                TextField("", text: $s.excludedBundleIDs)
                Text("Fixed-size windows always float automatically.").foregroundStyle(.secondary)
            }
            .padding()
            .tabItem { Label("Rules", systemImage: "list.bullet") }

            List(bindings, id: \.self) { name in
                HStack {
                    Text(name).font(.system(.body, design: .monospaced))
                    if hotkeys.failed.contains(name) {
                        Spacer()
                        Label("Taken by another app", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 480)
    }
}
