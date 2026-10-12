import AppKit

final class Column {
    var win: Win
    var width: Double   // fraction of usable screen width
    init(win: Win, width: Double) { self.win = win; self.width = width }
}

/// One infinite horizontal strip of full-height columns on the main display.
final class StripEngine {
    private(set) var columns: [Column] = []
    private(set) var focus = 0
    private(set) var scroll: CGFloat = 0     // strip x-offset in points
    var enabled = true { didSet { if enabled { refresh(); layout() } } }
    var onLayout: (() -> Void)?

    private var timer: Timer?
    private var anim: Timer?
    private let settings = Settings.shared
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    var screenArea: CGRect { NSScreen.main?.visibleFrame ?? .zero }   // Cocoa coords, Dock-aware
    var gap: CGFloat { CGFloat(settings.gap) }
    var usableWidth: CGFloat { max(200, screenArea.width - 2 * gap) }

    func start() {
        refresh(); layout()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self, self.enabled else { return }
            if self.refresh() { self.layout() }
        }
        settings.onChange = { [weak self] in self?.layout() }
    }

    // MARK: Window discovery

    private func tileable(_ w: Win, bundle: String?) -> Bool {
        if let b = bundle, settings.excluded.contains(b) { return false }
        return w.subrole == (kAXStandardWindowSubrole as String) && !w.isMinimized && !w.isFullscreen && w.isResizable
    }

    /// Syncs columns with live windows. Returns true if anything changed.
    @discardableResult
    func refresh() -> Bool {
        var live: [Win] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != selfPID && !app.isHidden {
            for w in AX.windows(of: app) where tileable(w, bundle: app.bundleIdentifier) { live.append(w) }
        }
        let liveSet = Set(live)
        let before = columns.count
        columns.removeAll { !liveSet.contains($0.win) }
        var changed = columns.count != before
        let known = Set(columns.map { $0.win })
        for w in live where !known.contains(w) {
            // New windows open right beside the focused column.
            let idx = columns.isEmpty ? 0 : min(focus + 1, columns.count)
            columns.insert(Column(win: w, width: settings.defaultWidth), at: idx)
            changed = true
        }
        focus = columns.isEmpty ? 0 : min(max(focus, 0), columns.count - 1)
        // Track the user's real focus (click / Cmd-Tab) without stealing it.
        if let fw = AX.focusedWindow(), let i = columns.firstIndex(where: { $0.win == fw }), i != focus {
            focus = i; ensureVisible(); changed = true
        }
        return changed
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
        for (i, c) in columns.enumerated() {
            let w = colWidth(c)
            let x = a.minX + gap + stripX(i) - scroll
            let r = CGRect(x: x, y: a.minY + gap, width: w, height: a.height - 2 * gap)
            c.win.setFrame(AX.toAX(r))
        }
        onLayout?()
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
}
