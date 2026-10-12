import AppKit

extension NSScreen {
    /// The CGDirectDisplayID, stable across reconfigurations (unlike the index in `screens`).
    var displayID: Int { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0 }
}

/// Runs `body` on the main actor after `delay`; cancel the returned item to drop it.
@MainActor @discardableResult
func runOnMain(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> DispatchWorkItem {
    let w = DispatchWorkItem { MainActor.assumeIsolated(body) }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    return w
}

final class Column {
    var win: Win
    var width: Double   // fraction of usable screen width
    var widthBeforeFull: Double?   // restored when full width is toggled off
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
    // Observer sources are added to the main run loop, so this runs on the main thread.
    MainActor.assumeIsolated { engine.handleAXNotification(name, element: element) }
}

/// One infinite horizontal strip of full-height columns, pinned to one display.
@MainActor
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
    var onLayout: (@MainActor () -> Void)?
    /// Called with false when Accessibility access is revoked, and true when it is back.
    var onAccessChanged: (@MainActor (Bool) -> Void)?
    private(set) var accessLost = false

    private var timer: Timer?
    private var anim: Timer?
    private let settings = Settings.shared
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    private var watchers: [pid_t: AppWatcher] = [:]
    private var stalled: [pid_t: Date] = [:]          // apps that timed out, skipped until the date
    private var standardWindows: Set<Win> = []        // cache: standard subrole and resizable
    private var refreshWork: DispatchWorkItem?
    private var geometryWork: DispatchWorkItem?
    private var geometryPending: [Win: Bool] = [:]    // window → was resized
    private var observers: [NSObjectProtocol] = []
    /// Window we just asked to focus. App activation is asynchronous, so until it reports focus
    /// (or the deadline passes) the system's stale focused window must not override ours.
    private var expectedFocus: (win: Win, until: Date)?
    private var screenWork: DispatchWorkItem?

    /// Windows that left the strip but are still alive (minimised, fullscreen, hidden app,
    /// other Space, background tab), with enough to put them back where they were.
    private struct Suspended { let width: Double; let index: Int; let left: Win? }
    private var suspended: [Win: Suspended] = [:]
    private var lastSweep = Date()
    private var windowIDs: [Win: CGWindowID] = [:]

    /// The display the strip lives on: the one chosen in Settings, else the primary display.
    /// (Not `NSScreen.main`, which follows keyboard focus from display to display.)
    var stripScreen: NSScreen? {
        let screens = NSScreen.screens, id = settings.stripDisplayID
        if id != 0, let s = screens.first(where: { $0.displayID == id }) { return s }
        return screens.first
    }

    var screenArea: CGRect { stripScreen?.visibleFrame ?? .zero }   // Cocoa coords, Dock-aware
    var gap: CGFloat { CGFloat(settings.gap) }
    var usableWidth: CGFloat { max(200, screenArea.width - 2 * gap) }

    func start() {
        AX.configureTimeout()
        refresh(); layout()
        // Safety-net poll; AXObserver notifications handle most changes as they happen.
        // Common run-loop modes keep it running while a menu is open or a slider is dragged.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        settings.onChange = { [weak self] in self?.ensureVisible(); self?.layout() }
        let wnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.screensChanged() } })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            })
        }
    }

    /// Displays were added, removed, rearranged or woke up, or the Dock/resolution changed:
    /// re-lay out everything once things settle.
    private func screensChanged() {
        screenWork?.cancel()
        screenWork = runOnMain(after: 0.5) { [weak self] in
            guard let self, self.enabled, !self.accessLost else { return }
            self.invalidateFrames()
            self.refresh()
            self.ensureVisible()
            self.layout()
        }
    }

    private func tick() {
        // Accessibility can be revoked while running: every AX call would fail and refresh would
        // empty the strip. Freeze instead, and pick up again once access comes back.
        guard AX.trusted else {
            if !accessLost { accessLost = true; anim?.invalidate(); onAccessChanged?(false) }
            return
        }
        if accessLost {
            accessLost = false
            onAccessChanged?(true)
            if enabled { invalidateFrames(); refresh(); ensureVisible(); layout() }
            return
        }
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
        guard enabled, !accessLost else { return }
        switch name {
        case kAXWindowMovedNotification, kAXMovedNotification:
            geometryChanged(element, resized: false)
        case kAXWindowResizedNotification, kAXResizedNotification:
            geometryChanged(element, resized: true)
        default:
            scheduleRefresh()
        }
    }

    /// Coalesces bursts of window events into one refresh.
    func scheduleRefresh() {
        refreshWork?.cancel()
        refreshWork = runOnMain(after: 0.08) { [weak self] in
            guard let self, self.enabled, !self.accessLost else { return }
            if self.refresh() { self.layout() }
        }
    }

    /// A column window moved or resized. Our own writes echo back here, so ignore anything
    /// right after a write. Otherwise, once the user lets go: a new width becomes the column's
    /// width, and anything else is put back in place by the next layout.
    private func geometryChanged(_ el: AXUIElement, resized: Bool) {
        guard let c = columns.first(where: { CFEqual($0.win.el, el) }) else { return }
        if let t = c.wroteAt, Date().timeIntervalSince(t) < 0.4 { return }
        geometryPending[c.win] = (geometryPending[c.win] ?? false) || resized
        geometryWork?.cancel()
        geometryWork = runOnMain(after: 0.35) { [weak self] in self?.processGeometryChanges() }
    }

    private func processGeometryChanges() {
        let pending = geometryPending
        geometryPending = [:]
        var changed = false
        var dragged: Set<Win> = []
        for c in columns {
            guard let resized = pending[c.win], let f = c.win.frame else { continue }
            if let last = c.applied, Self.approxEqual(f, last) { continue }
            if resized, abs(f.width - (c.applied?.width ?? colWidth(c))) >= 2 {
                c.width = min(1.0, max(0.1, Double((f.width + gap) / (usableWidth + gap))))
                c.widthBeforeFull = nil
            } else if !resized, let id = displayID(containing: f), id != stripScreen?.displayID {
                // Dragged onto another display: it leaves the strip and floats there.
                dragged.insert(c.win)
            }
            c.applied = nil
            changed = true
        }
        if !dragged.isEmpty {
            _ = removeColumns { dragged.contains($0.win) }
            ensureVisible()
        }
        if changed { ensureVisible(); layout() }
    }

    static func approxEqual(_ a: CGRect, _ b: CGRect, tolerance t: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) < t && abs(a.minY - b.minY) < t && abs(a.width - b.width) < t && abs(a.height - b.height) < t
    }

    private func invalidateFrames() { for c in columns { c.applied = nil } }

    /// The display under the centre of an AX-coordinate frame, if any.
    private func displayID(containing f: CGRect) -> Int? {
        let centre = AX.flip(CGPoint(x: f.midX, y: f.midY))
        return NSScreen.screens.first(where: { $0.frame.contains(centre) })?.displayID
    }

    /// New windows join the strip only if they open on its display, or nowhere visible at all
    /// (e.g. left parked by an earlier session).
    private func admits(frame f: CGRect?) -> Bool {
        guard let f else { return true }
        guard let id = displayID(containing: f) else { return true }
        return id == stripScreen?.displayID
    }

    // MARK: Window discovery

    private enum Kind { case tile, float, away }

    /// tile: belongs on the strip. float: shown but not ours (float-listed app, panel, fixed size).
    /// away: alive but not shown right now (minimised, fullscreen, other Space, background tab).
    private func classify(_ w: Win, excluded: Bool, onScreen: Set<CGWindowID>?) -> Kind {
        if excluded { return .float }
        if !standardWindows.contains(w) {
            // Only cache positives: a window can report an unknown subrole while it is being created.
            guard w.subrole == (kAXStandardWindowSubrole as String), w.isResizable else { return .float }
            standardWindows.insert(w)
        }
        if let onScreen, let id = windowID(w) {
            if !onScreen.contains(id) { return .away }
        } else if w.isMinimized {
            return .away
        }
        return w.isFullscreen ? .away : .tile
    }

    private func windowID(_ w: Win) -> CGWindowID? {
        if let id = windowIDs[w] { return id }
        let id = w.windowID
        windowIDs[w] = id
        return id
    }

    /// Removes columns, keeping focus on the same window, or on its nearest neighbour if that
    /// window went. Returns what was removed with its old index and left neighbour.
    private func removeColumns(where gone: (Column) -> Bool) -> [(column: Column, index: Int, left: Win?)] {
        let focusedWin = columns.indices.contains(focus) ? columns[focus].win : nil
        var kept: [Column] = [], removed: [(column: Column, index: Int, left: Win?)] = []
        var removedBeforeFocus = 0
        for (i, c) in columns.enumerated() {
            if gone(c) {
                removed.append((column: c, index: i, left: i > 0 ? columns[i - 1].win : nil))
                if i < focus { removedBeforeFocus += 1 }
            } else {
                kept.append(c)
            }
        }
        guard !removed.isEmpty else { return [] }
        columns = kept
        if let fw = focusedWin, let i = columns.firstIndex(where: { $0.win == fw }) { focus = i }
        else { focus -= removedBeforeFocus }
        focus = columns.isEmpty ? 0 : min(max(focus, 0), columns.count - 1)
        return removed
    }

    /// Syncs columns with live windows. Returns true if anything changed.
    @discardableResult
    func refresh() -> Bool {
        guard stripScreen != nil else { return false }
        let onScreen = AX.onScreenWindowIDs()
        var live: [Win] = [], floating = Set<Win>(), seen = Set<Win>()
        var running = Set<pid_t>(), stalledPIDs = Set<pid_t>()
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
                switch classify(w, excluded: excluded, onScreen: onScreen) {
                case .tile: live.append(w)
                case .float: floating.insert(w)
                case .away: break
                }
            }
        }
        standardWindows.formIntersection(seen)
        windowIDs = windowIDs.filter { seen.contains($0.key) }
        for (pid, w) in watchers where !running.contains(pid) { w.stop(); watchers[pid] = nil }
        suspended = suspended.filter { running.contains($0.key.pid) }
        if Date().timeIntervalSince(lastSweep) > 10 {
            // Windows closed while away (e.g. on another Space) are never reported; drop them.
            lastSweep = Date()
            suspended = suspended.filter { stalledPIDs.contains($0.key.pid) || seen.contains($0.key) || $0.key.isAlive }
        }

        let liveSet = Set(live)
        let known = Set(columns.map { $0.win })
        var newcomers = live.filter { !known.contains($0) }
        var frames: [Win: CGRect] = [:]
        for w in newcomers { frames[w] = w.frame }
        var changed = false

        // Switching native tabs swaps which window of the group is shown. The newly shown tab
        // (same app, same frame) takes over its sibling's column instead of getting its own.
        for c in columns where !liveSet.contains(c.win) && seen.contains(c.win) && !floating.contains(c.win) {
            guard let old = c.applied ?? c.win.frame,
                  let j = newcomers.firstIndex(where: { n in
                      n.pid == c.win.pid && frames[n].map { f in Self.approxEqual(f, old) } == true
                  }),
                  !c.win.isMinimized else { continue }
            c.win = newcomers.remove(at: j)
            c.applied = nil
            watchers[c.win.pid]?.watchWindow(c.win)
            changed = true
        }

        // Columns of an app that is not answering stay put until it recovers.
        let removed = removeColumns { !liveSet.contains($0.win) && !stalledPIDs.contains($0.win.pid) }
        for r in removed {
            changed = true
            let w = r.column.win
            if floating.contains(w) {
                // Left the strip for good (e.g. its app was added to the float list) and may
                // still be parked off-screen: bring it back.
                rescueIfOffScreen(w)
            } else if seen.contains(w) || w.isAlive {
                suspended[w] = Suspended(width: r.column.width, index: r.index, left: r.left)
            }
        }

        // Returning windows go back to their old slot, at their old width.
        let returning = newcomers.compactMap { w in suspended[w].map { (w, $0) } }
            .sorted { $0.1.index < $1.1.index }
        let focusedWin = columns.indices.contains(focus) ? columns[focus].win : nil
        for (w, s) in returning {
            suspended[w] = nil
            let afterLeft = s.left.flatMap { l in columns.firstIndex { $0.win == l } }.map { $0 + 1 }
            columns.insert(Column(win: w, width: s.width), at: afterLeft ?? min(s.index, columns.count))
            watchers[w.pid]?.watchWindow(w)
            changed = true
        }
        let back = Set(returning.map { $0.0 })

        // New windows open right beside the focused column, in the order they were found.
        var insertAt = focusedWin.flatMap { fw in columns.firstIndex { $0.win == fw } }.map { $0 + 1 } ?? columns.count
        for w in newcomers where !back.contains(w) && admits(frame: frames[w]) {
            columns.insert(Column(win: w, width: settings.defaultWidth), at: insertAt)
            insertAt += 1
            watchers[w.pid]?.watchWindow(w)
            changed = true
        }
        if let fw = focusedWin, let i = columns.firstIndex(where: { $0.win == fw }) { focus = i }
        focus = columns.isEmpty ? 0 : min(max(focus, 0), columns.count - 1)
        if changed { clampScroll() }
        if syncFocusFromSystem() { changed = true }
        return changed
    }

    /// Tracks the user's real focus (click / ⌘-Tab) without stealing it.
    private func syncFocusFromSystem() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, !isStalled(app.processIdentifier),
              let fw = AX.focusedWindow() else { return false }
        if let e = expectedFocus {
            // Wait for the window we focused to report focus before trusting the system again.
            if e.win != fw && Date() < e.until { return false }
            expectedFocus = nil
        }
        guard let i = columns.firstIndex(where: { $0.win == fw }), i != focus else { return false }
        focus = i
        scrollToFocus()
        return true
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
        // Away windows (other Space, minimised, …) may have been parked too.
        for w in suspended.keys where !isStalled(w.pid) { clampOnScreen(w) }
    }

    /// Clamps a window into the visible area of the strip's display.
    private func clampOnScreen(_ w: Win, frame: CGRect? = nil) {
        guard let scr = stripScreen, w.isAlive, !w.isFullscreen, var r = frame ?? w.frame else { return }
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

    func colWidth(_ c: Column) -> CGFloat { max(150, (usableWidth + gap) * CGFloat(c.width) - gap) }

    /// x of a column's left edge in strip space (0 = start of strip).
    func stripX(_ i: Int) -> CGFloat {
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

    /// How far the strip may scroll. In "always centre" mode the first and last columns may sit
    /// in the middle of the screen; otherwise the strip never scrolls past its ends.
    private var scrollRange: ClosedRange<CGFloat> {
        guard let last = columns.last else { return 0...0 }
        if settings.centerMode == .always {
            let lo = colWidth(columns[0]) / 2 - usableWidth / 2
            let hi = stripX(columns.count - 1) + colWidth(last) / 2 - usableWidth / 2
            return lo...max(lo, hi)
        }
        return 0...max(0, stripLength - usableWidth)
    }

    private func clamped(_ s: CGFloat) -> CGFloat {
        let r = scrollRange
        return min(max(s, r.lowerBound), r.upperBound)
    }

    private func clampScroll() { scroll = clamped(scroll) }

    /// Applies frames. Columns that don't reach the strip's display are parked beyond the
    /// outer edge of *all* displays, so they never show up on a neighbouring one.
    func layout() {
        guard enabled, !accessLost, let scr = stripScreen else { return }
        let a = scr.visibleFrame, disp = scr.frame
        // During display sleep or reconfiguration the frame can be empty: write nothing.
        guard a.width >= 300, a.height >= 200 else { return }
        let all = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        var x = a.minX + gap - scroll
        for c in columns {
            let w = colWidth(c)
            var r = CGRect(x: x, y: a.minY + gap, width: w, height: a.height - 2 * gap)
            x += w + gap
            if r.maxX <= disp.minX { r.origin.x = all.minX - w - 100 }
            else if r.minX >= disp.maxX { r.origin.x = all.maxX + 100 }
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
        let from = scroll, start = Date(), duration = 0.14
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let p = min(1, CGFloat(Date().timeIntervalSince(start) / duration))
                let e = 1 - pow(1 - p, 3)
                self.scroll = from + (target - from) * e
                self.layout()
                if p >= 1 { timer.invalidate() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        anim = t
    }

    private func scrollToFocus() {
        let old = scroll
        ensureVisible()
        let target = scroll
        scroll = old
        animate(to: target)
    }

    // MARK: Commands

    /// Focuses a column on our own initiative (keyboard, gesture).
    private func focusColumn(_ i: Int) {
        guard columns.indices.contains(i) else { return }
        focus = i
        let w = columns[i].win
        expectedFocus = (w, Date().addingTimeInterval(0.6))
        w.focus()
        scrollToFocus()
    }

    func focusLeft() { guard focus > 0 else { return }; focusColumn(focus - 1) }
    func focusRight() { guard focus + 1 < columns.count else { return }; focusColumn(focus + 1) }
    func focusFirst() { focusColumn(0) }
    func focusLast() { focusColumn(columns.count - 1) }

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
        columns[focus].widthBeforeFull = nil
        ensureVisible(); layout()
    }
    func nudgeWidth(_ delta: Double) {
        guard columns.indices.contains(focus) else { return }
        columns[focus].width = min(1.0, max(0.15, columns[focus].width + delta))
        columns[focus].widthBeforeFull = nil
        ensureVisible(); layout()
    }
    func fullWidth() {
        guard columns.indices.contains(focus) else { return }
        let c = columns[focus]
        if c.width >= 0.99 {
            c.width = c.widthBeforeFull ?? settings.defaultWidth
            c.widthBeforeFull = nil
        } else {
            c.widthBeforeFull = c.width
            c.width = 1.0
        }
        ensureVisible(); layout()
    }
    func center() {
        guard columns.indices.contains(focus) else { return }
        let x = stripX(focus), w = colWidth(columns[focus])
        animate(to: clamped(x + w / 2 - usableWidth / 2))
    }
    func equalize() {
        for c in columns { c.width = settings.defaultWidth }
        ensureVisible(); layout()
    }

    // MARK: Gesture scrolling (1:1 then snap)

    func scrollBy(_ dx: CGFloat) {
        anim?.invalidate()
        scroll = clamped(scroll + dx)
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
        focusColumn(best)
    }

    /// Re-applies every frame, e.g. after a manual re-tile.
    func retile() { invalidateFrames(); refresh(); ensureVisible(); layout() }
}
