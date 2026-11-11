import AppKit

enum SuggestionAction { case add, dismiss, never, timeout }

/// Small non-activating pop-up near the top of the screen: "Add “X” to vocabulary?"
enum SuggestionPanel {
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?
    private static var handler: ((SuggestionAction) -> Void)?

    private final class Target: NSObject {
        @objc func add() { SuggestionPanel.perform(.add) }
        @objc func dismiss() { SuggestionPanel.perform(.dismiss) }
        @objc func never() { SuggestionPanel.perform(.never) }
    }
    private static let target = Target()

    static func perform(_ a: SuggestionAction) {
        guard panel != nil else { return }
        hide?.cancel(); hide = nil
        panel?.orderOut(nil); panel = nil
        let h = handler; handler = nil
        h?(a)
    }

    static func show(heard: String, wanted: String, seconds: Double = 12, onAction: @escaping (SuggestionAction) -> Void) {
        DispatchQueue.main.async {
            if panel != nil { perform(.timeout) }
            guard let screen = NSScreen.main else { return }
            handler = onAction

            let label = NSTextField(labelWithString: "Add “\(wanted)” to vocabulary?  (heard “\(heard)”)")
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .white
            label.lineBreakMode = .byTruncatingMiddle
            label.sizeToFit()

            func button(_ title: String, _ sel: Selector, prominent: Bool) -> NSButton {
                let b = NSButton(title: title, target: target, action: sel)
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.setAccessibilityLabel(title)
                if prominent { b.keyEquivalent = "" }
                b.sizeToFit()
                return b
            }
            let addB = button("Add", #selector(Target.add), prominent: true)
            let disB = button("Dismiss", #selector(Target.dismiss), prominent: false)
            let never = NSButton(title: "Don't suggest this", target: target, action: #selector(Target.never))
            never.isBordered = false
            never.controlSize = .small
            never.attributedTitle = NSAttributedString(string: "Don't suggest this", attributes: [
                .foregroundColor: NSColor(white: 0.7, alpha: 1), .font: NSFont.systemFont(ofSize: 11)])
            never.setAccessibilityLabel("Don't suggest this")
            never.sizeToFit()

            let rowW = addB.frame.width + disB.frame.width + never.frame.width + 24
            let width = min(640, max(label.frame.width, rowW) + 40)
            let size = NSSize(width: width, height: 84)
            let vf = screen.visibleFrame
            let p = NSPanel(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 16,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let bg = NSView(frame: NSRect(origin: .zero, size: size))
            bg.wantsLayer = true
            bg.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.94).cgColor
            bg.layer?.cornerRadius = 16
            label.frame = NSRect(x: 20, y: size.height - 16 - label.frame.height,
                                 width: min(label.frame.width, size.width - 40), height: label.frame.height)
            addB.frame.origin = NSPoint(x: 20, y: 12)
            disB.frame.origin = NSPoint(x: addB.frame.maxX + 8, y: 12)
            never.frame.origin = NSPoint(x: size.width - 20 - never.frame.width, y: 14)
            for v in [label, addB, disB, never] { bg.addSubview(v) }
            p.contentView = bg
            p.orderFrontRegardless()
            panel = p
            let w = DispatchWorkItem { perform(.timeout) }
            hide = w
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        }
    }
}
