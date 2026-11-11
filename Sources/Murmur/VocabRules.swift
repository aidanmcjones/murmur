import AppKit
import Foundation

/// Extra evidence for loosened candidate rules: phonetic keys and acronym / initialism matching.
extension VocabDiff {
    /// Simplified Metaphone-style key (letters only).
    static func phoneticKey(_ word: String) -> String {
        var w = Array(word.lowercased().filter { $0.isLetter && $0.isASCII })
        if w.isEmpty { return "" }
        let vowels = Set("aeiou")
        for pre in ["kn", "gn", "pn", "ae", "wr"] where w.count > 1 && String(w[0...1]) == pre { w.removeFirst() }
        if w.first == "x" { w[0] = "s" }
        var out = ""
        var i = 0
        func at(_ k: Int) -> Character { k >= 0 && k < w.count ? w[k] : "\0" }
        while i < w.count {
            let c = w[i]
            if c == at(i - 1), c != "c" { i += 1; continue }
            switch c {
            case "a", "e", "i", "o", "u": if i == 0 { out.append("A") }
            case "b": if !(i == w.count - 1 && at(i - 1) == "m") { out.append("B") }
            case "c":
                if at(i + 1) == "h" { out.append("X"); i += 1 }
                else if "iey".contains(at(i + 1)) { if at(i - 1) != "s" { out.append("S") } }
                else if at(i - 1) != "k" { out.append("K") }
            case "d":
                if at(i + 1) == "g", "iey".contains(at(i + 2)) { out.append("J"); i += 1 } else { out.append("T") }
            case "g":
                if at(i + 1) == "h" { i += 1 }
                else if "iey".contains(at(i + 1)) { out.append("J") } else { out.append("K") }
            case "h": if vowels.contains(at(i + 1)), !"csptg".contains(at(i - 1)) { out.append("H") }
            case "k": if at(i - 1) != "c" { out.append("K") }
            case "p": if at(i + 1) == "h" { out.append("F"); i += 1 } else { out.append("P") }
            case "q": out.append("K")
            case "s": if at(i + 1) == "h" { out.append("X"); i += 1 } else { out.append("S") }
            case "t":
                if at(i + 1) == "h" { out.append("0"); i += 1 }
                else if at(i + 1) == "i", "ao".contains(at(i + 2)) { out.append("X") } else { out.append("T") }
            case "v": out.append("F")
            case "w", "y": if vowels.contains(at(i + 1)) { out.append(Character(c.uppercased())) }
            case "x": out.append("KS")
            case "z": out.append("S")
            default: out.append(Character(c.uppercased()))
            }
            i += 1
        }
        return out
    }

    static func phoneticSimilarity(_ a: [String], _ b: [String]) -> Double {
        let x = Array(a.map(phoneticKey).joined()), y = Array(b.map(phoneticKey).joined())
        if min(x.count, y.count) < 3 { return 0 }
        return 1 - Double(levenshtein(x, y)) / Double(max(x.count, y.count))
    }

    private static let numberWords: [String: String] = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                                                         "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]

    /// Initials (and number words as digits) of the heard phrase appear in order in the new token(s): "week one" -> W1A.
    static func initialismMatch(_ old: [String], _ new: [String]) -> Bool {
        var syms: [Character] = []
        for w in old {
            let l = w.lowercased()
            if let d = numberWords[l] { syms.append(contentsOf: d) }
            else if let f = l.first(where: { $0.isLetter || $0.isNumber }) { syms.append(f) }
        }
        let target = Array(new.joined().lowercased().filter { $0.isLetter || $0.isNumber })
        guard syms.count >= 2, let f = syms.first, f == target.first else { return false }
        var k = 0
        for c in target where k < syms.count && c == syms[k] { k += 1 }
        return k == syms.count
    }

    /// A plain misspelling of a common word ("recieve" -> "receive"): the new word is lowercase and known, the old one is
    /// unknown and close, and the system spellchecker itself would offer the new word among its top 3 corrections.
    static func isCommonTypoFix(_ old: String, _ new: String) -> Bool {
        guard new.allSatisfy({ $0.isLowercase }), old.allSatisfy({ $0.isLetter }),
              !unknownToSpellChecker(new), unknownToSpellChecker(old),
              levenshtein(Array(old.lowercased()), Array(new)) <= 2 else { return false }
        let g = NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (old as NSString).length), in: old,
                                              language: "en", inSpellDocumentWithTag: 0) ?? []
        return g.prefix(3).contains { $0.lowercased() == new }
    }

    /// Strongly vocab-like: digits, internal caps, acronym, or unknown to the spellchecker (known capitalised words never qualify).
    static func strongVocab(_ w: String) -> Bool {
        if w.contains(where: { $0.isNumber }) { return true }
        if w.dropFirst().contains(where: { $0.isUppercase }) { return true }
        if w.count >= 2, w.allSatisfy({ $0.isUppercase }) { return true }
        return unknownToSpellChecker(w)
    }
}

extension VocabDiff {
    /// Public generic tests for the loosened rules (made-up examples) plus negatives.
    static func ruleSelfTest() -> Int {
        var fails = 0
        func check(_ name: String, _ p: String, _ e: String, _ want: String?) {
            let got = describe(candidate(pasted: p, edited: e))
            let ok = got == (want ?? "none")
            if !ok { fails += 1 }
            print("\(ok ? "PASS" : "FAIL") rule-\(name): \"\(p)\" -> \"\(e)\": \(got)\(ok ? "" : " (expected \(want ?? "none"))")")
        }
        check("one-to-one-unknown", "ask the glorp team to join", "ask the Zyntrex team to join", "glorp -> Zyntrex")
        check("one-to-one-unknown-lower", "we use the frobnic tool", "we use the zyntrexo tool", "frobnic -> zyntrexo")
        check("initialism-number-word", "open the hub two plan today", "open the H2P plan today", "hub two -> H2P")
        check("initialism-two-tokens", "see ticket one now", "see T1D1 QA now", "ticket one -> T1D1 QA")
        check("acronym-all-caps", "the ay pee eye docs", "the API docs", nil)  // 3 words -> 1 acronym, no evidence: stays conservative
        check("digits-with-similarity", "call the model gpt four", "call the model GPT4", "gpt four -> GPT4")
        check("internal-caps", "use the ex eye ess dock", "use the XyZ dock", nil)
        for (bad, good) in [("recieve", "receive"), ("definately", "definitely"), ("teh", "the"), ("seperate", "separate"),
                            ("occured", "occurred"), ("untill", "until")] {
            check("neg-typo-\(bad)", "I will \(bad) it soon", "I will \(good) it soon", nil)
        }
        check("neg-ship-launch", "ship it", "launch it", nil)
        check("neg-meeting-tuesday", "move the meeting soon", "move the Tuesday soon", nil)
        check("neg-number", "let's meet at 3", "let's meet at 4", nil)
        check("neg-john", "send to john", "send to John", nil)
        check("neg-forward", "send it forward", "send it Forward", nil)
        check("neg-known-capital-swap", "ask the team", "ask the Forward", nil)
        check("neg-known-different", "I like the red one", "I like the Blue one", nil)
        func num(_ name: String, _ ok: Bool) { if !ok { fails += 1 }; print("\(ok ? "PASS" : "FAIL") rule-\(name)") }
        num("phonetic-same-sound", phoneticSimilarity(["fonetik"], ["phonetic"]) >= 0.7)
        num("phonetic-collab", phoneticSimilarity(["collab", "tree"], ["Kolabtree"]) >= 0.7)
        num("phonetic-different", phoneticSimilarity(["ship"], ["launch"]) < 0.7)
        num("initialism-week-one", initialismMatch(["week", "one"], ["W1A"]))
        num("initialism-needs-order", !initialismMatch(["one", "week"], ["W1A"]))
        num("initialism-single-word-no", !initialismMatch(["week"], ["W1A"]))
        num("strong-known-capital-not", !strongVocab("Tuesday") && !strongVocab("John") && !strongVocab("Forward"))
        num("strong-acronym-digits-caps", strongVocab("TXHES") && strongVocab("W1A") && strongVocab("FBPase"))
        return fails
    }

    /// Hidden mode: checks the candidate rules against pairs Wispr Flow learned from this user's edits (read-only local DB).
    static func wfParity() -> Int32 {
        let db = NSString("~/Library/Application Support/Wispr Flow/flow.sqlite").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: db) else { print("SKIP: Wispr Flow DB not found"); return 0 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-separator", "\t", "file:\(db)?immutable=1",
                       "select observedSource, phrase from Dictionary where source='user_edits' and observedSource is not null"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { print("SKIP: sqlite3 unavailable"); return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let pairs = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { l -> (String, String)? in
            let f = l.split(separator: "\t", omittingEmptySubsequences: false)
            return f.count == 2 ? (String(f[0]), String(f[1])) : nil
        }
        if pairs.isEmpty { print("SKIP: no pairs"); return 0 }
        let templates = ["open the %@ deck", "can you check %@ later today", "I think the %@ is wrong here"]
        var ok = 0
        for (heard, wanted) in pairs {
            var good = true
            var got = ""
            for t in templates {
                let a = t.replacingOccurrences(of: "%@", with: heard), b = t.replacingOccurrences(of: "%@", with: wanted)
                let c = candidate(pasted: a, edited: b)
                let want = heard.split(separator: " ").joined(separator: " ").lowercased()
                got = describe(c)
                if c == nil || c!.heard.lowercased() != want || c!.wanted != wanted { good = false; break }
            }
            if good { ok += 1 }
            print("\(good ? "PASS" : "FAIL") \(heard) -> \(wanted)\(good ? "" : " (got \(got))")")
        }
        print("parity \(ok)/\(pairs.count)")
        return ok == pairs.count ? 0 : 1
    }
}
