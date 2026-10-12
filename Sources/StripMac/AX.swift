import AppKit
import ApplicationServices

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

    var title: String { attr(kAXTitleAttribute) ?? "" }
    var subrole: String { attr(kAXSubroleAttribute) ?? "" }
    var isMinimized: Bool { (attr(kAXMinimizedAttribute) as Bool?) ?? false }
    var isFullscreen: Bool { (attr("AXFullScreen") as Bool?) ?? false }

    var isResizable: Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &settable)
        return settable.boolValue
    }

    var frame: CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
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

    func focus() {
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
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
    static func windows(of app: AXUIElement, pid: pid_t) -> [Win]? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
        if err == .cannotComplete { return nil }
        guard err == .success, let arr = v as? [AXUIElement] else { return [] }
        return arr.map { Win(el: $0, pid: pid) }
    }

    static func focusedWindow() -> Win? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let a = AXUIElementCreateApplication(app.processIdentifier)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, kAXFocusedWindowAttribute as CFString, &v) == .success, let v else { return nil }
        return Win(el: v as! AXUIElement, pid: app.processIdentifier)
    }

    /// Converts a Cocoa (bottom-left) rect to AX (top-left) coordinates.
    static func toAX(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
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

    /// Window destruction is only reported to observers registered on the window itself.
    func watchDestroyed(_ w: Win) {
        guard let observer else { return }
        AXObserverAddNotification(observer, w.el, kAXUIElementDestroyedNotification as CFString, refcon)
    }

    func stop() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }
}
