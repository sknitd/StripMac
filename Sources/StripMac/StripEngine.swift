import AppKit

final class Column {
    var win: Win
    var width: Double   // fraction of usable screen width
    var applied: CGRect?     // last frame written to the window (AX coords); nil = unknown
    var wroteAt: Date?       // when we last wrote it, to tell our own moves from the user's
    init(win: Win, width: Double) { self.win = win; self.width = width }
}

/// Receives AXObserver notifications on the main run loop and forwards them to the engine.
private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let engine = Unmanaged<StripEngine>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    engine.handleAXNotification(name, element: element)
}

/// One infinite horizontal strip of full-height columns on the main display.
final class StripEngine {
    private(set) var columns: [Column] = []
    private(set) var focus = 0
    private(set) var scroll: CGFloat = 0     // strip x-offset in points
    var enabled = true {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { invalidateFrames(); refresh(); ensureVisible(); layout() }
            else { anim?.invalidate(); releaseWindows() }
        }
    }
    var onLayout: (() -> Void)?

    private var timer: Timer?
    private var anim: Timer?
    private let settings = Settings.shared
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    private var watchers: [pid_t: AppWatcher] = [:]
    private var stalled: [pid_t: Date] = [:]          // apps that timed out, skipped until the date
    private var standardWindows: Set<Win> = []        // cache: standard subrole and resizable
    private var refreshWork: DispatchWorkItem?
    private var geometryWork: DispatchWorkItem?
    private var geometryPending: Set<Win> = []

    var screenArea: CGRect { NSScreen.main?.visibleFrame ?? .zero }   // Cocoa coords, Dock-aware
    var gap: CGFloat { CGFloat(settings.gap) }
    var usableWidth: CGFloat { max(200, screenArea.width - 2 * gap) }

    func start() {
        AX.configureTimeout()
        refresh(); layout()
        // Safety-net poll; AXObserver notifications handle most changes as they happen.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        settings.onChange = { [weak self] in self?.layout() }
    }

    private func tick() {
        guard enabled else { return }
        let stallEnded = expireStalls()
        if refresh() || stallEnded { layout() }
    }

    // MARK: Unresponsive apps

    private func isStalled(_ pid: pid_t) -> Bool { stalled[pid].map { $0 > Date() } ?? false }

    private func markStalled(_ pid: pid_t) { stalled[pid] = Date().addingTimeInterval(3) }

    /// Forgets stalls that have run out. Returns true if any did, so their windows get laid out again.
    private func expireStalls() -> Bool {
        let now = Date(), before = stalled.count
        stalled = stalled.filter { $0.value > now }
        return stalled.count != before
    }

    // MARK: AX notifications

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func watcher(for pid: pid_t) -> AppWatcher {
        if let w = watchers[pid] { return w }
        let w = AppWatcher(pid: pid, callback: axObserverCallback, refcon: refcon)
        watchers[pid] = w
        return w
    }

    fileprivate func handleAXNotification(_ name: String, element: AXUIElement) {
        guard enabled else { return }
        switch name {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            geometryChanged(element)
        default:
            scheduleRefresh()
        }
    }

    /// Coalesces bursts of window events into one refresh.
    func scheduleRefresh() {
        refreshWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.enabled else { return }
            if self.refresh() { self.layout() }
        }
        refreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
    }

    /// A column window moved or resized. Our own writes echo back here, so ignore anything
    /// right after a write; otherwise forget the cached frame so the next layout puts it back.
    private func geometryChanged(_ el: AXUIElement) {
        guard let c = columns.first(where: { CFEqual($0.win.el, el) }) else { return }
        if let t = c.wroteAt, Date().timeIntervalSince(t) < 0.4 { return }
        geometryPending.insert(c.win)
        geometryWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.processGeometryChanges() }
        geometryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    private func processGeometryChanges() {
        let pending = geometryPending
        geometryPending = []
        var changed = false
        for c in columns where pending.contains(c.win) {
            guard let f = c.win.frame else { continue }
            if let last = c.applied, Self.approxEqual(f, last) { continue }
            c.applied = nil
            changed = true
        }
        if changed { layout() }
    }

    static func approxEqual(_ a: CGRect, _ b: CGRect, tolerance t: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) < t && abs(a.minY - b.minY) < t && abs(a.width - b.width) < t && abs(a.height - b.height) < t
    }

    private func invalidateFrames() { for c in columns { c.applied = nil } }

    // MARK: Window discovery

    private func tileable(_ w: Win, excluded: Bool) -> Bool {
        if excluded { return false }
        if !standardWindows.contains(w) {
            // Only cache positives: a window can report an unknown subrole while it is being created.
            guard w.subrole == (kAXStandardWindowSubrole as String), w.isResizable else { return false }
            standardWindows.insert(w)
        }
        return !w.isMinimized && !w.isFullscreen
    }

    /// Syncs columns with live windows. Returns true if anything changed.
    @discardableResult
    func refresh() -> Bool {
        var live: [Win] = []
        var running = Set<pid_t>(), stalledPIDs = Set<pid_t>(), seen = Set<Win>()
        let excludedIDs = settings.excluded
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != selfPID {
            let pid = app.processIdentifier
            running.insert(pid)
            let watcher = watcher(for: pid)
            if app.isHidden { continue }
            if isStalled(pid) { stalledPIDs.insert(pid); continue }
            guard let wins = AX.windows(of: watcher.app, pid: pid) else {
                markStalled(pid); stalledPIDs.insert(pid); continue
            }
            let excluded = app.bundleIdentifier.map { excludedIDs.contains($0) } ?? false
            for w in wins {
                seen.insert(w)
                if tileable(w, excluded: excluded) { live.append(w) }
            }
        }
        standardWindows.formIntersection(seen)
        for (pid, w) in watchers where !running.contains(pid) { w.stop(); watchers[pid] = nil }

        let liveSet = Set(live)
        let before = columns.count
        // Columns of an app that is not answering stay put until it recovers.
        let leaving = columns.filter { !liveSet.contains($0.win) && !stalledPIDs.contains($0.win.pid) }
        columns.removeAll { !liveSet.contains($0.win) && !stalledPIDs.contains($0.win.pid) }
        // A window that left the strip without closing (floated, minimised and restored, …)
        // may still be parked off-screen: bring it back.
        for c in leaving where seen.contains(c.win) || c.win.isAlive { rescueIfOffScreen(c.win) }
        var changed = columns.count != before
        let known = Set(columns.map { $0.win })
        for w in live where !known.contains(w) {
            // New windows open right beside the focused column.
            let idx = columns.isEmpty ? 0 : min(focus + 1, columns.count)
            columns.insert(Column(win: w, width: settings.defaultWidth), at: idx)
            watchers[w.pid]?.watchDestroyed(w)
            changed = true
        }
        focus = columns.isEmpty ? 0 : min(max(focus, 0), columns.count - 1)
        // Track the user's real focus (click / Cmd-Tab) without stealing it.
        if let fw = AX.focusedWindow(), !isStalled(fw.pid),
           let i = columns.firstIndex(where: { $0.win == fw }), i != focus {
            focus = i; ensureVisible(); changed = true
        }
        return changed
    }

    // MARK: Putting windows back

    /// Moves every window the strip manages back on-screen. Called when tiling stops,
    /// on quit, and from the termination/crash handlers.
    func releaseWindows() {
        anim?.invalidate()
        for c in columns where !isStalled(c.win.pid) {
            clampOnScreen(c.win)
            c.applied = nil
        }
    }

    /// Clamps a window into the visible area of the strip's display.
    private func clampOnScreen(_ w: Win, frame: CGRect? = nil) {
        guard let scr = NSScreen.main, w.isAlive, !w.isFullscreen, var r = frame ?? w.frame else { return }
        let vis = AX.toAX(scr.visibleFrame)
        guard vis.width > 0, vis.height > 0 else { return }
        let orig = r
        r.size.width = min(r.width, vis.width)
        r.size.height = min(r.height, vis.height)
        r.origin.x = min(max(r.minX, vis.minX), vis.maxX - r.width)
        r.origin.y = min(max(r.minY, vis.minY), vis.maxY - r.height)
        if r != orig { w.setFrame(r.integral) }
    }

    /// Clamps a window on-screen only if its centre is not on any display.
    private func rescueIfOffScreen(_ w: Win) {
        guard !w.isMinimized, let f = w.frame else { return }
        let centre = AX.flip(CGPoint(x: f.midX, y: f.midY))
        if NSScreen.screens.contains(where: { $0.frame.contains(centre) }) { return }
        clampOnScreen(w, frame: f)
    }

    // MARK: Geometry

    private func colWidth(_ c: Column) -> CGFloat { max(150, (usableWidth + gap) * CGFloat(c.width) - gap) }

    /// x of a column's left edge in strip space (0 = start of strip).
    private func stripX(_ i: Int) -> CGFloat {
        var x: CGFloat = 0
        for j in 0..<min(i, columns.count) { x += colWidth(columns[j]) + gap }
        return x
    }

    var stripLength: CGFloat { columns.isEmpty ? 0 : stripX(columns.count) - gap }

    func ensureVisible() {
        guard columns.indices.contains(focus) else { return }
        let x = stripX(focus), w = colWidth(columns[focus])
        let overflow = stripLength > usableWidth
        switch settings.centerMode {
        case .always:
            scroll = x + w / 2 - usableWidth / 2
        case .onOverflow where overflow:
            scroll = x + w / 2 - usableWidth / 2
        default:
            if x < scroll { scroll = x }
            else if x + w > scroll + usableWidth { scroll = x + w - usableWidth }
        }
        clampScroll()
    }

    private func clampScroll() {
        let maxS = max(0, stripLength - usableWidth)
        if settings.centerMode == .always { return }
        scroll = min(max(scroll, 0), maxS)
    }

    /// Applies frames. Off-screen columns are parked beyond the screen edges.
    func layout() {
        guard enabled else { return }
        let a = screenArea
        var x = a.minX + gap - scroll
        for c in columns {
            let w = colWidth(c)
            let r = CGRect(x: x, y: a.minY + gap, width: w, height: a.height - 2 * gap)
            x += w + gap
            apply(AX.toAX(r).integral, to: c)
        }
        onLayout?()
    }

    /// Writes a frame only if it differs from the last one written, and only the position
    /// when the size is unchanged (the common case while scrolling).
    private func apply(_ r: CGRect, to c: Column) {
        if c.applied == r || isStalled(c.win.pid) { return }
        let err: AXError
        if let last = c.applied, last.size == r.size { err = c.win.setPosition(r.origin) }
        else { err = c.win.setFrame(r) }
        c.wroteAt = Date()
        if err == .cannotComplete { markStalled(c.win.pid) }
        c.applied = err == .success ? r : nil
    }

    /// Short eased scroll animation toward the target scroll value.
    private func animate(to target: CGFloat) {
        anim?.invalidate()
        let from = scroll, steps = 8
        var n = 0
        anim = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            n += 1
            let p = CGFloat(n) / CGFloat(steps)
            let e = 1 - pow(1 - p, 3)
            self.scroll = from + (target - from) * e
            self.layout()
            if n >= steps { t.invalidate() }
        }
    }

    private func scrollToFocus() {
        let old = scroll
        ensureVisible()
        let target = scroll
        scroll = old
        animate(to: target)
    }

    // MARK: Commands

    func focusLeft() { guard focus > 0 else { return }; focus -= 1; columns[focus].win.focus(); scrollToFocus() }
    func focusRight() { guard focus + 1 < columns.count else { return }; focus += 1; columns[focus].win.focus(); scrollToFocus() }
    func focusFirst() { guard !columns.isEmpty else { return }; focus = 0; columns[0].win.focus(); scrollToFocus() }
    func focusLast() { guard !columns.isEmpty else { return }; focus = columns.count - 1; columns[focus].win.focus(); scrollToFocus() }

    func moveLeft() {
        guard focus > 0 else { return }
        columns.swapAt(focus, focus - 1); focus -= 1; scrollToFocus()
    }
    func moveRight() {
        guard focus + 1 < columns.count else { return }
        columns.swapAt(focus, focus + 1); focus += 1; scrollToFocus()
    }

    func cycleWidth() {
        guard columns.indices.contains(focus) else { return }
        let p = settings.presets, cur = columns[focus].width
        columns[focus].width = p.first(where: { $0 > cur + 0.01 }) ?? p[0]
        ensureVisible(); layout()
    }
    func nudgeWidth(_ delta: Double) {
        guard columns.indices.contains(focus) else { return }
        columns[focus].width = min(1.0, max(0.15, columns[focus].width + delta))
        ensureVisible(); layout()
    }
    func fullWidth() {
        guard columns.indices.contains(focus) else { return }
        columns[focus].width = columns[focus].width >= 0.99 ? settings.defaultWidth : 1.0
        ensureVisible(); layout()
    }
    func center() {
        guard columns.indices.contains(focus) else { return }
        let x = stripX(focus), w = colWidth(columns[focus])
        animate(to: x + w / 2 - usableWidth / 2)
    }
    func equalize() {
        for c in columns { c.width = settings.defaultWidth }
        ensureVisible(); layout()
    }

    // MARK: Gesture scrolling (1:1 then snap)

    func scrollBy(_ dx: CGFloat) {
        anim?.invalidate()
        scroll += dx
        layout()
    }

    func snapToNearest() {
        guard !columns.isEmpty else { return }
        let mid = scroll + usableWidth / 2
        var best = 0, bestD = CGFloat.greatestFiniteMagnitude
        for i in columns.indices {
            let c = stripX(i) + colWidth(columns[i]) / 2
            if abs(c - mid) < bestD { bestD = abs(c - mid); best = i }
        }
        focus = best
        columns[focus].win.focus()
        scrollToFocus()
    }

    /// Re-applies every frame, e.g. after a manual re-tile.
    func retile() { invalidateFrames(); refresh(); ensureVisible(); layout() }
}
