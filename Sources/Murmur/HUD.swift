import AppKit

final class PillView: NSView {
    private var levels = [CGFloat](repeating: 0, count: 14)
    let spinner = NSProgressIndicator()
    var processing = false { didSet { spinner.isHidden = !processing; processing ? spinner.startAnimation(nil) : spinner.stopAnimation(nil); needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        layer?.cornerRadius = frame.height / 2
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        spinner.frame = NSRect(x: (frame.width - 16) / 2, y: (frame.height - 16) / 2, width: 16, height: 16)
        spinner.appearance = NSAppearance(named: .darkAqua)
        addSubview(spinner)
    }
    required init?(coder: NSCoder) { fatalError() }

    func push(_ rms: Float) {
        levels.removeFirst()
        levels.append(CGFloat(min(1, Float(pow(Double(rms), 0.5)) * 2.5)))
        needsDisplay = true
    }

    func clear() { levels = levels.map { _ in 0 }; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard !processing else { return }
        NSColor.white.setFill()
        let w: CGFloat = 4, gap: CGFloat = 4
        let total = CGFloat(levels.count) * (w + gap) - gap
        var x = (bounds.width - total) / 2
        for l in levels {
            let h = max(4, l * (bounds.height - 12))
            NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h), xRadius: 2, yRadius: 2).fill()
            x += w + gap
        }
    }
}

final class HUD {
    private let panel: NSPanel
    private let pill: PillView

    init() {
        let size = NSSize(width: 128, height: 36)
        pill = PillView(frame: NSRect(origin: .zero, size: size))
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = pill
    }

    private func place() {
        guard let s = NSScreen.main else { return }
        let f = s.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 48))
    }

    func showRecording() { pill.processing = false; pill.clear(); place(); panel.orderFrontRegardless() }
    func showProcessing() { pill.processing = true }
    func hide() { pill.processing = false; panel.orderOut(nil) }
    func level(_ v: Float) { pill.push(v) }
}
