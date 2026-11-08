import AppKit

/// Small transient message near the top of the screen (launch/permission status).
enum Toast {
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?

    static func show(_ text: String, seconds: Double = 3) {
        DispatchQueue.main.async {
            hide?.cancel()
            panel?.orderOut(nil)
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.textColor = .white
            label.sizeToFit()
            let size = NSSize(width: label.frame.width + 40, height: 40)
            guard let screen = NSScreen.main else { return }
            let vf = screen.visibleFrame
            let p = NSPanel(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 16,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let bg = NSView(frame: NSRect(origin: .zero, size: size))
            bg.wantsLayer = true
            bg.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
            bg.layer?.cornerRadius = 20
            label.frame.origin = NSPoint(x: 20, y: (size.height - label.frame.height) / 2)
            bg.addSubview(label)
            p.contentView = bg
            p.orderFrontRegardless()
            panel = p
            let w = DispatchWorkItem { panel?.orderOut(nil); panel = nil }
            hide = w
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        }
    }
}
