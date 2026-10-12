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

    /// Frame is in AX (top-left origin) global coordinates.
    func setFrame(_ r: CGRect) {
        var p = r.origin, s = r.size
        if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv) }
        if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv) }
        if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv) }
    }

    func setPosition(_ pt: CGPoint) {
        var p = pt
        if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv) }
    }

    func focus() {
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}

enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func windows(of app: NSRunningApplication) -> [Win] {
        let a = AXUIElementCreateApplication(app.processIdentifier)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, kAXWindowsAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr.map { Win(el: $0, pid: app.processIdentifier) }
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
