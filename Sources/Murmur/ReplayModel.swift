import CoreGraphics
import Foundation

/// Simulates the user's edits to the pasted text from key events alone (works where AX can't read the field).
/// Frozen ("uncertain") models keep the last known-good text, except after undo which discards it.
struct ReplayModel {
    enum Move: Equatable { case left, right, wordLeft, wordRight, lineStart, lineEnd }
    enum Event: Equatable {
        case text(String), backspace, forwardDelete, deleteWord, deleteLine
        case move(Move, select: Bool)
        case selectAll, undo, unsupported
    }

    private let original: String
    private(set) var chars: [Character]
    private(set) var cursor: Int
    private(set) var anchor: Int
    /// Kind of the event that made the model uncertain (never the characters themselves).
    private(set) var frozen: String?
    private(set) var discarded = false
    private var awaitingCaret = false
    private var queue: [Event] = []
    /// Counts per kind, for the debug log only.
    private(set) var counts = (text: 0, delete: 0, nav: 0, mouse: 0, other: 0)

    init(_ pasted: String) {
        original = pasted
        chars = Array(pasted)
        cursor = chars.count
        anchor = cursor
    }

    /// The edited pasted text, or nil when unchanged / discarded.
    var result: String? {
        if discarded { return nil }
        let s = String(chars)
        return s == original ? nil : s
    }

    private var sel: Range<Int> { min(anchor, cursor)..<max(anchor, cursor) }

    private mutating func freeze(_ kind: String, discard: Bool = false) {
        if frozen == nil { frozen = kind }
        if discard { discarded = true }
        awaitingCaret = false
        queue = []
    }

    private func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "'" || c == "’" }

    private func wordLeft(_ i: Int) -> Int {
        var j = i
        while j > 0, !isWord(chars[j - 1]) { j -= 1 }
        while j > 0, isWord(chars[j - 1]) { j -= 1 }
        return j
    }

    private func wordRight(_ i: Int) -> Int {
        var j = i
        while j < chars.count, !isWord(chars[j]) { j += 1 }
        while j < chars.count, isWord(chars[j]) { j += 1 }
        return j
    }

    private func lineStart(_ i: Int) -> Int? {
        var j = i - 1
        while j >= 0 { if chars[j].isNewline { return j + 1 }; j -= 1 }
        return nil
    }

    private func lineEnd(_ i: Int) -> Int? {
        var j = i
        while j < chars.count { if chars[j].isNewline { return j }; j += 1 }
        return nil
    }

    private mutating func replaceSelection(_ new: [Character]) {
        let r = sel
        chars.replaceSubrange(r, with: new)
        cursor = r.lowerBound + new.count
        anchor = cursor
    }

    private mutating func deleteRange(_ r: Range<Int>) {
        chars.removeSubrange(r)
        cursor = r.lowerBound
        anchor = cursor
    }

    mutating func apply(_ e: Event) {
        if frozen != nil { return }
        if awaitingCaret { queue.append(e); return }
        switch e {
        case .text(let s):
            counts.text += 1
            replaceSelection(Array(s))
        case .backspace:
            counts.delete += 1
            if !sel.isEmpty { replaceSelection([]) }
            else if cursor == 0 { freeze("boundary") }
            else { deleteRange((cursor - 1)..<cursor) }
        case .forwardDelete:
            counts.delete += 1
            if !sel.isEmpty { replaceSelection([]) }
            else if cursor >= chars.count { freeze("boundary") }
            else { deleteRange(cursor..<(cursor + 1)) }
        case .deleteWord:
            counts.delete += 1
            if !sel.isEmpty { replaceSelection([]) }
            else if cursor == 0 { freeze("boundary") }
            else { deleteRange(wordLeft(cursor)..<cursor) }
        case .deleteLine:
            counts.delete += 1
            if !sel.isEmpty { replaceSelection([]) }
            else if let s = lineStart(cursor), s < cursor { deleteRange(s..<cursor) }
            else { freeze("line-boundary") }
        case .move(let m, let select):
            counts.nav += 1
            let hasSel = !sel.isEmpty
            var target: Int?
            switch m {
            case .left: target = (!select && hasSel) ? sel.lowerBound : (cursor > 0 ? cursor - 1 : nil)
            case .right: target = (!select && hasSel) ? sel.upperBound : (cursor < chars.count ? cursor + 1 : nil)
            case .wordLeft: target = (!select && hasSel) || cursor == 0 ? nil : wordLeft(cursor)
            case .wordRight: target = (!select && hasSel) || cursor >= chars.count ? nil : wordRight(cursor)
            case .lineStart: target = lineStart(cursor)
            case .lineEnd: target = lineEnd(cursor)
            }
            guard let t = target else { freeze("boundary"); return }
            cursor = t
            if !select { anchor = t }
        case .selectAll: counts.other += 1; freeze("select-all")
        case .undo: counts.other += 1; freeze("undo", discard: true)
        case .unsupported: counts.other += 1; freeze("unsupported")
        }
    }

    /// A click moves the caret somewhere unknown. With `lookup`, events queue until `resolveCaret`.
    mutating func mouseDown(lookup: Bool) {
        if frozen != nil { return }
        counts.mouse += 1
        if lookup { awaitingCaret = true } else { freeze("mouse") }
    }

    /// Caret/selection read from AX relative to the pasted text; nil or out of range freezes the model.
    mutating func resolveCaret(location: Int?, length: Int) {
        guard awaitingCaret else { return }
        awaitingCaret = false
        let q = queue
        queue = []
        guard let l = location, l >= 0, length >= 0, l + length <= chars.count else { freeze("mouse"); return }
        anchor = l
        cursor = l + length
        for e in q { apply(e) }
    }

    /// Maps a key press to a model event; nil means "ignore" (harmless).
    static func event(code: Int, flags: CGEventFlags, chars: String) -> Event? {
        let cmd = flags.contains(.maskCommand), opt = flags.contains(.maskAlternate)
        let ctl = flags.contains(.maskControl), shift = flags.contains(.maskShift)
        switch code {
        case 51: return cmd ? .deleteLine : opt ? .deleteWord : ctl ? .unsupported : .backspace
        case 117: return (cmd || opt || ctl) ? .unsupported : .forwardDelete
        case 123, 124:
            if ctl { return .unsupported }
            let left = code == 123
            let m: Move = cmd ? (left ? .lineStart : .lineEnd) : opt ? (left ? .wordLeft : .wordRight) : (left ? .left : .right)
            return .move(m, select: shift)
        case 125, 126, 115, 119, 116, 121, 48, 53: return .unsupported
        case 36, 76: return shift && !cmd && !opt && !ctl ? .text("\n") : .unsupported
        case 0 where cmd && !opt && !ctl && !shift: return .selectAll
        case 6 where cmd: return .undo
        case 8 where cmd && !opt && !ctl: return nil  // copy
        default: break
        }
        if cmd || ctl || chars.isEmpty { return .unsupported }
        if chars.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) || (0xF700...0xF8FF).contains($0.value) }) {
            return .unsupported
        }
        return .text(chars)
    }

    var summary: String {
        "text=\(counts.text) delete=\(counts.delete) nav=\(counts.nav) mouse=\(counts.mouse) other=\(counts.other) frozen=\(frozen ?? "no")"
    }

    // MARK: Self test

    static func selfTest() -> Int {
        var fails = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { fails += 1 }
            print("\(ok ? "PASS" : "FAIL") replay-\(name)\(ok ? "" : " \(detail)")")
        }
        let p = "take control of my collab tree tab"
        func run(_ start: String, _ evs: [Event]) -> ReplayModel {
            var m = ReplayModel(start)
            for e in evs { m.apply(e) }
            return m
        }
        let left4 = Array(repeating: Event.move(.left, select: false), count: 4)
        // Backspace: arrow to the phrase, delete it, retype.
        var evs = left4 + Array(repeating: Event.backspace, count: 11) + [.text("Kolabtree")]
        var m = run(p, evs)
        check("backspace", m.result == "take control of my Kolabtree tab" && m.frozen == nil, "\(m.result ?? "nil")")
        check("backspace-candidate",
              VocabDiff.describe(m.result.flatMap { VocabDiff.candidate(pasted: p, edited: $0) }) == "collab tree -> Kolabtree")
        // Word delete.
        m = run("send it to john", [.deleteWord, .text("John")])
        check("word-delete", m.result == "send it to John", "\(m.result ?? "nil")")
        m = run("one two three", [.move(.wordLeft, select: false), .deleteWord])
        check("word-delete-mid", m.result == "one three", "\(m.result ?? "nil")")
        // Arrow navigation: word moves + shift-selection replace.
        evs = Array(repeating: Event.move(.wordLeft, select: false), count: 3)
            + [.move(.wordRight, select: true), .text("Kolab")]
        m = run(p, evs)
        check("word-nav-select", m.result == "take control of my Kolab tree tab", "\(m.result ?? "nil")")
        // Selection replace with shift+left.
        evs = left4 + Array(repeating: Event.move(.left, select: true), count: 11) + [.text("Kolabtree")]
        m = run(p, evs)
        check("selection-replace", m.result == "take control of my Kolabtree tab", "\(m.result ?? "nil")")
        // Forward delete and right arrow.
        m = run("abcd", [.move(.left, select: false), .move(.left, select: false), .forwardDelete, .move(.right, select: false), .text("X")])
        check("forward-delete", m.result == "abXd" || m.result == "abdX", "\(m.result ?? "nil")")
        // Cmd+Z makes the model uncertain and discards the result.
        m = run(p, left4 + [.backspace, .undo])
        check("undo-uncertain", m.frozen == "undo" && m.result == nil)
        // Boundary: moving before the pasted text freezes but keeps earlier certain edits.
        m = run("ab", [.backspace, .text("c")] + Array(repeating: .move(.left, select: false), count: 5) + [.text("zzz")])
        check("boundary-freeze", m.frozen == "boundary" && m.result == "ac", "\(m.result ?? "nil") \(m.frozen ?? "")")
        // Line start/end need a newline inside the pasted text.
        m = run("a\nb c", [.move(.lineStart, select: false), .text("X")])
        check("line-start", m.result == "a\nXb c", "\(m.result ?? "nil")")
        m = run("b c", [.move(.lineStart, select: false)])
        check("line-start-unknown", m.frozen == "line-boundary" || m.frozen == "boundary")
        m = run("a\nb c", [.deleteLine, .text("Z")])
        check("delete-line", m.result == "a\nZ", "\(m.result ?? "nil")")
        // Select-all freezes.
        m = run(p, [.backspace, .selectAll, .text("q")])
        check("select-all-freeze", m.frozen == "select-all" && m.result == "take control of my collab tree ta")
        // Mouse: resolved from AX caret, queued keys replay after.
        m = ReplayModel("hello wrld")
        m.mouseDown(lookup: true)
        m.apply(.text("o"))
        m.resolveCaret(location: 9, length: 0)
        check("mouse-resolved", m.result == "hello wrlod", "\(m.result ?? "nil")")
        m = ReplayModel("hello wrld")
        m.mouseDown(lookup: true)
        m.apply(.text("o"))
        m.resolveCaret(location: 8, length: 0)
        check("mouse-caret", m.result == "hello wrold", "\(m.result ?? "nil")")
        m = ReplayModel("hello")
        m.mouseDown(lookup: true)
        m.resolveCaret(location: 99, length: 0)
        check("mouse-outside", m.frozen == "mouse")
        m = ReplayModel("hello")
        m.mouseDown(lookup: false)
        check("mouse-unresolvable", m.frozen == "mouse")
        // Event mapping.
        check("map-word-delete", event(code: 51, flags: .maskAlternate, chars: "") == .deleteWord)
        check("map-line-delete", event(code: 51, flags: .maskCommand, chars: "") == .deleteLine)
        check("map-shift-line", event(code: 124, flags: [.maskCommand, .maskShift], chars: "") == .move(.lineEnd, select: true))
        check("map-undo", event(code: 6, flags: .maskCommand, chars: "z") == .undo)
        check("map-char", event(code: 0, flags: [], chars: "k") == .text("k"))
        check("map-return", event(code: 36, flags: [], chars: "\r") == .unsupported)
        check("map-cmd-v", event(code: 9, flags: .maskCommand, chars: "v") == .unsupported)
        // OCR: render text and recognise it with Vision (the capture step needs Screen Recording and is not exercised).
        if let img = ScreenOCR.render("take control of my Kolabtree tab"), let t = ScreenOCR.recognize(img) {
            check("ocr-render", t.lowercased().contains("control") && t.lowercased().contains("tab"), t)
        } else { check("ocr-render", false, "no result") }
        return fails
    }
}
