import AppKit
import Combine

/// Navigation by scrolling while holding ⌃⌥: a trackpad moves the strip 1:1 and snaps to the
/// nearest column when the fingers lift; a mouse wheel steps one column per notch.
///
/// Events come from a CGEventTap so the ones used for navigation can be swallowed: the app under
/// the cursor never sees them. The tap runs on its own thread, so a busy main thread never
/// delays scrolling system-wide; actions are handed to the main thread.
final class Gestures {
    private let engine: StripEngine
    private var tap: ScrollTap?
    private var monitor: Any?
    private var snapWork: DispatchWorkItem?
    private var settingsSub: AnyCancellable?

    init(engine: StripEngine) { self.engine = engine }

    func start() {
        let t = ScrollTap { [weak self] action in
            DispatchQueue.main.async { self?.perform(action) }
        }
        tap = t
        syncEnabled()
        settingsSub = Settings.shared.$gesturesEnabled.sink { [weak self] on in
            guard let self else { return }
            self.tap?.enabled = on && self.engine.enabled
        }
        if !t.start() {
            // No tap (should not happen with Accessibility granted): observe only, can't swallow.
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { ev in
                if let cg = ev.cgEvent { _ = t.handle(type: .scrollWheel, event: cg) }
            }
        }
    }

    /// Call when tiling is turned on or off, so the tap stops swallowing ⌃⌥-scroll when unused.
    func syncEnabled() { tap?.enabled = Settings.shared.gesturesEnabled && engine.enabled }

    private func perform(_ action: ScrollTap.Action) {
        guard Settings.shared.gesturesEnabled, engine.enabled else { return }
        switch action {
        case .scroll(let dx):
            snapWork?.cancel()
            engine.scrollBy(dx)
        case .snap:
            snapWork?.cancel()
            engine.snapToNearest()
        case .snapWhenIdle:
            // Precise deltas without gesture phases (some mice): snap once they stop.
            snapWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.engine.snapToNearest() }
            snapWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
        case .step(let dir):
            if dir < 0 { engine.focusLeft() } else { engine.focusRight() }
        }
    }
}

/// Owns the event tap and the per-gesture state. Everything except `enabled` is only touched on
/// the tap's thread (or on the main thread when the global-monitor fallback is used instead).
final class ScrollTap {
    enum Action { case scroll(CGFloat), snap, snapWhenIdle, step(Int) }

    private enum State { case idle, tracking, momentum }
    private var state = State.idle
    private var port: CFMachPort?
    private let send: (Action) -> Void

    private let lock = NSLock()
    private var _enabled = false
    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }

    // CGScrollPhase / CGMomentumScrollPhase raw values.
    private static let phaseBegan: Int64 = 1, phaseEnded: Int64 = 4, phaseCancelled: Int64 = 8
    private static let momentumEnd: Int64 = 3

    init(send: @escaping (Action) -> Void) { self.send = send }

    /// Creates the tap on a dedicated thread. Returns false if the tap could not be created.
    func start() -> Bool {
        let mask = CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: scrollTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.port = port
        let thread = Thread {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "StripMac scroll tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// Returns true if the event was used for strip navigation and must not reach other apps.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        guard type == .scrollWheel else { return false }
        let flags = event.flags
        let held = flags.contains(.maskControl) && flags.contains(.maskAlternate)
        let precise = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let h = event.getDoubleValueField(precise ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventDeltaAxis2)
        let v = event.getDoubleValueField(precise ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventDeltaAxis1)
        let d = CGFloat(abs(h) >= abs(v) ? h : v)

        // Momentum that follows one of our gestures is swallowed; the strip has already snapped.
        if momentum != 0 {
            guard state == .momentum else { return false }
            if momentum == Self.momentumEnd { state = .idle }
            return true
        }
        if state == .momentum { state = .idle }

        // Trackpad (and Magic Mouse) gestures: decide at .began, then own the whole gesture even
        // if ⌃⌥ is released before the fingers lift.
        if phase != 0 {
            if phase == Self.phaseBegan { state = held && enabled ? .tracking : .idle }
            guard state == .tracking else { return false }
            if phase == Self.phaseEnded || phase == Self.phaseCancelled {
                state = .momentum
                send(.snap)
            } else if d != 0 {
                send(.scroll(-d))
            }
            return true
        }

        // Phase-less events: a classic mouse wheel steps one column per notch.
        guard held, enabled, d != 0 else { return false }
        if precise {
            send(.scroll(-d))
            send(.snapWhenIdle)
        } else {
            send(.step(d > 0 ? -1 : 1))
        }
        return true
    }
}

private func scrollTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<ScrollTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
