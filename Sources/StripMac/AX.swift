import AppKit
import ApplicationServices
import QuartzCore

/// Private but long-stable HIServices call mapping an AX window to its CGWindowID
/// (used the same way by Rectangle, yabai and AeroSpace).
@_silgen_name("_AXUIElementGetWindow") @discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

/// Hashable wrapper around an AXUIElement window reference.
struct Win: Hashable {
    let el: AXUIElement
    let pid: pid_t

    static func == (a: Win, b: Win) -> Bool { CFEqual(a.el, b.el) }
    func hash(into h: inout Hasher) { h.combine(CFHash(el)) }

    func attr<T>(_ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }

    var isAlive: Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success
    }

    var subrole: String { attr(kAXSubroleAttribute) ?? "" }
    var title: String { attr(kAXTitleAttribute) ?? "" }

    /// Closes just this window, as its red close button would (the app may ask to save).
    @discardableResult
    func close() -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXCloseButtonAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(unsafeBitCast(v, to: AXUIElement.self), kAXPressAction as CFString) == .success
    }
    var isMinimized: Bool { (attr(kAXMinimizedAttribute) as Bool?) ?? false }
    var isFullscreen: Bool { (attr("AXFullScreen") as Bool?) ?? false }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success && id != 0 ? id : nil
    }

    var isResizable: Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &settable)
        return settable.boolValue
    }

    /// An attribute's AXValue, type-checked before it is treated as one.
    private func axValue(_ name: String) -> AXValue? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXValue.self)
    }

    /// Frame in AX (top-left origin) global coordinates.
    var frame: CGRect? {
        guard let pv = axValue(kAXPositionAttribute), let sv = axValue(kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Frame is in AX (top-left origin) global coordinates. Returns the first error that matters.
    @discardableResult
    func setFrame(_ r: CGRect) -> AXError {
        var p = r.origin, s = r.size
        guard let sv = AXValueCreate(.cgSize, &s), let pv = AXValueCreate(.cgPoint, &p) else { return .failure }
        // Size, position, size: the second size fixes windows that couldn't grow at their old position.
        let e1 = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv)
        if e1 == .cannotComplete { return e1 }
        let e2 = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv)
        if e2 == .cannotComplete { return e2 }
        let e3 = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv)
        return e2 != .success ? e2 : e3
    }

    @discardableResult
    func setPosition(_ pt: CGPoint) -> AXError {
        var p = pt
        guard let pv = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv)
    }

    /// Raises the window and gives its app keyboard focus. Under macOS 14 cooperative activation,
    /// `NSRunningApplication.activate()` from a background app is often refused, so the app is
    /// made frontmost through Accessibility, with `activate()` only as a fallback.
    @discardableResult
    func focus() -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        let front = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let focused = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, el)
        if front != .success {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        return raised == .success && (front == .success || focused == .success)
    }
}

enum AX {
    /// Upper bound for any single Accessibility request. A hung app costs at most this per call
    /// instead of the system default of about 6 s.
    static let timeout: Float = 0.25

    static var trusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Applies `timeout` to every Accessibility request this process makes.
    static func configureTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)
    }

    /// The app's windows, or nil if the app did not answer in time.
    /// How many ordinary document windows an app has open (any Space, minimised included).
    static func standardWindowCount(pid: pid_t) -> Int {
        (windows(of: AXUIElementCreateApplication(pid), pid: pid) ?? []).filter { $0.subrole == kAXStandardWindowSubrole as String }.count
    }

    static func windows(of app: AXUIElement, pid: pid_t) -> [Win]? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
        if err == .cannotComplete { return nil }
        guard err == .success, let arr = v as? [AXUIElement] else { return [] }
        return arr.map { Win(el: $0, pid: pid) }
    }

    /// IDs of windows ordered in on the current Space. Minimised windows, background tabs,
    /// hidden apps and other Spaces are missing; position on or off the display doesn't matter.
    static func onScreenWindowIDs() -> Set<CGWindowID>? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]], !list.isEmpty else { return nil }
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    static func focusedWindow() -> Win? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let a = AXUIElementCreateApplication(app.processIdentifier)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, kAXFocusedWindowAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return Win(el: unsafeBitCast(v, to: AXUIElement.self), pid: app.processIdentifier)
    }

    /// Converts a Cocoa (bottom-left) rect to AX (top-left) coordinates.
    static func toAX(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// Converts a point between Cocoa and AX coordinates (the flip is its own inverse).
    static func flip(_ p: CGPoint) -> CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }
}

/// Per-app Accessibility element plus an AXObserver that reports window events,
/// so the strip reacts to changes without polling every window.
final class AppWatcher {
    let pid: pid_t
    let app: AXUIElement
    private var observer: AXObserver?
    private let refcon: UnsafeMutableRawPointer

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification,
    ]

    init(pid: pid_t, callback: AXObserverCallback, refcon: UnsafeMutableRawPointer) {
        self.pid = pid
        self.refcon = refcon
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AX.timeout)
        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        for n in Self.appNotifications { AXObserverAddNotification(obs, app, n as CFString, refcon) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
    }

    /// Destruction is only reported to observers registered on the window itself; moves and
    /// resizes are registered there too, since not every app forwards them to the app element.
    func watchWindow(_ w: Win) {
        guard let observer else { return }
        for n in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(observer, w.el, n as CFString, refcon)
        }
    }

    func stop() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }
}

// AXUIElement is a CFType and safe to message from any thread.
extension Win: @unchecked Sendable {}

/// Writes window frames off the main thread, on one serial queue per app, so a slow app never
/// stalls the animation or the other apps. Writes are coalesced: while an app is busy, only the
/// newest target per window is kept, so a lagging app skips frames instead of falling behind.
final class AXWriter: @unchecked Sendable {
    private struct Job { let rect: CGRect; let moveOnly: Bool }
    private let lock = NSLock()
    private var pending: [pid_t: [Win: Job]] = [:]
    private var busy: Set<pid_t> = []
    private var queues: [pid_t: DispatchQueue] = [:]
    private var latencies: [pid_t: Double] = [:]   // smoothed seconds per window write
    private let onResult: @Sendable (Win, CGRect, AXError) -> Void

    init(onResult: @escaping @Sendable (Win, CGRect, AXError) -> Void) { self.onResult = onResult }

    private func queue(_ pid: pid_t) -> DispatchQueue {   // call with lock held
        if let q = queues[pid] { return q }
        let q = DispatchQueue(label: "StripMac.ax.\(pid)", qos: .userInteractive)
        queues[pid] = q
        return q
    }

    func write(_ win: Win, _ rect: CGRect, moveOnly: Bool) {
        lock.lock()
        // A pending full write must stay a full write even if a later frame only moves.
        let keepFull = pending[win.pid]?[win].map { !$0.moveOnly } ?? false
        pending[win.pid, default: [:]][win] = Job(rect: rect, moveOnly: moveOnly && !keepFull)
        let start = busy.insert(win.pid).inserted
        let q = queue(win.pid)
        lock.unlock()
        if start { q.async { self.drain(win.pid) } }
    }

    /// Runs `body` on the app's queue, after any writes already queued for it.
    func run(on pid: pid_t, _ body: @escaping @Sendable () -> Void) {
        lock.lock(); let q = queue(pid); lock.unlock()
        q.async(execute: body)
    }

    private func drain(_ pid: pid_t) {
        while true {
            lock.lock()
            guard let jobs = pending.removeValue(forKey: pid), !jobs.isEmpty else {
                busy.remove(pid); lock.unlock(); return
            }
            lock.unlock()
            for (win, job) in jobs {
                let t0 = CACurrentMediaTime()
                let err = job.moveOnly ? win.setPosition(job.rect.origin) : win.setFrame(job.rect)
                if job.moveOnly && err == .success {
                    let dt = CACurrentMediaTime() - t0
                    lock.lock()
                    latencies[pid] = latencies[pid].map { $0 * 0.7 + dt * 0.3 } ?? dt
                    lock.unlock()
                }
                onResult(win, job.rect, err)
            }
        }
    }

    /// How long a move of one of this app's windows typically takes to land (0 until measured).
    func latency(_ pid: pid_t) -> Double {
        lock.lock(); defer { lock.unlock() }
        return latencies[pid] ?? 0
    }

    /// Drops queued writes and waits for in-flight ones, so callers can write final frames.
    func cancelAndWait() {
        lock.lock(); pending.removeAll(); let qs = Array(queues.values); lock.unlock()
        for q in qs { q.sync {} }
    }
}

/// Drives a callback on every refresh of a screen (macOS 14 `NSScreen.displayLink`).
@MainActor
final class FrameDriver: NSObject {
    private var link: CADisplayLink?
    private var tick: (@MainActor () -> Bool)?

    /// `tick` returns false to stop.
    func start(on screen: NSScreen, _ tick: @escaping @MainActor () -> Bool) {
        stop()
        self.tick = tick
        let l = screen.displayLink(target: self, selector: #selector(step))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() { link?.invalidate(); link = nil; tick = nil }
    var isRunning: Bool { link != nil }

    @objc private func step(_ l: CADisplayLink) {
        if tick?() != true { stop() }
    }
}

enum Spaces {
    /// Sends the system "Move left/right a space" shortcut (⌃← / ⌃→), the same switch a
    /// trackpad swipe makes, so full-screen apps continue the strip on either side.
    static func switchSpace(_ dir: Int) {
        let key: CGKeyCode = dir > 0 ? 124 : 123
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            e.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            e.post(tap: .cghidEventTap)
        }
    }

    /// True when the frontmost window is a native full-screen window (its own Space).
    @MainActor static var inFullScreenSpace: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return false }
        return Win(el: unsafeBitCast(v, to: AXUIElement.self), pid: app.processIdentifier).isFullscreen
    }
}
