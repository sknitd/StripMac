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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = StripEngine()
    private var status: NSStatusItem!
    private var gestures: Gestures?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var trustTimer: Timer?
    private var toggleItem: NSMenuItem!
    let minimap = Minimap()

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
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "StripMac")
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

    private var started = false
    func startEngine() {
        guard !started else { return }
        started = true
        onboardingWindow?.close()
        engine.onLayout = { [weak self] in
            guard let self, Settings.shared.showMinimap else { return }
            self.minimap.show(engine: self.engine)
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
    }

    @objc func retile() { engine.retile() }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "StripMac Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(bindings: DefaultBindings.all(engine: engine, toggle: {}).map { $0.name }))
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
            w.center()
            onboardingWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            if AX.trusted { t.invalidate(); self?.startEngine() }
        }
    }
}

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

struct SettingsView: View {
    @ObservedObject var s = Settings.shared
    let bindings: [String]
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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
                Toggle("Trackpad swipe navigation (⌃⌥ + scroll)", isOn: $s.gesturesEnabled)
                Toggle("Show strip minimap while navigating", isOn: $s.showMinimap)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = !on }
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

            List(bindings, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 480)
    }
}
