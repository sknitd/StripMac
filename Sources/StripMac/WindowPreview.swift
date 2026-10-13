import AppKit
import ScreenCaptureKit

/// A small, click-through thumbnail of a window, shown above the strip map after hovering a
/// card. Captured with ScreenCaptureKit, which needs Screen Recording permission; without it the
/// preview shows the app icon and window title instead, and never prompts on its own.
@MainActor
final class WindowPreview {
    private var panel: NSPanel?
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "")
    private var token = 0

    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    func show(win: Win, appName: String, icon: NSImage?, above anchor: NSRect) {
        token += 1
        let mine = token
        let title = win.title
        titleField.stringValue = title.isEmpty ? appName : "\(appName) — \(title)"
        let p = makePanel()
        if Self.canCapture, let id = win.windowID {
            hintField.isHidden = true
            Task { @MainActor in
                guard let img = await Self.capture(windowID: id), mine == self.token else { return }
                self.present(p, image: img, anchor: anchor)
            }
        } else {
            hintField.isHidden = false
            hintField.stringValue = "Allow Screen Recording in Settings → General for live previews"
            present(p, image: icon ?? NSImage(), anchor: anchor, iconOnly: true)
        }
    }

    func hide() {
        token += 1
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { if p.alphaValue == 0 { p.orderOut(nil) } }
        }
    }

    private func present(_ p: NSPanel, image: NSImage, anchor: NSRect, iconOnly: Bool = false) {
        imageView.image = image
        let maxW: CGFloat = 340, maxH: CGFloat = 210
        var size = iconOnly ? NSSize(width: 96, height: 96) : image.size
        let k = min(maxW / max(size.width, 1), maxH / max(size.height, 1), 1)
        size = NSSize(width: max(140, size.width * k), height: max(60, size.height * k))
        let w = max(size.width + 16, 220), h = size.height + 16 + 22 + (hintField.isHidden ? 0 : 16)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? anchor
        var x = anchor.midX - w / 2
        x = min(max(x, screen.minX + 8), screen.maxX - w - 8)
        p.setFrame(NSRect(x: x, y: anchor.maxY + 10, width: w, height: h), display: false)
        let content = p.contentView!
        imageView.frame = NSRect(x: (w - size.width) / 2, y: h - 8 - size.height, width: size.width, height: size.height)
        titleField.frame = NSRect(x: 10, y: hintField.isHidden ? 8 : 24, width: w - 20, height: 16)
        hintField.frame = NSRect(x: 10, y: 6, width: w - 20, height: 14)
        if imageView.superview == nil { [imageView, titleField, hintField].forEach(content.addSubview) }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
    }

    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true   // never gets in the way
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        p.contentView = blur
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        titleField.font = .systemFont(ofSize: 11, weight: .semibold)
        titleField.textColor = .white
        titleField.lineBreakMode = .byTruncatingTail
        titleField.alignment = .center
        hintField.font = .systemFont(ofSize: 9.5)
        hintField.textColor = NSColor.white.withAlphaComponent(0.6)
        hintField.alignment = .center
        panel = p
        return p
    }

    private static func capture(windowID: CGWindowID) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scw = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let cfg = SCStreamConfiguration()
            let scale: CGFloat = 2, maxSide: CGFloat = 420
            let k = min(maxSide / max(scw.frame.width, 1), maxSide / max(scw.frame.height, 1), 1)
            cfg.width = Int(scw.frame.width * k * scale)
            cfg.height = Int(scw.frame.height * k * scale)
            cfg.showsCursor = false
            let cg = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scw),
                                                                configuration: cfg)
            return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
        } catch {
            return nil
        }
    }
}
