import Foundation

struct PipelineResult {
    var raw: String
    var cleaned: String
    var final: String
    var asrMs: Int
    var llmMs: Int
    var mode: Cleanup.Mode = .det
}

/// Holds the raw transcript of an in-flight run as soon as ASR finishes, so the caller can paste a
/// deterministic cleanup of it if the LLM stage misses the post-release deadline.
final class RawBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: (String, Int)?
    var value: (String, Int)? { lock.lock(); defer { lock.unlock() }; return _v }
    func set(_ v: (String, Int)) { lock.lock(); _v = v; lock.unlock() }
}

enum Fuzzy {
    /// Lowercase, alphanumerics only, repeated characters collapsed: "Collab tree" -> "colabtre".
    static func norm(_ s: String) -> String {
        var out = ""
        for c in s.lowercased() where c.isLetter || c.isNumber {
            if out.last != c { out.append(c) }
        }
        return out
    }

    static func eligible(_ e: DictEntry) -> Bool {
        guard let r = e.replacement, !r.isEmpty else { return false }
        return e.learned == true
    }

    private static let wordRe = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")

    /// Replaces any 1-3 consecutive whole words (separated by spaces or hyphens) whose normalized form
    /// equals the normalized phrase.
    static func apply(_ text: String, phrase: String, replacement: String) -> String {
        let target = norm(phrase)
        guard target.count >= 5 else { return text }
        let ns = text as NSString
        let words = wordRe.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range }
        func joined(_ i: Int, _ j: Int) -> Bool {  // words i and j=i+1 separated only by blanks/hyphens
            let gap = ns.substring(with: NSRange(location: words[i].upperBound, length: words[j].location - words[i].upperBound))
            return !gap.isEmpty && gap.allSatisfy { $0 == " " || $0 == "\t" || $0 == "-" || $0 == "\u{2013}" }
        }
        var hits: [NSRange] = []
        var i = 0
        while i < words.count {
            var matched = 0
            var acc = ""
            for len in 1...3 where i + len <= words.count {
                if len > 1, !joined(i + len - 2, i + len - 1) { break }
                acc += norm(ns.substring(with: words[i + len - 1]))
                if acc == target { matched = len; break }
                if acc.count > target.count { break }
            }
            if matched > 0 {
                hits.append(NSRange(location: words[i].location, length: words[i + matched - 1].upperBound - words[i].location))
                i += matched
            } else { i += 1 }
        }
        var out = text as NSString
        for r in hits.reversed() { out = out.replacingCharacters(in: r, with: replacement) as NSString }
        return out as String
    }
}

enum Post {
    static func applyDictionary(_ text: String, _ entries: [DictEntry]) -> String {
        var t = text
        for e in entries {
            guard let rep = e.replacement, !rep.isEmpty, !e.phrase.isEmpty else { continue }
            defer { if Fuzzy.eligible(e) { t = Fuzzy.apply(t, phrase: e.phrase, replacement: rep) } }
            let pat = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: e.phrase) + "(?![\\p{L}\\p{N}_])"
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { continue }
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t),
                                            withTemplate: NSRegularExpression.escapedTemplate(for: rep))
        }
        return t
    }

    static func finalize(_ text: String, before: String, dictionary: [DictEntry]) -> String {
        var t = applyDictionary(text, dictionary)
        if let last = before.last, !last.isWhitespace, !t.isEmpty { t = " " + t }
        return t
    }
}

enum Pipeline {
    static func now() -> Double { Date().timeIntervalSince1970 * 1000 }

    /// Steps 3-7. Returns nil when there is nothing to insert.
    static func run(samples: [Float], ctx: AppContext, llmTimeout: TimeInterval, rawBox: RawBox? = nil) async -> PipelineResult? {
        let dict = UserDictionary.load()
        let vocab = UserDictionary.vocabulary(dict)
        var prompt = ""
        for v in vocab {
            let next = prompt.isEmpty ? v : prompt + ", " + v
            if next.count > 700 { break }  // ~200 tokens
            prompt = next
        }
        let t0 = now()
        var parakeetSegs: [Segment]?
        if Settings.asrEngine == .fast {
            // Never fall through to Whisper in Fast mode: a cold whisper-server start took ~10 s under swap.
            if !(await ParakeetEngine.shared.isReady) { _ = await ParakeetEngine.shared.load() }
            parakeetSegs = await ParakeetEngine.shared.transcribe(samples: samples)
            if parakeetSegs == nil { DebugLog.log("pipeline: parakeet failed -> nil"); return nil }
        }
        let segs: [Segment]
        if let p = parakeetSegs {
            segs = p
        } else {
            guard await WhisperServer.shared.ensureRunning(),
                  let w = await WhisperServer.shared.transcribe(samples: samples, prompt: prompt) else {
                DebugLog.log("pipeline: whisper unavailable/failed -> nil"); return nil
            }
            segs = w
        }
        let t1 = now()
        let raw = SpeechGate.filter(segs, samples: samples)
        DebugLog.log("pipeline: samples=\(samples.count) segs=\(segs.count) rawLen=\(raw.count) asr=\(Int(t1 - t0))ms")
        if raw.isEmpty { DebugLog.log("pipeline: empty after gate -> nil"); return nil }
        rawBox?.set((raw, Int(t1 - t0)))
        let (cleaned, mode) = await Cleanup.clean(raw: raw, vocab: vocab, before: ctx.before,
                                                  bundleId: ctx.bundleId, name: ctx.appName, timeout: llmTimeout)
        let t2 = now()
        DebugLog.log("pipeline: cleanup \(mode.rawValue) \(Int(t2 - t1))ms cancelled=\(Task.isCancelled) len=\(cleaned.count)")
        let final = Post.finalize(cleaned, before: ctx.before, dictionary: dict)
        return PipelineResult(raw: raw, cleaned: cleaned, final: final, asrMs: Int(t1 - t0), llmMs: Int(t2 - t1), mode: mode)
    }
}

enum Headless {
    static func run(_ args: [String]) async -> Int32 {
        func val(_ k: String) -> String? {
            guard let i = args.firstIndex(of: k), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let file = val("--transcribe") else { return 2 }
        // CoreML/E5RT writes diagnostics to stdout; keep the real stdout clean for the result only.
        let realOut = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        if Settings.asrEngine == .fast { await ParakeetEngine.shared.load() }  // test harness: wait for the model
        let bid = val("--bundle-id") ?? ""
        guard let samples = try? Resample.loadFile(URL(fileURLWithPath: file)), !samples.isEmpty else {
            FileHandle.standardError.write(Data("murmur: cannot read \(file)\n".utf8)); return 1
        }
        let ctx = AppContext(bundleId: bid, appName: ContextProbe.name(forBundleId: bid), before: val("--before") ?? "")
        guard let r = await Pipeline.run(samples: samples, ctx: ctx, llmTimeout: 30) else { return 0 }
        _ = r.final.withCString { write(realOut, $0, strlen($0)) }
        _ = write(realOut, "\n", 1)
        FileHandle.standardError.write(Data("[asr \(r.asrMs)ms, llm \(r.llmMs)ms \(r.mode.rawValue)] raw: \(r.raw)\n".utf8))
        return 0
    }
}
