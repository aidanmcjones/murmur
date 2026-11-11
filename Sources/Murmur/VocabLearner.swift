import AppKit
import ApplicationServices

/// Pure diff logic: finds a "heard -> wanted" vocabulary correction between pasted and edited text.
enum VocabDiff {
    struct Candidate: Equatable { let heard: String; let wanted: String; let score: Double }

    private struct Tok { let raw: String; let word: String }

    private static func tokenize(_ s: String) -> [Tok] {
        let strip = CharacterSet.punctuationCharacters.union(.symbols)
        return s.split(whereSeparator: { $0.isWhitespace }).compactMap { part in
            let raw = String(part)
            let w = raw.trimmingCharacters(in: strip)
            return w.isEmpty ? nil : Tok(raw: raw, word: w)
        }
    }

    static func pairKey(_ heard: String, _ wanted: String) -> String {
        heard.lowercased() + "|" + wanted.lowercased()
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    private static func norm(_ ws: [String]) -> [Character] {
        Array(ws.joined().lowercased().filter { $0 != "-" && !$0.isWhitespace })
    }

    static func similarity(_ a: [String], _ b: [String]) -> Double {
        let x = norm(a), y = norm(b)
        let m = max(x.count, y.count)
        return m == 0 ? 1 : 1 - Double(levenshtein(x, y)) / Double(m)
    }

    private static func unknownToSpellChecker(_ w: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
    }

    /// Capital not at sentence start, digits, internal caps/acronym, or unknown to the spellchecker.
    private static func looksLikeVocab(_ t: Tok, sentenceStart: Bool) -> Bool {
        let w = t.word
        if w.allSatisfy({ $0.isNumber || $0.isPunctuation || $0.isSymbol }) { return false }
        if w.contains(where: { $0.isNumber }) { return true }
        if w.dropFirst().contains(where: { $0.isUppercase }) { return true }
        if let f = w.first, f.isUppercase, !sentenceStart { return true }
        return unknownToSpellChecker(w)
    }

    /// Word-level LCS hunks: (range in a, range in b) of non-matching stretches.
    private static func hunks(_ a: [Tok], _ b: [Tok]) -> [(Range<Int>, Range<Int>)] {
        let n = a.count, m = b.count
        var L = Array(repeating: Array(repeating: Int32(0), count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    L[i][j] = a[i].word == b[j].word ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1])
                }
            }
        }
        var out: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0, si = 0, sj = 0
        func flush() { if i > si || j > sj { out.append((si..<i, sj..<j)) } }
        while i < n || j < m {
            if i < n, j < m, a[i].word == b[j].word {
                flush(); i += 1; j += 1; si = i; sj = j
            } else if j < m, i == n || L[i][j + 1] >= L[i + 1][j] { j += 1 }
            else { i += 1 }
        }
        flush()
        return out
    }

    static func candidate(pasted: String, edited: String, dictionary: [DictEntry] = [],
                          rejected: Set<String> = []) -> Candidate? {
        let a = tokenize(pasted), b = tokenize(edited)
        if a.isEmpty || b.isEmpty || a.count > 4000 || b.count > 4000 { return nil }
        var best: Candidate?
        for (ra, rb) in hunks(a, b) {
            guard (1...3).contains(ra.count), (1...3).contains(rb.count) else { continue }
            let old = a[ra].map { $0.word }, new = b[rb].map { $0.word }
            let heard = old.joined(separator: " "), wanted = new.joined(separator: " ")
            let caseOnly = heard.lowercased() == wanted.lowercased()
            if caseOnly, !new.contains(where: { unknownToSpellChecker($0) }) { continue }
            var vocab = false
            for (k, t) in b[rb].enumerated() {
                let idx = rb.lowerBound + k
                let start = idx == 0 || ".!?".contains(b[idx - 1].raw.last ?? " ")
                if looksLikeVocab(t, sentenceStart: start) { vocab = true; break }
            }
            let sim = similarity(old, new)
            // A real word replacing a non-word that sounds alike (e.g. zoanthellae -> zooxanthellae).
            if !vocab, sim >= 0.7, !caseOnly, old.contains(where: { unknownToSpellChecker($0) }) { vocab = true }
            if !vocab { continue }
            let ol = norm(old).count, nl = norm(new).count
            let sameFirst = norm(old).first == norm(new).first
            let lenRatio = Double(min(ol, nl)) / Double(max(1, max(ol, nl)))
            guard sim >= 0.5 || (sameFirst && lenRatio >= 0.7) else { continue }
            if rejected.contains(pairKey(heard, wanted)) { continue }
            if dictionary.contains(where: { $0.phrase.lowercased() == heard.lowercased()
                && ($0.replacement ?? "").lowercased() == wanted.lowercased() }) { continue }
            let c = Candidate(heard: heard, wanted: wanted, score: sim + (caseOnly ? 0 : 0.1))
            if best == nil || c.score > best!.score { best = c }
        }
        return best
    }

    /// Maps the pasted region [rs, re) of `old` through the edit to `new`; returns (oldRegion, newRegion).
    static func editedRegion(old: String, new: String, regionStart rs: Int, regionEnd re: Int) -> (String, String)? {
        let o = Array(old.utf16), n = Array(new.utf16)
        guard rs >= 0, re <= o.count, rs < re else { return nil }
        var cp = 0
        while cp < o.count, cp < n.count, o[cp] == n[cp] { cp += 1 }
        var cs = 0
        while cs < o.count - cp, cs < n.count - cp, o[o.count - 1 - cs] == n[n.count - 1 - cs] { cs += 1 }
        let zoneEnd = o.count - cs
        if cp >= re || zoneEnd <= rs { return nil }  // edit is outside the pasted text
        let s1 = min(rs, cp)
        let e1 = re >= zoneEnd ? re + (n.count - o.count) : n.count - cs
        guard s1 >= 0, e1 > s1, e1 <= n.count else { return nil }
        return (String(decoding: o[rs..<re], as: UTF16.self), String(decoding: n[s1..<e1], as: UTF16.self))
    }

    // MARK: Self test

    static let cases: [(String, String, String?)] = [
        ("take control of my collab tree tab", "take control of my Kolabtree tab", "collab tree -> Kolabtree"),
        ("file it into the Neely AI forward repo", "file it into the Neeley AI Forward repo", "Neely -> Neeley"),
        ("I think we should ship it", "I think we should launch it on Friday", nil),
        ("send it to john", "send it to John", nil),
        ("how does zoanthellae bleach coral", "how does zooxanthellae bleach coral", "zoanthellae -> zooxanthellae"),
        ("let's meet at 3", "let's meet at 4", nil),
    ]

    static func describe(_ c: Candidate?) -> String { c.map { "\($0.heard) -> \($0.wanted)" } ?? "none" }

    static func selfTest() -> Int32 {
        var fails = 0
        for (p, e, want) in cases {
            let got = describe(candidate(pasted: p, edited: e))
            let ok = got == (want ?? "none")
            if !ok { fails += 1 }
            print("\(ok ? "PASS" : "FAIL") \"\(p)\" -> \"\(e)\": \(got)\(ok ? "" : " (expected \(want ?? "none"))")")
        }
        // Anchoring through an edit elsewhere in the document.
        let old = "Intro line.\ntake control of my collab tree tab\nOutro."
        let new = "Intro line!!\ntake control of my Kolabtree tab\nOutro."
        let reg = (old as NSString).range(of: "take control of my collab tree tab")
        if let (o, n) = editedRegion(old: old, new: new, regionStart: reg.location, regionEnd: reg.location + reg.length),
           describe(candidate(pasted: o, edited: n)) == "collab tree -> Kolabtree" {
            print("PASS anchor")
        } else { fails += 1; print("FAIL anchor") }
        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
        return fails == 0 ? 0 : 1
    }
}

/// Watches the focused text element after a paste and suggests vocabulary from the user's correction.
final class VocabLearner {
    static let shared = VocabLearner()

    private var element: AXUIElement?
    private var observer: AXObserver?
    private var pid: pid_t = 0
    private var bundleId = ""
    private var pasted = ""
    private var snapshot = ""
    private var region = (0, 0)
    private var lastValue = ""
    private var dirtyAt: Date?
    private var startedAt = Date()
    private var timer: Timer?
    private var generation = 0

    static let maxChars = 50_000
    static let watchSeconds: TimeInterval = 45
    static let debounce: TimeInterval = 2.5

    // MARK: AX helpers

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let r = f, CFGetTypeID(r) == AXUIElementGetTypeID() else { return nil }
        let el = r as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.4)
        return el
    }

    private func isSecure(_ el: AXUIElement) -> Bool {
        for attr in [kAXRoleAttribute, kAXSubroleAttribute] {
            var r: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, attr as CFString, &r) == .success,
               (r as? String) == "AXSecureTextField" { return true }
        }
        return false
    }

    private func value(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private func selectionLocation(_ el: AXUIElement) -> Int? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success,
              let ref = r, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(ref as! AXValue, .cfRange, &range) ? range.location : nil
    }

    // MARK: Lifecycle

    /// Call right after a successful paste (main thread).
    func pasted(_ text: String, bundleId: String) {
        stop()
        guard Settings.learnVocab, AXIsProcessTrusted(), !text.isEmpty else { return }
        generation += 1
        let gen = generation
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard pid != 0 else { return }
        attempt(text, bundleId: bundleId, pid: pid, gen: gen, delays: [0.15, 0.5, 1.0])
    }

    private func attempt(_ text: String, bundleId: String, pid: pid_t, gen: Int, delays: [Double]) {
        guard let d = delays.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
            guard let self, gen == self.generation else { return }
            if self.begin(text, bundleId: bundleId, pid: pid) { return }
            self.attempt(text, bundleId: bundleId, pid: pid, gen: gen, delays: Array(delays.dropFirst()))
        }
    }

    /// Returns true when watching started or the target is permanently unsuitable.
    private func begin(_ text: String, bundleId: String, pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let el = focusedElement(pid: pid) else { return true }
        if isSecure(el) { return true }
        guard let v = value(el), (v as NSString).length <= Self.maxChars else { return true }
        let ns = v as NSString
        let len = (text as NSString).length
        var start = -1
        if let loc = selectionLocation(el), loc - len >= 0, loc <= ns.length,
           ns.substring(with: NSRange(location: loc - len, length: len)) == text { start = loc - len }
        else {
            let r = ns.range(of: text, options: .backwards)
            if r.location != NSNotFound { start = r.location }
        }
        guard start >= 0 else { return false }  // paste may not have landed yet
        element = el; self.pid = pid; self.bundleId = bundleId
        pasted = text; snapshot = v; lastValue = v
        region = (start, start + len)
        dirtyAt = nil; startedAt = Date()
        var obs: AXObserver?
        if AXObserverCreate(pid, { _, _, _, _ in VocabLearner.shared.poll() }, &obs) == .success, let o = obs {
            AXObserverAddNotification(o, el, kAXValueChangedNotification as CFString, nil)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
            observer = o
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in VocabLearner.shared.poll() }
        DebugLog.log("learn: watching app=\(bundleId) len=\(len)")
        return true
    }

    /// Ends the current watch (new dictation, focus moved, timeout). Evaluates once if there are pending edits.
    func stop(evaluate: Bool = false) {
        generation += 1
        if evaluate, element != nil, dirtyAt != nil { _ = evaluateNow() }
        timer?.invalidate(); timer = nil
        if let o = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        }
        observer = nil; element = nil; dirtyAt = nil
    }

    private func poll() {
        guard let el = element else { return }
        if Date().timeIntervalSince(startedAt) > Self.watchSeconds
            || NSWorkspace.shared.frontmostApplication?.processIdentifier != pid
            || focusedElement(pid: pid).map({ CFEqual($0, el) }) != true {
            stop(evaluate: true); return
        }
        guard let v = value(el) else { stop(); return }
        if v != lastValue { lastValue = v; dirtyAt = Date() }
        if let d = dirtyAt, Date().timeIntervalSince(d) >= Self.debounce {
            dirtyAt = nil
            if evaluateNow() { stop() }
        }
    }

    /// Returns true when a suggestion was shown.
    private func evaluateNow() -> Bool {
        guard let el = element, let v = value(el), (v as NSString).length <= Self.maxChars,
              let (o, n) = VocabDiff.editedRegion(old: snapshot, new: v, regionStart: region.0, regionEnd: region.1),
              (n as NSString).length <= (o as NSString).length * 3 + 200,
              let c = VocabDiff.candidate(pasted: o, edited: n, dictionary: UserDictionary.load(),
                                          rejected: Settings.rejectedPairs) else { return false }
        suggest(c)
        return true
    }

    private func suggest(_ c: VocabDiff.Candidate) {
        let app = bundleId
        DebugLog.log("learn: suggest \(c.heard) -> \(c.wanted)")
        logHistory("vocab-suggest", c, app)
        SuggestionPanel.show(heard: c.heard, wanted: c.wanted) { action in
            switch action {
            case .add:
                let n = UserDictionary.addLearned(heard: c.heard, wanted: c.wanted)
                DebugLog.log("learn: accepted \(c.heard) -> \(c.wanted) (+\(n))")
                self.logHistory("vocab-add", c, app)
            case .dismiss, .timeout:
                DebugLog.log("learn: dismissed \(c.heard) -> \(c.wanted)")
                self.logHistory("vocab-dismiss", c, app)
            case .never:
                Settings.rejectedPairs.insert(VocabDiff.pairKey(c.heard, c.wanted))
                DebugLog.log("learn: rejected \(c.heard) -> \(c.wanted)")
                self.logHistory("vocab-reject", c, app)
            }
        }
    }

    private func logHistory(_ mode: String, _ c: VocabDiff.Candidate, _ app: String) {
        History.append(HistoryEntry(ts: ISO8601DateFormatter().string(from: Date()), raw: c.heard, cleaned: c.wanted,
                                    app: app, asrMs: 0, llmMs: 0, totalMs: 0, mode: mode))
    }

    // MARK: Debug hooks (only when defaults key debugHooks=true)

    /// Distributed notifications "MurmurDebugPaste" {text} and "MurmurDebugSuggestion" {action: add|dismiss|never}.
    static func installDebugHooks() {
        guard UserDefaults.standard.bool(forKey: "debugHooks") else { return }
        let c = DistributedNotificationCenter.default()
        c.addObserver(forName: NSNotification.Name("MurmurDebugPaste"), object: nil, queue: .main) { n in
            guard let t = n.userInfo?["text"] as? String else { return }
            DebugLog.log("learn: debug paste len=\(t.count)")
            shared.pasted(t, bundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        }
        c.addObserver(forName: NSNotification.Name("MurmurDebugSuggestion"), object: nil, queue: .main) { n in
            switch n.userInfo?["action"] as? String {
            case "add": SuggestionPanel.perform(.add)
            case "never": SuggestionPanel.perform(.never)
            default: SuggestionPanel.perform(.dismiss)
            }
        }
    }
}
