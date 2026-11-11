import AppKit
import ScreenCaptureKit
import Vision

/// On-device screen-text fallback for fields that expose no text through Accessibility.
enum ScreenOCR {
    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks for Screen Recording once, from an explicit menu action; opens Settings if still denied.
    static func requestFromMenu() {
        if granted { return }
        if CGRequestScreenCaptureAccess() { return }
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Vision text recognition, lines in reading order.
    static func recognize(_ image: CGImage) -> String? {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["en-US"]
        req.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([req])) != nil, let obs = req.results else { return nil }
        let rows = obs.compactMap { o -> (CGRect, String)? in
            guard let s = o.topCandidates(1).first?.string else { return nil }
            return (o.boundingBox, s)
        }
        // Vision's origin is bottom-left: higher midY is higher on screen.
        return rows.sorted { abs($0.0.midY - $1.0.midY) > 0.01 ? $0.0.midY > $1.0.midY : $0.0.minX < $1.0.minX }
            .map { $0.1 }.joined(separator: "\n")
    }

    /// Captures a region (global top-left point coordinates) of the display with ScreenCaptureKit, excluding Murmur's windows.
    static func capture(_ rect: CGRect) async -> CGImage? {
        guard granted, rect.width >= 8, rect.height >= 8 else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.frame.intersects(rect) }) ?? content.displays.first else { return nil }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let local = rect.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        guard !local.isNull, local.width >= 8, local.height >= 8 else { return nil }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = local
        let scale = CGFloat(filter.pointPixelScale)
        cfg.width = Int(local.width * scale)
        cfg.height = Int(local.height * scale)
        cfg.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// Test helper: renders black-on-white text to an image.
    static func render(_ text: String) -> CGImage? {
        let font = NSFont.systemFont(ofSize: 28)
        let lines = text.components(separatedBy: "\n")
        let strs = lines.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: NSColor.black]) }
        let size = NSSize(width: ceil(strs.map { $0.size().width }.max() ?? 100) + 40, height: CGFloat(lines.count) * 50 + 30)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (i, str) in strs.enumerated() { str.draw(at: NSPoint(x: 20, y: size.height - CGFloat(i + 1) * 50)) }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Headless: offscreen images stand in for screen captures ("canvas editor" before/after an edit).
    static func selfTest() -> Int {
        var fails = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { fails += 1 }
            print("\(ok ? "PASS" : "FAIL") ocr-\(name)\(ok ? "" : " \(detail)")")
        }
        func ocr(_ t: String) -> String { render(t).flatMap { recognize($0) } ?? "" }
        let pasted = "take control of my collab tree tab"
        let before = ocr("File  Edit  View\nNotes canvas\n\(pasted)")
        let after = ocr("File  Edit  View\nNotes canvas\ntake control of my Kolabtree tab")
        check("baseline-contains-paste", VocabDiff.fuzzyContains(pasted: pasted, buffer: before), before)
        check("canvas-edit-detected", VocabDiff.describe(VocabDiff.fuzzyCandidate(pasted: pasted, buffer: after)) == "collab tree -> Kolabtree", after)
        check("canvas-unchanged-none", VocabDiff.describe(VocabDiff.fuzzyCandidate(pasted: pasted, buffer: before)) == "none", before)
        let wrapped = ocr("File  Edit  View\ntake control of my\nKolabtree tab and then list")
        let longPaste = "take control of my collab tree tab and then list"
        check("canvas-wrapped-edit", VocabDiff.describe(VocabDiff.fuzzyCandidate(pasted: longPaste, buffer: wrapped)) == "collab tree -> Kolabtree", wrapped)
        return fails
    }
}
