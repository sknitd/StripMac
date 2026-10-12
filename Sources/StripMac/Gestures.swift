import AppKit

/// Trackpad navigation: horizontal two-finger scroll while holding ⌃⌥ (or a three-finger
/// swipe, when macOS delivers it) moves the strip 1:1, then snaps to the nearest column.
final class Gestures {
    private var monitors: [Any] = []
    private let engine: StripEngine
    init(engine: StripEngine) { self.engine = engine }

    func start() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] ev in
            self?.handleScroll(ev)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.swipe], handler: { [weak self] ev in
            self?.handleSwipe(ev)
        }) { monitors.append(m) }
    }

    private func handleScroll(_ ev: NSEvent) {
        guard Settings.shared.gesturesEnabled, engine.enabled else { return }
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.control) && mods.contains(.option) else { return }
        let dx = abs(ev.scrollingDeltaX) >= abs(ev.scrollingDeltaY) ? ev.scrollingDeltaX : ev.scrollingDeltaY
        if dx != 0 { engine.scrollBy(-dx * (ev.hasPreciseScrollingDeltas ? 1 : 12)) }
        if ev.phase == .ended || ev.momentumPhase == .ended || (!ev.hasPreciseScrollingDeltas && dx != 0) {
            engine.snapToNearest()
        }
    }

    private func handleSwipe(_ ev: NSEvent) {
        guard Settings.shared.gesturesEnabled, engine.enabled else { return }
        if ev.deltaX > 0 { engine.focusLeft() } else if ev.deltaX < 0 { engine.focusRight() }
    }
}
