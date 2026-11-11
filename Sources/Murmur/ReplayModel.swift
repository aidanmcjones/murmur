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
        /// A selection reported by AX after a mouse selection, Cmd+A or a shift-move past the pasted text.
        case select(Selection)
    }

    /// AXSelectedText and/or AXSelectedTextRange. `start`/`end` are UTF-16 offsets relative to the start of the
    /// original paste in the field (negative = before it); they are only set when the AX value is readable.
    /// `via` (mouse, double_click, cmd_a, shift_word_left...) is informational.
    struct Selection: Equatable {
        var text: String?
        var start: Int?
        var end: Int?
        var via: String

        init(text: String?, start: Int? = nil, end: Int? = nil, via: String) {
            self.text = text; self.start = start; self.end = end; self.via = via
        }

        /// From an absolute AX range: relative offsets only when the paste's start in the AX value is known.
        static func fromAX(text: String?, location: Int?, length: Int?, regionStart: Int, via: String) -> Selection? {
            var s = Selection(text: text, via: via)
            if regionStart >= 0, let l = location, let n = length, l >= 0, n >= 0 { s.start = l - regionStart; s.end = l + n - regionStart }
            return s.text == nil && s.start == nil ? nil : s
        }
    }

    private let pastedText: String
    /// The paste plus neighbouring text learned from a selection that crossed its boundary.
    private var original: String
    /// Characters of `original` before / after the paste.
    private(set) var lead = 0
    private(set) var trail = 0
    /// UTF-16 offset of `chars[0]` relative to the start of the original paste (<= 0).
    private var origin = 0
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
        pastedText = pasted
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

    /// What `result` is diffed against: the paste, extended by any neighbouring text a selection revealed.
    var baseText: String { original }

    /// The candidate for the replayed edit. With neighbouring text in the base, the heard words must touch the
    /// paste itself (a selection outside it must not produce a suggestion about unrelated text).
    func candidate(dictionary: [DictEntry] = [], rejected: Set<String> = []) -> VocabDiff.Candidate? {
        guard let r = result, let c = VocabDiff.candidate(pasted: original, edited: r, dictionary: dictionary, rejected: rejected)
        else { return nil }
        if lead == 0 && trail == 0 { return c }
        let base = Array(original), h = Array(c.heard)
        let span = lead..<(base.count - trail)
        guard !h.isEmpty, h.count <= base.count else { return nil }
        func eq(_ a: Character, _ b: Character) -> Bool { a == b || a.lowercased() == b.lowercased() }
        for i in 0...(base.count - h.count) where (0..<h.count).allSatisfy({ eq(base[i + $0], h[$0]) }) {
            if i < span.upperBound && i + h.count > span.lowerBound { return c }
        }
        return nil
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
            case .lineStart: target = lineStart(select ? cursor : sel.lowerBound)
            case .lineEnd: target = lineEnd(select ? cursor : sel.upperBound)
            }
            guard let t = target else { freeze("boundary"); return }
            cursor = t
            if !select { anchor = t }
        case .selectAll: counts.other += 1; freeze("select-all")
        case .select(let s): counts.nav += 1; select(s)
        case .undo: counts.other += 1; freeze("undo", discard: true)
        case .unsupported: counts.other += 1; freeze("unsupported")
        }
    }

    /// UTF-16 offset (relative to `chars[0]`) -> character index; nil inside a character or out of range.
    private func charIndex(utf16 u: Int) -> Int? {
        var acc = 0
        for (i, c) in chars.enumerated() {
            if acc == u { return i }
            if acc > u { return nil }
            acc += c.utf16.count
        }
        return acc == u ? chars.count : nil
    }

    private func occurrences(of t: [Character], in hay: [Character]) -> [Int] {
        guard !t.isEmpty, t.count <= hay.count else { return [] }
        return (0...(hay.count - t.count)).filter { i in (0..<t.count).allSatisfy { hay[i + $0] == t[$0] } }
    }

    /// Splits `text` into UTF-16 prefix / middle / suffix; nil when a cut falls inside a character.
    private static func split(_ text: String, before: Int, after: Int) -> ([Character], [Character], [Character])? {
        let u = Array(text.utf16)
        guard before >= 0, after >= 0, before + after <= u.count else { return nil }
        let parts = [u[0..<before], u[before..<(u.count - after)], u[(u.count - after)...]].map { String(utf16CodeUnits: Array($0), count: $0.count) }
        guard parts.map({ $0.utf16.count }) == [before, u.count - before - after, after], parts.joined() == text else { return nil }
        return (Array(parts[0]), Array(parts[1]), Array(parts[2]))
    }

    /// Adds neighbouring text (revealed by a selection crossing the paste's boundary) to the model and the base.
    private mutating func extend(before: [Character], after: [Character]) {
        if !before.isEmpty {
            chars.insert(contentsOf: before, at: 0)
            original = String(before) + original
            lead += before.count
            origin -= String(before).utf16.count
            cursor += before.count; anchor += before.count
        }
        if !after.isEmpty {
            chars.append(contentsOf: after)
            original += String(after)
            trail += after.count
        }
    }

    /// Keeps the selection's direction: a lookup after shift+left that kept the old anchor at its end leaves the
    /// caret at the start, so further shift-moves extend the right end.
    private mutating func setSelection(_ lo: Int, _ hi: Int) {
        if lo != hi, anchor == hi { cursor = lo } else { anchor = lo; cursor = hi }
    }

    /// Sets the selection reported by AX. Prefers the relative range; falls back to locating the selected text
    /// (the occurrence nearest the caret). A selection wholly outside the known text freezes the model.
    private mutating func select(_ s: Selection) {
        if let a = s.start, let b = s.end, a <= b {
            let u0 = a - origin, u1 = b - origin, total = String(chars).utf16.count
            if u1 < 0 || u0 > total || (u0 != u1 && (u1 <= 0 || u0 >= total)) { freeze("select-outside"); return }
            if u0 >= 0, u1 <= total, let i0 = charIndex(utf16: u0), let i1 = charIndex(utf16: u1),
               s.text == nil || String(chars[i0..<i1]) == s.text {
                setSelection(i0, i1); return
            }
            // Crossing the boundary: the selected text supplies the neighbouring characters.
            if let t = s.text, t.utf16.count == u1 - u0, u0 < 0 || u1 > total,
               let (pre, mid, post) = Self.split(t, before: max(0, -u0), after: max(0, u1 - total)),
               let i0 = charIndex(utf16: max(0, u0)), let i1 = charIndex(utf16: min(total, u1)),
               Array(chars[i0..<i1]) == mid,
               (pre.isEmpty || i0 == 0), (post.isEmpty || i1 == chars.count) {
                extend(before: pre, after: post)
                setSelection(pre.isEmpty ? i0 : 0, (pre.isEmpty ? i0 : 0) + pre.count + mid.count + post.count)
                return
            }
        }
        guard let text = s.text, !text.isEmpty else { freeze("select-unknown"); return }
        let t = Array(text)
        let hits = occurrences(of: t, in: chars)
        if !hits.isEmpty {
            let here = sel
            func dist(_ i: Int) -> Int { max(0, i - here.upperBound, here.lowerBound - (i + t.count)) }
            let best = hits.map(dist).min()!
            let at = hits.filter { dist($0) == best }
            // Equally near occurrences hold the same text, so either gives the same heard/wanted.
            setSelection(at[0], at[0] + t.count)
            return
        }
        // The selection covers the whole paste (e.g. Cmd+A in a field holding more text).
        let whole = occurrences(of: chars, in: t)
        if whole.count == 1, !chars.isEmpty {
            extend(before: Array(t[0..<whole[0]]), after: Array(t[(whole[0] + chars.count)...]))
            setSelection(0, chars.count)
            return
        }
        freeze(whole.count > 1 ? "select-ambiguous" : "select-outside")
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

    /// Starts an AX selection lookup (mouse-down, Cmd+A, shift-move past the paste): keys queue until `resolve`.
    mutating func awaitSelection() {
        if frozen != nil { return }
        awaitingCaret = true
    }

    var awaiting: Bool { awaitingCaret }

    /// Applies the looked-up selection (it already reflects the triggering key), then the queued keys.
    /// When AX had nothing, `fallback` (the triggering key) is replayed instead, else the model freezes with `failKind`.
    mutating func resolve(_ s: Selection?, fallback: Event? = nil, failKind: String) {
        guard awaitingCaret else { return }
        awaitingCaret = false
        let q = queue
        queue = []
        if let s { apply(.select(s)) } else if let f = fallback { apply(f) } else { freeze(failKind); return }
        for e in q { apply(e) }
    }

    /// True when the model cannot place this selection itself and the learner should ask AX: a shift-move that
    /// leaves the known text, or shift+Cmd+left/right (soft-wrapped lines end where only the app knows).
    func selectionNeedsLookup(_ e: Event) -> Bool {
        guard frozen == nil, !awaitingCaret else { return false }
        if e == .selectAll { return true }
        guard case .move(let m, true) = e else { return false }
        switch m {
        case .left, .wordLeft: return cursor == 0
        case .right, .wordRight: return cursor >= chars.count
        case .lineStart, .lineEnd: return true
        }
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
        // Replace-everything flows: Cmd+A then typing leaves the model uncertain (frozen at the last known text).
        m = run("one two", [.selectAll, .text("three")])
        check("select-all-replace-uncertain", m.frozen == "select-all" && m.result == nil)
        // Option/Command arrows with selection.
        m = run("alpha beta gamma", [.move(.wordLeft, select: false), .move(.wordLeft, select: true), .text("B")])
        check("shift-word-select-replace", m.result == "alpha Bgamma", "\(m.result ?? "nil")")
        m = run("alpha beta", [.move(.wordLeft, select: true), .move(.wordLeft, select: true), .backspace])
        check("shift-word-select-delete", m.result == "", "\(m.result ?? "nil")")
        m = run("a\nbcd", [.move(.lineStart, select: true), .text("X")])
        check("shift-line-select", m.result == "a\nX", "\(m.result ?? "nil")")
        m = run("a\nbcd\ne", [.move(.left, select: false), .move(.left, select: false), .move(.left, select: false), .move(.lineEnd, select: false), .text("!")])
        check("line-end", m.result == "a\nbcd!\ne", "\(m.result ?? "nil")")
        m = run("hello world", [.move(.wordLeft, select: true), .move(.left, select: false), .text("_")])
        check("left-collapses-selection", m.result == "hello _world", "\(m.result ?? "nil")")
        m = run("don't stop", [.deleteWord, .deleteWord])
        check("delete-word-apostrophe", m.result == "", "\(m.result ?? "nil")")
        m = run("abc", [.text("d"), .undo, .text("e")])
        check("undo-then-typing-ignored", m.result == nil && m.frozen == "undo")
        m = run("abc", [.unsupported, .text("x")])
        check("unsupported-key-freezes", m.frozen == "unsupported" && m.result == nil)
        // Event mapping.
        check("map-word-delete", event(code: 51, flags: .maskAlternate, chars: "") == .deleteWord)
        check("map-line-delete", event(code: 51, flags: .maskCommand, chars: "") == .deleteLine)
        check("map-shift-line", event(code: 124, flags: [.maskCommand, .maskShift], chars: "") == .move(.lineEnd, select: true))
        check("map-undo", event(code: 6, flags: .maskCommand, chars: "z") == .undo)
        check("map-char", event(code: 0, flags: [], chars: "k") == .text("k"))
        check("map-return", event(code: 36, flags: [], chars: "\r") == .unsupported)
        check("map-cmd-v", event(code: 9, flags: .maskCommand, chars: "v") == .unsupported)
        // OCR render (the capture step needs Screen Recording and is not exercised headlessly).
        if let img = ScreenOCR.render("take control of my Kolabtree tab"), let t = ScreenOCR.recognize(img) {
            check("ocr-render", t.lowercased().contains("control") && t.lowercased().contains("tab"), t)
        } else { check("ocr-render", false, "no result") }
        return fails + ScreenOCR.selfTest() + selectionSelfTest()
    }

    /// Corrections made by selecting text: every selection method x (a) type over it / (b) delete then type.
    static func selectionSelfTest() -> Int {
        var fails = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { fails += 1 }
            print("\(ok ? "PASS" : "FAIL") select-\(name)\(ok ? "" : " \(detail)")")
        }
        func sel(_ t: String?, _ r: [Int]? = nil, _ via: String = "mouse") -> Event { .select(.init(text: t, start: r?[0], end: r?[1], via: via)) }
        let p = "take control of my collab tree tab", fixed = "take control of my Kolabtree tab", kola = "collab tree -> Kolabtree"
        let shiftL = Event.move(.left, select: true), shiftR = Event.move(.right, select: true)
        let left = Event.move(.left, select: false), wl = Event.move(.wordLeft, select: false)
        func run(_ name: String, _ start: String, _ evs: [Event], result: String?, cand: String, frozen: String? = nil) {
            var m = ReplayModel(start)
            for e in evs { m.apply(e) }
            let got = VocabDiff.describe(m.candidate())
            check(name, m.result == result && got == cand && m.frozen == frozen,
                  "result=\(m.result ?? "nil") cand=\(got) frozen=\(m.frozen ?? "no")")
        }
        let typeA = [Event.text("Kolabtree")], typeB = [Event.backspace, .text("Kolabtree")]
        for (variant, tail) in [("a", typeA), ("b", typeB)] {
            run("drag-range-\(variant)", p, [sel("collab tree", [19, 30])] + tail, result: fixed, cand: kola)
            run("drag-text-only-\(variant)", p, [sel("collab tree")] + tail, result: fixed, cand: kola)
            run("double-click-\(variant)", p, [sel("collab", [19, 25], "double_click")] + tail + [sel("tree", [29, 33], "double_click"), .backspace, .backspace],
                result: fixed, cand: kola)
            run("triple-click-\(variant)", p, [sel(p, [0, 34], "triple_click")] + (variant == "a" ? [] : [.backspace]) + [.text(fixed)],
                result: fixed, cand: kola)
            run("cmd-a-\(variant)", "collab tree", [sel("Notes: collab tree, ok", nil, "cmd_a")] + (variant == "a" ? [] : [.backspace])
                + [.text("Notes: Kolabtree, ok")], result: "Notes: Kolabtree, ok", cand: kola)
            run("shift-left-\(variant)", p, Array(repeating: left, count: 4) + Array(repeating: shiftL, count: 11) + tail, result: fixed, cand: kola)
            run("shift-right-\(variant)", p, Array(repeating: left, count: 15) + Array(repeating: shiftR, count: 11) + tail, result: fixed, cand: kola)
            run("shift-opt-left-\(variant)", p, Array(repeating: Event.move(.wordLeft, select: true), count: 3)
                + (variant == "a" ? [] : [.backspace]) + [.text("Kolabtree tab")], result: fixed, cand: kola)
            run("shift-opt-right-\(variant)", p, [wl, wl, wl, .move(.wordRight, select: true), .move(.wordRight, select: true)] + tail,
                result: fixed, cand: kola)
            run("shift-cmd-left-\(variant)", "note\ncollab tree", [.move(.lineStart, select: true)] + tail, result: "note\nKolabtree", cand: kola)
            run("shift-cmd-left-ax-\(variant)", "collab tree", [sel("say collab tree", [-4, 11], "shift_lineStart")]
                + (variant == "a" ? [] : [.backspace]) + [.text("say Kolabtree")], result: "say Kolabtree", cand: kola)
            run("shift-cmd-right-\(variant)", "x\ncollab tree\nok", [left, left, left, .move(.lineStart, select: false), .move(.lineEnd, select: true)]
                + tail, result: "x\nKolabtree\nok", cand: kola)
            run("across-start-\(variant)", "tree tab", [sel("collab tree", [-7, 4])] + tail, result: "Kolabtree tab", cand: kola)
            run("across-end-\(variant)", "my collab", [sel("collab tree", [3, 14])] + tail, result: "my Kolabtree", cand: kola)
        }
        // Shift-move past the paste: the model asks for an AX lookup, then continues with the reported selection.
        var m = ReplayModel("tree tab")
        for e in [wl, .move(.wordLeft, select: true)] { m.apply(e) }
        check("boundary-needs-lookup", m.selectionNeedsLookup(.move(.wordLeft, select: true)) && !m.selectionNeedsLookup(.move(.wordRight, select: true)))
        m.awaitSelection()
        m.apply(.text("Kolabtree "))  // typed before the lookup returned: queued
        m.resolve(.init(text: "collab tree ", start: -7, end: 5, via: "shift_wordLeft"), failKind: "select")
        check("boundary-lookup-resolves", m.result == "Kolabtree tab" && m.baseText == "collab tree tab" && m.frozen == nil
              && VocabDiff.describe(m.candidate()) == kola, "\(m.result ?? "nil")")
        m = ReplayModel("tree tab")
        for e in [wl, wl] { m.apply(e) }
        m.awaitSelection()
        m.resolve(nil, fallback: .move(.wordLeft, select: true), failKind: "select")
        check("boundary-lookup-failed-falls-back", m.frozen == "boundary")
        m = ReplayModel(p)
        check("cmd-a-needs-lookup", m.selectionNeedsLookup(.selectAll) && m.selectionNeedsLookup(.move(.lineStart, select: true)))
        m.awaitSelection()
        m.resolve(nil, fallback: .selectAll, failKind: "select")
        check("cmd-a-lookup-failed-uncertain", m.frozen == "select-all" && m.result == nil)
        m = ReplayModel(p)
        m.awaitSelection()
        m.resolve(nil, failKind: "mouse")
        check("mouse-lookup-failed-uncertain", m.frozen == "mouse")
        // Partial word and multi-word phrase.
        run("partial-word", p, [sel("ollab", [20, 25]), .text("olab")], result: "take control of my colab tree tab", cand: "collab -> colab")
        run("partial-two-words", p, [sel("collab tr", [19, 28]), .text("Kolabtr")], result: fixed, cand: kola)
        // Selections outside the paste never yield a suggestion about unrelated text.
        run("outside-range", "collab tree", [sel("Hello", [-12, -7]), .text("Hi")], result: nil, cand: "none", frozen: "select-outside")
        run("outside-adjacent", "collab tree", [sel("Hello ", [-6, 0]), .text("Hi ")], result: nil, cand: "none", frozen: "select-outside")
        run("outside-text-only", "collab tree", [sel("unrelated"), .text("other")], result: nil, cand: "none", frozen: "select-outside")
        run("outside-after-edit", p, [.backspace, sel("elsewhere"), .text("x")], result: "take control of my collab tree ta", cand: "tab -> ta",
            frozen: "select-outside")  // the earlier certain edit is kept; nothing about the outside text
        run("across-edit-only-outside", "collab tree tab", [sel("Hello c", [-6, 1]), .text("Hi c")], result: "Hi collab tree tab", cand: "none")
        // Undo after replacing a selection: uncertain, discarded.
        run("undo-after-replace", p, [sel("collab tree", [19, 30]), .text("Kolabtree"), .undo], result: nil, cand: "none", frozen: "undo")
        // Arrows without shift collapse the selection.
        run("arrow-left-collapses", p, [sel("collab tree", [19, 30]), left, .text("the ")], result: "take control of my the collab tree tab",
            cand: VocabDiff.describe(VocabDiff.candidate(pasted: p, edited: "take control of my the collab tree tab")))
        run("arrow-right-collapses", p, [sel("collab", [19, 25]), .move(.right, select: false), .text("s")],
            result: "take control of my collabs tree tab", cand: VocabDiff.describe(VocabDiff.candidate(pasted: p, edited: "take control of my collabs tree tab")))
        run("cmd-left-collapses-to-start", "a\nbc de", [sel("de", [5, 7]), .move(.lineStart, select: false), .text("X")], result: "a\nXbc de",
            cand: VocabDiff.describe(VocabDiff.candidate(pasted: "a\nbc de", edited: "a\nXbc de")))
        // Caret clicks and ambiguous text.
        run("click-caret", p, [sel("", [15, 15]), .text(" my")], result: "take control of my my collab tree tab",
            cand: VocabDiff.describe(VocabDiff.candidate(pasted: p, edited: "take control of my my collab tree tab")))
        run("click-no-info", p, [sel("", nil), .text("x")], result: nil, cand: "none", frozen: "select-unknown")
        run("repeated-word-nearest", "the cat and the dog", [left, left, left, left, sel("the", nil, "double_click"), .text("a")],
            result: "the cat and a dog", cand: VocabDiff.describe(VocabDiff.candidate(pasted: "the cat and the dog", edited: "the cat and a dog")))
        run("range-mismatch-uses-text", p, [sel("collab tree", [0, 11]), .text("Kolabtree")], result: fixed, cand: kola)
        run("emoji-utf16-range", "go 😀 collab tree", [sel("collab tree", [6, 17]), .text("Kolabtree")], result: "go 😀 Kolabtree", cand: kola)
        // AX selection read from mock trees -> model; and the AX diff tier on the same edits (AX-readable apps).
        let before = "Notes: take control of my collab tree tab, ok"
        let field = AXRead.Fake(["AXRole": "AXTextArea", "AXValue": before, "AXSelectedText": "collab tree",
                                 "AXSelectedTextRange": AXRead.rangeValue(26, 11)])
        let r = AXRead.selection(field)
        let s1 = Selection.fromAX(text: r.text, location: r.range?.location, length: r.range?.length, regionStart: 7, via: "mouse")
        check("ax-mock-selection", s1 == Selection(text: "collab tree", start: 19, end: 30, via: "mouse"), "\(String(describing: s1))")
        m = ReplayModel(p)
        if let s1 { m.apply(.select(s1)) }
        m.apply(.text("Kolabtree"))
        check("ax-mock-replay", VocabDiff.describe(m.candidate()) == kola)
        let s2 = Selection.fromAX(text: r.text, location: r.range?.location, length: r.range?.length, regionStart: -1, via: "mouse")
        check("ax-mock-unreadable-text-only", s2?.start == nil && s2?.text == "collab tree")
        check("ax-mock-nothing", Selection.fromAX(text: nil, location: nil, length: nil, regionStart: 7, via: "mouse") == nil
              && AXRead.selection(AXRead.Fake(["AXRole": "AXTextArea"])).range == nil)
        check("ax-mock-deadline-skips-text", AXRead.selection(field, deadline: .distantPast).text == nil)
        let afterA = "Notes: take control of my Kolabtree tab, ok"
        let (cMid, _) = VocabDiff.axCandidate(pasted: p, snapshot: before, now: "Notes: take control of my  tab, ok", region: (7, 41))
        check("ax-diff-after-delete-none", cMid == nil, VocabDiff.describe(cMid))
        for (name, after, snapRegion) in [("ax-diff-replace-selection", afterA, (7, 41)), ("ax-diff-fuzzy-region", afterA, (-1, -1))] {
            let (c, tier) = VocabDiff.axCandidate(pasted: p, snapshot: before, now: after, region: snapRegion)
            check(name, VocabDiff.describe(c) == kola, "\(VocabDiff.describe(c)) \(tier)")
        }
        let (cOut, _) = VocabDiff.axCandidate(pasted: p, snapshot: before, now: "Hi: take control of my collab tree tab, ok", region: (7, 41))
        check("ax-diff-outside-none", cOut == nil, VocabDiff.describe(cOut))
        return fails
    }
}
