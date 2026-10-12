import AppKit

/// A small overlay showing the whole strip and the visible viewport; fades out after navigating.
final class Minimap {
    private var panel: NSPanel?
    private let view = MinimapView()
    private var hide: DispatchWorkItem?

    func show(engine: StripEngine) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 46),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary]
            p.contentView = view
            panel = p
        }
        guard let p = panel else { return }
        let a = engine.screenArea
        p.setFrameOrigin(NSPoint(x: a.midX - 160, y: a.minY + 24))
        view.update(engine: engine)
        hide?.cancel()
        // Setting alphaValue directly can be overridden by an in-flight fade; animating to 1 with
        // zero duration replaces that animation.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            p.animator().alphaValue = 1
        }
        p.orderFrontRegardless()
        let w = DispatchWorkItem { [weak p] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; p?.animator().alphaValue = 0 })
        }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }
}

final class MinimapView: NSView {
    // Fractions of the panel width: (start, length).
    private var bars: [(CGFloat, CGFloat)] = []
    private var focus = 0
    private var viewport: (CGFloat, CGFloat) = (0, 1)

    /// Uses the engine's real geometry (gaps, minimum widths), and spans both the strip and the
    /// viewport, so the viewport stays inside the panel even when it extends past a strip end.
    func update(engine: StripEngine) {
        let lo = min(0, engine.scroll)
        let hi = max(engine.stripLength, engine.scroll + engine.usableWidth)
        let span = max(hi - lo, 1)
        bars = engine.columns.indices.map { i in
            ((engine.stripX(i) - lo) / span, engine.colWidth(engine.columns[i]) / span)
        }
        focus = engine.focus
        viewport = ((engine.scroll - lo) / span, engine.usableWidth / span)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.6).setFill(); bg.fill()
        let inner = bounds.insetBy(dx: 10, dy: 10)
        for (i, b) in bars.enumerated() {
            let r = NSRect(x: inner.minX + b.0 * inner.width, y: inner.minY,
                           width: max(2, b.1 * inner.width), height: inner.height)
            (i == focus ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.35)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        }
        let vp = NSRect(x: inner.minX + viewport.0 * inner.width, y: inner.minY - 3,
                        width: viewport.1 * inner.width, height: inner.height + 6)
        NSColor.white.setStroke()
        let p = NSBezierPath(roundedRect: vp, xRadius: 4, yRadius: 4); p.lineWidth = 1.5; p.stroke()
    }
}
