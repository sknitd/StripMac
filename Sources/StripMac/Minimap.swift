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
        p.alphaValue = 1
        p.orderFrontRegardless()
        hide?.cancel()
        let w = DispatchWorkItem { [weak p] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; p?.animator().alphaValue = 0 })
        }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }
}

final class MinimapView: NSView {
    private var widths: [CGFloat] = []
    private var focus = 0
    private var viewport: (CGFloat, CGFloat) = (0, 1)

    func update(engine: StripEngine) {
        let total = max(engine.stripLength, engine.usableWidth, 1)
        widths = engine.columns.map { CGFloat($0.width) * engine.usableWidth / total }
        focus = engine.focus
        viewport = (engine.scroll / total, engine.usableWidth / total)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.6).setFill(); bg.fill()
        let inner = bounds.insetBy(dx: 10, dy: 10)
        var x = inner.minX
        for (i, w) in widths.enumerated() {
            let r = NSRect(x: x, y: inner.minY, width: max(2, w * inner.width - 2), height: inner.height)
            (i == focus ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.35)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            x += w * inner.width
        }
        let vp = NSRect(x: inner.minX + viewport.0 * inner.width, y: inner.minY - 3,
                        width: viewport.1 * inner.width, height: inner.height + 6)
        NSColor.white.setStroke()
        let p = NSBezierPath(roundedRect: vp, xRadius: 4, yRadius: 4); p.lineWidth = 1.5; p.stroke()
    }
}
