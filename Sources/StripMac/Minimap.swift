import AppKit

/// A map of the whole strip: one card per column with its app icon, a live RAM gauge and a close
/// button, the focused column highlighted, and an outline for the visible area. Shown while
/// navigating, then fades out. Hover to keep it open; hover a card for 2 s for a window preview;
/// click a card to jump to it; press and hold for 3 s to make the cards wiggle and drag to reorder.
@MainActor
final class Minimap {
    private var panel: NSPanel?
    private let view = MinimapView(frame: NSRect(x: 0, y: 0, width: 460, height: MinimapView.height))
    private let preview = WindowPreview()
    private let ram = RAMMonitor()
    private var hide: DispatchWorkItem?
    private var generation = 0
    private weak var engine: StripEngine?

    func show(engine: StripEngine) {
        self.engine = engine
        if panel == nil { panel = makePanel() }
        guard let p = panel else { return }
        view.update(engine: engine, ram: ram.usage)
        let a = engine.screenArea
        let w = view.preferredWidth(maxWidth: a.width - 80)
        let frame = NSRect(x: a.midX - w / 2, y: a.minY + 24, width: w, height: MinimapView.height)
        if p.frame != frame { p.setFrame(frame, display: true) }
        generation += 1
        // Setting alphaValue directly can be overridden by an in-flight fade; animating to 1 with
        // zero duration replaces that animation.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            p.animator().alphaValue = 1
        }
        p.orderFrontRegardless()
        ram.start()
        if !view.isHeld { scheduleHide(after: 1.4) }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let blur = NSVisualEffectView(frame: view.frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        view.autoresizingMask = [.width, .height]
        blur.addSubview(view)
        p.contentView = blur

        view.onPick = { [weak self] i in self?.engine?.focus(column: i) }
        view.onMove = { [weak self] from, to in self?.engine?.moveColumn(from: from, to: to) }
        view.onClose = { pid in NSRunningApplication(processIdentifier: pid)?.terminate() }
        view.onCloseWindow = { [weak self] i, pid in
            // Only if the strip hasn't changed under the callout.
            guard let engine = self?.engine, engine.columns.indices.contains(i), engine.columns[i].win.pid == pid else { return }
            engine.columns[i].win.close()
        }
        view.windowCount = { pid in AX.standardWindowCount(pid: pid) }
        view.onHold = { [weak self] held in
            guard let self else { return }
            if held { self.hide?.cancel() } else { self.scheduleHide(after: 0.6) }
        }
        view.onPreview = { [weak self] i, cardRect in
            guard let self, let engine = self.engine, engine.columns.indices.contains(i), let p = self.panel else { return }
            let win = engine.columns[i].win
            let app = NSRunningApplication(processIdentifier: win.pid)
            let anchor = NSRect(x: p.frame.minX + cardRect.minX, y: p.frame.minY, width: cardRect.width, height: p.frame.height)
            self.preview.show(win: win, appName: app?.localizedName ?? "Window", icon: app?.icon, above: anchor)
        }
        view.onPreviewHide = { [weak self] in self?.preview.hide() }
        ram.onUpdate = { [weak self] in
            guard let self, let engine = self.engine else { return }
            self.view.update(engine: engine, ram: self.ram.usage)
        }
        return p
    }

    private func scheduleHide(after delay: TimeInterval) {
        hide?.cancel()
        let gen = generation
        hide = runOnMain(after: delay) { [weak self] in
            guard let self, let p = self.panel, !self.view.isHeld else { return }
            self.preview.hide()
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; p.animator().alphaValue = 0 }) {
                // The panel takes clicks, so take it off screen once faded unless it was shown again.
                MainActor.assumeIsolated {
                    if self.generation == gen, !self.view.isHeld {
                        p.orderOut(nil)
                        self.ram.stop()
                    }
                }
            }
        }
    }
}

final class MinimapView: NSView {
    static let height: CGFloat = 138
    private struct Card {
        var start: CGFloat; var length: CGFloat   // fractions of the track width
        var pid: pid_t; var icon: NSImage?; var name: String
        var ram: RAMMonitor.Usage?
    }
    private var cards: [Card] = []
    private var focus = 0
    private var viewport: (CGFloat, CGFloat) = (0, 1)
    private var appInfo: [pid_t: (NSImage?, String)] = [:]   // looked up once per app, not per frame

    var onPick: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onClose: ((pid_t) -> Void)?          // quit the app
    var onCloseWindow: ((Int, pid_t) -> Void)?   // close just this column's window
    var windowCount: ((pid_t) -> Int)?
    var onHold: ((Bool) -> Void)?             // true while the map must stay open
    var onPreview: ((Int, NSRect) -> Void)?
    var onPreviewHide: (() -> Void)?

    // Interaction state.
    private var hovering = false
    private var hoverIndex: Int?
    private var hoverClose: Int?
    private var previewTimer: DispatchWorkItem?
    private var pressIndex: Int?, pressStart: CFTimeInterval = 0, pressPoint = NSPoint.zero
    private var jiggling = false
    private var dragIndex: Int?, dragX: CGFloat = 0, dragOffset: CGFloat = 0
    private var frameTimer: Timer?

    var isHeld: Bool { hovering || jiggling || dragIndex != nil || closeChoice != nil }

    // "Close what?" callout from the × when the app has more than one window.
    private var closeChoice: NSPopover?
    private var outsideClickMonitors: [Any] = []
    private static let longPress: CFTimeInterval = 3
    private static let minCard: CGFloat = 64

    private var track: NSRect { NSRect(x: 16, y: 34, width: bounds.width - 32, height: bounds.height - 50) }

    /// Uses the engine's real geometry (gaps, minimum widths), and spans both the strip and the
    /// viewport, so the viewport stays inside the panel even when it extends past a strip end.
    @MainActor func update(engine: StripEngine, ram: [pid_t: RAMMonitor.Usage]) {
        let lo = min(0, engine.scroll)
        let hi = max(engine.stripLength, engine.scroll + engine.usableWidth)
        let span = max(hi - lo, 1)
        let newCards: [Card] = engine.columns.indices.map { i in
            let pid = engine.columns[i].win.pid
            if appInfo[pid] == nil {
                let app = NSRunningApplication(processIdentifier: pid)
                appInfo[pid] = (app?.icon, app?.localizedName ?? "Window")
            }
            let (icon, name) = appInfo[pid]!
            return Card(start: (engine.stripX(i) - lo) / span, length: engine.colWidth(engine.columns[i]) / span,
                        pid: pid, icon: icon, name: name, ram: ram[pid])
        }
        if newCards.count != cards.count { dragIndex = nil; pressIndex = nil; hoverIndex = nil }
        cards = newCards
        focus = engine.focus
        viewport = ((engine.scroll - lo) / span, engine.usableWidth / span)
        needsDisplay = true
    }

    /// Wide enough that the narrowest card fits its gauge, icon and close button.
    func preferredWidth(maxWidth: CGFloat) -> CGFloat {
        guard let narrowest = cards.map(\.length).min(), narrowest > 0 else { return 460 }
        return min(max(460, Self.minCard / narrowest + 32), max(460, maxWidth))
    }

    // MARK: Geometry

    private func rect(_ c: Card) -> NSRect {
        let t = track
        return NSRect(x: t.minX + c.start * t.width, y: t.minY, width: max(3, c.length * t.width), height: t.height)
    }

    private func closeRect(_ r: NSRect) -> NSRect { NSRect(x: r.maxX - 21, y: r.maxY - 21, width: 17, height: 17) }
    private func showsBadges(_ r: NSRect) -> Bool { r.width >= 50 }

    private func cardIndex(at p: NSPoint) -> Int? {
        cards.indices.first { rect(cards[$0]).insetBy(dx: -2, dy: -6).contains(p) }
    }

    /// Card rects in drag order: the dragged card removed and the rest packed in sequence,
    /// with a gap left at `slot` for it.
    private func packedRects(excluding drag: Int, slot: Int) -> [Int: NSRect] {
        let t = track
        let gapFrac = cards.count > 1 ? max(0, cards[1].start - cards[0].start - cards[0].length) : 0
        var order = Array(cards.indices); order.remove(at: drag)
        order.insert(drag, at: min(slot, order.count))
        var x = cards[0].start
        var out: [Int: NSRect] = [:]
        for i in order {
            out[i] = NSRect(x: t.minX + x * t.width, y: t.minY, width: max(3, cards[i].length * t.width), height: t.height)
            x += cards[i].length + gapFrac
        }
        return out
    }

    private func dropSlot(for drag: Int) -> Int {
        var others = Array(cards.indices); others.remove(at: drag)
        return others.filter { rect(cards[$0]).midX < dragX }.count
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { hovering = true; onHold?(true) }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        setHover(nil)
        if dragIndex == nil { stopJiggle() }
        onHold?(isHeld)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = cardIndex(at: p)
        let overClose = i.flatMap { showsBadges(rect(cards[$0])) && closeRect(rect(cards[$0])).insetBy(dx: -3, dy: -3).contains(p) ? $0 : nil }
        if overClose != hoverClose { hoverClose = overClose; needsDisplay = true }
        setHover(i)
    }

    private func setHover(_ i: Int?) {
        guard i != hoverIndex else { return }
        hoverIndex = i
        needsDisplay = true
        previewTimer?.cancel()
        onPreviewHide?()
        guard let i, !jiggling, dragIndex == nil else { return }
        // Preview only after a deliberate 2 s hover, so passing over the map shows nothing.
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.hoverIndex == i, self.pressIndex == nil, !self.jiggling,
                  self.cards.indices.contains(i) else { return }
            self.onPreview?(i, self.rect(self.cards[i]))
        }
        previewTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        previewTimer?.cancel(); onPreviewHide?()
        guard let i = cardIndex(at: p) else { stopJiggle(); return }   // background click ends wiggle mode
        let r = rect(cards[i])
        if showsBadges(r), closeRect(r).insetBy(dx: -3, dy: -3).contains(p) {
            if (windowCount?(cards[i].pid) ?? 1) > 1 { showCloseChoice(for: i, from: closeRect(r)) }
            else { onClose?(cards[i].pid) }
            return
        }
        if jiggling { beginDrag(i, at: p); return }
        pressIndex = i; pressStart = CACurrentMediaTime(); pressPoint = p
        startFrameTimer()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if dragIndex != nil { dragX = p.x - dragOffset; needsDisplay = true; return }
        // Moving before the long press completes cancels it (it was not a press-and-hold).
        if pressIndex != nil, hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 6 { pressIndex = nil; stopFrameTimerIfIdle(); needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        if let d = dragIndex {
            let slot = dropSlot(for: d)
            dragIndex = nil
            if slot != d { onMove?(d, slot) }
            needsDisplay = true
            return
        }
        if let i = pressIndex {
            pressIndex = nil
            stopFrameTimerIfIdle()
            needsDisplay = true
            onPick?(i)   // a short press is a click
        }
    }

    /// A callout from the × offering to quit the app or close only this window. Any click
    /// elsewhere, in StripMac or in another app, dismisses it.
    private func showCloseChoice(for i: Int, from anchor: NSRect) {
        dismissCloseChoice()
        let pid = cards[i].pid
        let pop = NSPopover()
        pop.behavior = .applicationDefined
        pop.animates = true
        let vc = CloseChoiceController(appName: cards[i].name) { [weak self] choice in
            guard let self else { return }
            self.dismissCloseChoice()
            switch choice {
            case .app: self.onClose?(pid)
            case .window: self.onCloseWindow?(i, pid)
            }
        }
        pop.contentViewController = vc
        closeChoice = pop
        onHold?(true)
        pop.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        let popWindow = vc.view.window
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if e.window !== popWindow { self?.dismissCloseChoice() }
            return e
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissCloseChoice() }
        }
        outsideClickMonitors = [local, global].compactMap { $0 }
    }

    private func dismissCloseChoice() {
        outsideClickMonitors.forEach(NSEvent.removeMonitor)
        outsideClickMonitors = []
        guard let pop = closeChoice else { return }
        closeChoice = nil
        pop.close()
        onHold?(isHeld)
    }

    private func beginDrag(_ i: Int, at p: NSPoint) {
        let r = rect(cards[i])
        dragIndex = i
        dragOffset = p.x - r.midX
        dragX = r.midX
        onHold?(true)
        needsDisplay = true
    }

    private func startJiggle() {
        jiggling = true
        previewTimer?.cancel(); onPreviewHide?()
        startFrameTimer()
        onHold?(true)
    }

    private func stopJiggle() {
        guard jiggling else { return }
        jiggling = false
        dragIndex = nil
        stopFrameTimerIfIdle()
        needsDisplay = true
        onHold?(isHeld)
    }

    private func startFrameTimer() {
        guard frameTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        frameTimer = t
    }

    private func stopFrameTimerIfIdle() {
        if !jiggling && pressIndex == nil { frameTimer?.invalidate(); frameTimer = nil }
    }

    private func tick() {
        if let i = pressIndex, CACurrentMediaTime() - pressStart >= Self.longPress {
            pressIndex = nil
            startJiggle()
            if let w = window, cards.indices.contains(i) {
                beginDrag(i, at: convert(w.mouseLocationOutsideOfEventStream, from: nil))
            }
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !cards.isEmpty else { return }
        let now = CACurrentMediaTime()
        let packed = dragIndex.map { packedRects(excluding: $0, slot: dropSlot(for: $0)) }

        for (i, c) in cards.enumerated() where i != dragIndex {
            drawCard(i, c, in: packed?[i] ?? rect(c), now: now, lifted: false)
        }

        // Visible area of the screen.
        if dragIndex == nil {
            let t = track
            let vp = NSRect(x: t.minX + viewport.0 * t.width - 3, y: t.minY - 4,
                            width: viewport.1 * t.width + 6, height: t.height + 8)
            let p = NSBezierPath(roundedRect: vp, xRadius: 10, yRadius: 10)
            NSColor.white.withAlphaComponent(0.85).setStroke(); p.lineWidth = 1.5; p.stroke()
        }

        if let d = dragIndex {
            let base = rect(cards[d])
            let r = NSRect(x: dragX - base.width / 2, y: base.minY, width: base.width, height: base.height)
            drawCard(d, cards[d], in: r.insetBy(dx: -4, dy: -4), now: now, lifted: true)
        }

        drawCaption()
    }

    private func drawCard(_ i: Int, _ c: Card, in r: NSRect, now: CFTimeInterval, lifted: Bool) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if jiggling && !lifted {
            // iPhone-style wiggle: small alternating rotation, out of phase between cards.
            let angle = sin(now * 2 * .pi * 3.2 + Double(i) * 1.7) * 1.8
            let xf = NSAffineTransform()
            xf.translateX(by: r.midX, yBy: r.midY); xf.rotate(byDegrees: angle); xf.translateX(by: -r.midX, yBy: -r.midY)
            xf.concat()
        }
        if lifted {
            let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.5); s.shadowBlurRadius = 14
            s.shadowOffset = NSSize(width: 0, height: -4); s.set()
        }
        let path = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        if i == focus {
            NSGradient(colors: [NSColor.controlAccentColor.withAlphaComponent(0.95),
                                NSColor.controlAccentColor.blended(withFraction: 0.35, of: .white)!])!.draw(in: path, angle: 90)
        } else {
            NSColor.white.withAlphaComponent(lifted ? 0.4 : (i == hoverIndex ? 0.3 : 0.16)).setFill(); path.fill()
        }
        NSShadow().set()

        // Long-press progress: a ring that fills over the 3 s hold.
        if pressIndex == i {
            let p = min(1, (now - pressStart) / Self.longPress)
            if p > 0.08 {
                let ring = NSBezierPath()
                ring.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: min(r.width, r.height) / 2 - 6,
                               startAngle: 90, endAngle: 90 - 360 * p, clockwise: true)
                NSColor.white.withAlphaComponent(0.85).setStroke(); ring.lineWidth = 2.5; ring.lineCapStyle = .round; ring.stroke()
            }
        }

        if let icon = c.icon {
            let side = min(r.width - 10, r.height - 22, 40)
            if side >= 12 {
                icon.draw(in: NSRect(x: r.midX - side / 2, y: r.midY - side / 2 - 4, width: side, height: side),
                          from: .zero, operation: .sourceOver, fraction: i == focus || lifted ? 1 : 0.8)
            }
        }
        guard showsBadges(r) else { return }
        if let u = c.ram { drawRAMGauge(u, at: NSPoint(x: r.minX + 5, y: r.maxY - 29)) }
        if hoverIndex == i || jiggling || lifted { drawClose(closeRect(r), hot: hoverClose == i) }
    }

    /// Donut gauge: the arc is the app's share of physical RAM, coloured by how heavy it is.
    private func drawRAMGauge(_ u: RAMMonitor.Usage, at origin: NSPoint) {
        let d: CGFloat = 24
        let box = NSRect(x: origin.x, y: origin.y, width: d, height: d)
        let center = NSPoint(x: box.midX, y: box.midY)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(ovalIn: box).fill()
        let track = NSBezierPath(); track.appendArc(withCenter: center, radius: d / 2 - 3, startAngle: 0, endAngle: 360)
        NSColor.white.withAlphaComponent(0.2).setStroke(); track.lineWidth = 3; track.stroke()
        let color: NSColor = u.percent >= 20 ? .systemRed : u.percent >= 8 ? .systemOrange : .systemGreen
        let frac = max(0.04, min(1, u.percent / 100))
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: d / 2 - 3, startAngle: 90, endAngle: 90 - 360 * frac, clockwise: true)
        color.setStroke(); arc.lineWidth = 3; arc.lineCapStyle = .round; arc.stroke()
        let text = (u.percent < 10 ? String(format: "%.1f", u.percent) : String(format: "%.0f", u.percent)) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .bold),
                                                     .foregroundColor: NSColor.white]
        let sz = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2), withAttributes: attrs)
    }

    private func drawClose(_ r: NSRect, hot: Bool) {
        (hot ? NSColor.systemRed : NSColor(white: 0.15, alpha: 0.85)).setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let x = NSBezierPath(), k: CGFloat = 4.5
        x.move(to: NSPoint(x: r.midX - k, y: r.midY - k)); x.line(to: NSPoint(x: r.midX + k, y: r.midY + k))
        x.move(to: NSPoint(x: r.midX - k, y: r.midY + k)); x.line(to: NSPoint(x: r.midX + k, y: r.midY - k))
        x.lineWidth = 1.6; x.lineCapStyle = .round; x.stroke()
    }

    /// Caption: the hovered or focused app, its RAM, and its position on the strip.
    private func drawCaption() {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                                                     .foregroundColor: NSColor.white.withAlphaComponent(0.92),
                                                     .paragraphStyle: style]
        var dim = attrs; dim[.foregroundColor] = NSColor.white.withAlphaComponent(0.55)
        dim[.font] = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let i = dragIndex ?? hoverIndex ?? min(focus, cards.count - 1)
        let c = cards[i]
        var text = c.name
        if jiggling { text = dragIndex != nil ? "Drop to reorder" : "Drag to reorder · click outside to finish" }
        else if hoverClose == i { text = "Quit \(c.name)" }
        else if let u = c.ram { text += String(format: "  ·  %.1f%% RAM (%@)", u.percent, ByteCountFormatter.string(fromByteCount: Int64(u.bytes), countStyle: .memory)) }
        (text as NSString).draw(in: NSRect(x: 18, y: 10, width: bounds.width - 110, height: 16), withAttributes: attrs)
        let count = "\(i + 1) / \(cards.count)" as NSString
        let w = count.size(withAttributes: dim).width
        count.draw(at: NSPoint(x: bounds.width - 18 - w, y: 10), withAttributes: dim)
    }
}

/// Content of the × callout: "App" quits the whole app, "This Window" closes only the window.
final class CloseChoiceController: NSViewController {
    enum Choice { case app, window }
    private let appName: String
    private let pick: (Choice) -> Void

    init(appName: String, pick: @escaping (Choice) -> Void) {
        self.appName = appName
        self.pick = pick
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: "Close")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let window = NSButton(title: "This Window", target: self, action: #selector(closeWindow))
        window.bezelStyle = .rounded
        window.keyEquivalent = "\r"
        let app = NSButton(title: "App", target: self, action: #selector(quitApp))
        app.bezelStyle = .rounded
        app.hasDestructiveAction = true
        app.contentTintColor = .systemRed
        app.toolTip = "Quit \(appName) and close all its windows"
        let buttons = NSStackView(views: [window, app])
        buttons.spacing = 8
        let stack = NSStackView(views: [title, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        view = stack
    }

    @objc private func closeWindow() { pick(.window) }
    @objc private func quitApp() { pick(.app) }
}
