import AppKit

/// Three- or four-finger horizontal swipe on a trackpad (whichever macOS isn't using): one swipe
/// moves one window, like the native swipe between Spaces. Past either end of the strip it switches to the adjacent
/// Space, so full-screen apps continue the strip. No modifier needed.
///
/// macOS does not deliver finger counts to event taps, so raw touches are read from the private
/// MultitouchSupport framework (as Jitouch, MiddleClick and BetterTouchTool do). It is loaded with
/// dlopen, so nothing links against it and StripMac still runs if it ever goes away. These touches
/// are observed, not swallowed: if macOS uses the same finger count for swiping between Spaces,
/// both react, so pick the count macOS isn't using.
final class TrackpadSwipe: @unchecked Sendable {
    enum Action { case swipe(Int) }   // +1: fingers moved left (go to the next window), -1: right

    private typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                                        Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, ContactCallback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private struct API { let create: CreateList; let register: Register; let unregister: Register; let start: Start; let stop: Stop }
    private static let api: API? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
              let c = dlsym(h, "MTDeviceCreateList"), let r = dlsym(h, "MTRegisterContactFrameCallback"),
              let u = dlsym(h, "MTUnregisterContactFrameCallback"), let s = dlsym(h, "MTDeviceStart"),
              let t = dlsym(h, "MTDeviceStop") else { return nil }
        return API(create: unsafeBitCast(c, to: CreateList.self), register: unsafeBitCast(r, to: Register.self),
                   unregister: unsafeBitCast(u, to: Register.self), start: unsafeBitCast(s, to: Start.self),
                   stop: unsafeBitCast(t, to: Stop.self))
    }()

    /// The C callback has no context pointer, so it reaches the instance through this.
    nonisolated(unsafe) fileprivate static var current: TrackpadSwipe?

    private let send: @Sendable (Action) -> Void
    private var devices: CFArray?
    private var wakeObserver: NSObjectProtocol?

    private let lock = NSLock()
    private var _enabled = false
    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }
    private var _fingers = 3
    /// How many fingers make the gesture (3 or 4).
    var fingers: Int {
        get { lock.lock(); defer { lock.unlock() }; return _fingers }
        set { lock.lock(); _fingers = newValue; lock.unlock() }
    }

    // Per-gesture state; only touched on the multitouch thread.
    private enum Phase { case idle, pending, done }
    private var phase = Phase.idle
    private var startX = 0.0, startY = 0.0, startSpread = 0.0

    init(send: @escaping @Sendable (Action) -> Void) { self.send = send }

    /// Returns false if the framework or a trackpad is unavailable.
    @discardableResult
    func start() -> Bool {
        guard let api = Self.api else { return false }
        Self.current = self
        attach(api)
        // Multitouch devices can stop reporting after sleep; re-attach on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let api = Self.api else { return }
            self.detach(api); self.attach(api)
        }
        return (devices.map(CFArrayGetCount) ?? 0) > 0
    }

    private func attach(_ api: API) {
        guard let list = api.create()?.takeRetainedValue() else { return }
        devices = list
        for i in 0..<CFArrayGetCount(list) {
            let dev = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, i))
            api.register(dev, contactFrameCallback)
            api.start(dev, 0)
        }
    }

    private func detach(_ api: API) {
        guard let list = devices else { return }
        for i in 0..<CFArrayGetCount(list) {
            let dev = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, i))
            api.unregister(dev, contactFrameCallback)
            api.stop(dev)
        }
        devices = nil
    }

    // MTTouch layout (96 bytes): state Int32 at 20, normalized position Float x/y at 32/36.
    private static let stride = 96, stateOffset = 20, xOffset = 32, yOffset = 36

    fileprivate func frame(_ touches: UnsafeMutableRawPointer?, count: Int) {
        guard let touches, enabled else { phase = .idle; return }
        var xs: [Double] = [], ys: [Double] = []
        for i in 0..<count {
            let t = touches + i * Self.stride
            let state = t.load(fromByteOffset: Self.stateOffset, as: Int32.self)
            guard state == 3 || state == 4 else { continue }   // make-touch / touching
            xs.append(Double(t.load(fromByteOffset: Self.xOffset, as: Float.self)))
            ys.append(Double(t.load(fromByteOffset: Self.yOffset, as: Float.self)))
        }
        let n = fingers
        guard xs.count == n else { phase = .idle; return }
        let x = xs.reduce(0, +) / Double(n), y = ys.reduce(0, +) / Double(n)
        let spread = zip(xs, ys).map { hypot($0 - x, $1 - y) }.reduce(0, +) / Double(n)
        switch phase {
        case .idle:
            (startX, startY, startSpread, phase) = (x, y, spread, .pending)
        case .pending:
            let dx = x - startX, dy = y - startY
            // Thumb + three fingers pinch/spread (Launchpad, Show Desktop) changes the spread, not the centre.
            // One action per gesture, fired as soon as the swipe is clear, so it feels immediate.
            if abs(spread - startSpread) > 0.05 || abs(dy) > 0.06 { phase = .done }
            else if abs(dx) > 0.04 && abs(dx) > 1.5 * abs(dy) { phase = .done; send(.swipe(dx < 0 ? 1 : -1)) }
        case .done:
            break
        }
    }
}

private func contactFrameCallback(_ device: UnsafeMutableRawPointer?, _ touches: UnsafeMutableRawPointer?,
                                  _ count: Int32, _ timestamp: Double, _ frame: Int32) -> Int32 {
    TrackpadSwipe.current?.frame(touches, count: Int(count))
    return 0
}
