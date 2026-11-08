import AppKit

enum Inserter {
    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "dev.warp.Warp", "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper"]

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// HTML with <ul>/<ol> when the text contains list lines; nil otherwise.
    static func html(for text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        func kind(_ l: String) -> (String, String)? {
            if l.hasPrefix("- ") { return ("ul", String(l.dropFirst(2))) }
            if let r = l.range(of: #"^\d+\. "#, options: .regularExpression) { return ("ol", String(l[r.upperBound...])) }
            return nil
        }
        guard lines.contains(where: { kind($0) != nil }) else { return nil }
        var out = ""
        var open: String?
        for l in lines {
            if let (k, item) = kind(l) {
                if open != k { if let o = open { out += "</\(o)>" }; out += "<\(k)>"; open = k }
                out += "<li>\(esc(item))</li>"
            } else {
                if let o = open { out += "</\(o)>"; open = nil }
                if !l.trimmingCharacters(in: .whitespaces).isEmpty { out += "<p>\(esc(l))</p>" }
            }
        }
        if let o = open { out += "</\(o)>" }
        return out
    }

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]
    // Main-thread only: original clipboard held while a restore is pending.
    private static var pendingSnapshot: Snapshot?
    private static var pendingMine = -1
    private static var pendingRestore: DispatchWorkItem?

    static func insert(_ text: String, bundleId: String) {
        let pb = NSPasteboard.general
        let snapshot: Snapshot
        if let pending = pendingSnapshot, pb.changeCount == pendingMine {
            snapshot = pending  // pasteboard still holds our last transcript: keep the original
        } else {
            snapshot = (pb.pasteboardItems ?? []).map { item in
                item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
            }
        }
        pendingRestore?.cancel()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if !terminals.contains(bundleId), let h = html(for: text) { item.setString(h, forType: .html) }
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.clearContents()
        pb.writeObjects([item])
        let mine = pb.changeCount
        pendingSnapshot = snapshot
        pendingMine = mine

        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }

        let work = DispatchWorkItem {
            pendingSnapshot = nil; pendingRestore = nil
            guard pb.changeCount == mine else { return }  // user copied something meanwhile
            pb.clearContents()
            let items: [NSPasteboardItem] = snapshot.map { entries in
                let it = NSPasteboardItem()
                for (t, d) in entries { it.setData(d, forType: t) }
                return it
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
