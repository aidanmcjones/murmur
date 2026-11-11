import Foundation

enum Cleanup {
    static let messaging: Set<String> = ["com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.telegram.desktop", "com.apple.iChat"]
    static let email: Set<String> = ["com.microsoft.Outlook", "com.apple.mail", "com.microsoft.Word",
        "com.apple.iWork.Pages", "com.apple.Notes"]
    static let ai: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "com.anthropic.claudefordesktop", "com.openai.codex", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.warp.Warp-Stable", "dev.warp.Warp"]

    static func styleKey(bundleId: String, name: String) -> String {
        if messaging.contains(bundleId) { return "messaging" }
        if email.contains(bundleId) { return "email" }
        if ai.contains(bundleId) { return "ai" }
        switch name {
        case "Messages", "Slack", "Discord", "WhatsApp", "Telegram": return "messaging"
        case "Outlook", "Microsoft Outlook", "Mail", "Word", "Microsoft Word", "Pages", "Notes": return "email"
        case "Terminal", "iTerm2", "Ghostty", "Claude", "Codex", "Code", "Visual Studio Code", "Cursor", "Warp": return "ai"
        default: return "default"
        }
    }

    static func systemPrompt(bundleId: String, name: String, vocab: [String]) -> String {
        let styles = (try? JSONSerialization.jsonObject(with: Data(Res.text("styles", "json").utf8))) as? [String: String] ?? [:]
        let style = styles[styleKey(bundleId: bundleId, name: name)] ?? styles["default"] ?? ""
        return Res.text("cleanup_prompt", "txt")
            .replacingOccurrences(of: "{{APP}}", with: name.isEmpty ? "the active app" : name)
            .replacingOccurrences(of: "{{STYLE}}", with: style)
            .replacingOccurrences(of: "{{VOCAB}}", with: vocab.joined(separator: ", "))
    }

    static func wrap(_ raw: String) -> String { "<<<\n\(raw)\n>>>" }

    /// Few-shot (transcript, cleaned) pairs shared with the eval harness.
    static let fewShot: [[String: String]] = {
        let pairs = (try? JSONSerialization.jsonObject(with: Data(Res.text("fewshot", "json").utf8))) as? [[String]] ?? []
        return pairs.flatMap { p in [["role": "user", "content": wrap(p[0])], ["role": "assistant", "content": p[1]]] }
    }()

    static var ollamaModel: String {
        UserDefaults.standard.string(forKey: "ollamaModel") ?? "qwen3:4b-instruct-2507-q4_K_M"
    }

    // MARK: drift guard (mirrors eval/fmt_eval.py guard())
    private static let numWords = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                                   "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]
    static func normWords(_ s: String) -> [String] {
        let lowered = s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let cleaned = lowered.unicodeScalars.map { c -> Character in
            (CharacterSet.alphanumerics.contains(c) || c == "'" || c == "%" || c == "_") ? Character(c) : " "
        }
        return String(cleaned).split(separator: " ").map { numWords[String($0)] ?? String($0) }
    }
    static func _unusedWordErrors(_ ref: [String], _ hyp: [String]) -> Int {
        if ref.isEmpty { return hyp.count }
        var d = Array(0...hyp.count)
        for i in 1...ref.count {
            var prev = d[0]; d[0] = i
            if hyp.isEmpty { continue }
            for j in 1...hyp.count {
                let cur = min(d[j] + 1, d[j - 1] + 1, prev + (ref[i - 1] == hyp[j - 1] ? 0 : 1))
                prev = d[j]; d[j] = cur
            }
        }
        return d[hyp.count]
    }
    /// Reject LLM output that drifted (answered the prompt, echoed context, hallucinated).
    static func lcs(_ a: [String], _ b: [String]) -> Int {
        var d = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var prev = 0
            for j in 0..<b.count {
                let t = d[j + 1]
                d[j + 1] = x == b[j] ? prev + 1 : max(d[j + 1], d[j])
                prev = t
            }
        }
        return d[b.count]
    }
    /// Deletions (fillers, self-corrections) are fine; new words mean the model rewrote or answered.
    /// Strict: the cleanup may delete fillers and corrected phrases and fix punctuation, but not reword,
    /// censor, or answer. Thresholds chosen on the held-out Wispr Flow eval (eval/cleanup_eval.py).
    static let profanity = try! NSRegularExpression(pattern: #"(?i)fuck|shit|damn|bitch|\bass\b"#)
    static func guardOutput(raw: String, hyp: String) -> String {
        let r = normWords(raw), h = normWords(hyp)
        let novel = Double(h.count - lcs(r, h)) / Double(max(h.count, 1))
        let hw = hyp.split(whereSeparator: \.isWhitespace).count, rw = raw.split(whereSeparator: \.isWhitespace).count
        func count(_ re: NSRegularExpression, _ s: String) -> Int { re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) }
        let ok = novel <= 0.08 && Double(h.count) >= 0.6 * Double(r.count) && Double(hw) <= 1.5 * Double(rw) + 6
            && count(profanity, hyp) >= count(profanity, raw)
            && hyp.range(of: #"\w-\s?['’ ]?t\b"#, options: .regularExpression) == nil
        return ok ? hyp : raw
    }

    private static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 4
        return URLSession(configuration: c)
    }

    private static func ollamaBody(system: String, user: String, numPredict: Int?, fewShot: Bool = true) -> Data {
        var opts: [String: Any] = ["temperature": 0, "num_ctx": 4096]
        if let n = numPredict { opts["num_predict"] = n }
        let body: [String: Any] = [
            "model": ollamaModel,
            "messages": [["role": "system", "content": system]] + (fewShot ? Cleanup.fewShot : []) + [["role": "user", "content": user]],
            "stream": false, "think": false, "keep_alive": "30m", "options": opts,
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    static func messages(system: String, user: String) -> [[String: Any]] {
        [["role": "system", "content": system]] + Cleanup.fewShot + [["role": "user", "content": user]]
    }

    private static func localRequest(system: String, user: String, maxTokens: Int) -> URLRequest {
        var req = URLRequest(url: LocalLLM.shared.base.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["messages": [["role": "system", "content": system]] + Cleanup.fewShot + [["role": "user", "content": user]],
                                   "temperature": 0, "max_tokens": maxTokens, "cache_prompt": true]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Deterministic cleanup used when the transcript needs no rewriting, and as the fallback when the
    /// LLM misses its deadline: strip fillers and stutters, tidy spacing, capitalize the first letter.
    static func basicClean(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: #"(?i)(^|\s)(um+|uh+|erm+|hmm+)[,.…]*(?=\s|$)"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)\b(\w+)(?: \1\b)+"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([,.?!])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^[,.\s]+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let f = t.first, f.isLowercase { t = f.uppercased() + t.dropFirst() }
        return t.isEmpty ? raw : t
    }

    /// True when the transcript has something deterministic cleanup can't fix: self-corrections, fillers,
    /// spoken punctuation/commands, or repeated words. On 250 held-out Wispr Flow clips this fires on ~7%;
    /// on the rest the local LLM was neutral-to-harmful for fidelity (it reworded, censored, or answered
    /// the dictation) and only added latency.
    static let needsLLMPattern: NSRegularExpression = try! NSRegularExpression(pattern:
        #"(?i)\b(um+|uh+|actually|no wait|wait no|scratch that|i mean|or rather|comma|period|question mark|"# +
        #"new ?line|new paragraph|colon|bullet|number one|firstly|secondly)\b|\b(\w+) \2\b"#)
    static var gateEnabled: Bool { !UserDefaults.standard.bool(forKey: "alwaysLLM") }
    static func needsLLM(_ raw: String) -> Bool {
        if !gateEnabled { return true }
        return needsLLMPattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
    }

    /// Small-model output artifacts seen in history ("don-'t").
    static func fixArtifacts(_ s: String) -> String {
        s.replacingOccurrences(of: #"(\p{L})-['’](\p{L})"#, with: "$1'$2", options: .regularExpression)
    }

    static func prewarm(bundleId: String, name: String) async {
        if Settings.provider == .local {
            guard await LocalLLM.shared.ensureRunning() else { return }
            let sys = systemPrompt(bundleId: bundleId, name: name, vocab: UserDictionary.vocabulary(UserDictionary.load()))
            _ = await LocalLLM.shared.complete(messages: messages(system: sys, user: wrap("ok")), maxTokens: 1, timeout: 3)
            return
        }
        guard Settings.provider == .ollama else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = ollamaBody(system: systemPrompt(bundleId: bundleId, name: name, vocab: UserDictionary.vocabulary(UserDictionary.load())), user: wrap("ok"), numPredict: 1)
        _ = try? await session().data(for: req)
    }

    enum Mode: String { case llm, det, timeout }

    /// Post-release LLM budget. Short dictations keep 0.9 s (unchanged latency); past ~40 words (220 chars) it grows
    /// with the local Qwen3-4B server's cost: measured 1.45 ms/char warm (57 -> 1099 chars: 122 -> 1633 ms, M5 Pro),
    /// ~1.9 ms/char in real use under load (928 chars: 1565-1761 ms), so 2.0 ms/char; capped at 3.5 s (~1500 chars).
    static let shortBudget: TimeInterval = 0.9
    static let shortChars = 220
    static let msPerChar = 2.0
    static let maxBudget: TimeInterval = 3.5
    static func releaseBudget(chars: Int) -> TimeInterval {
        min(maxBudget, shortBudget + Double(max(0, chars - shortChars)) * msPerChar / 1000)
    }

    /// Returns cleaned text and how it was produced. Falls back to deterministic cleanup when the transcript
    /// doesn't need the LLM, or when the LLM fails or misses `timeout`.
    static func clean(raw: String, vocab: [String], before: String, bundleId: String, name: String,
                      timeout: TimeInterval) async -> (String, Mode) {
        if Settings.provider == .none { return (raw, .det) }
        if !needsLLM(raw) { return (basicClean(raw), .det) }
        let system = systemPrompt(bundleId: bundleId, name: name, vocab: vocab)
        let user = wrap(raw)
        var out: String?
        switch Settings.provider {
        case .none:
            return (raw, .det)
        case .local:
            // Never block a dictation on model load: if the server isn't ready, start it and fall back.
            guard await LocalLLM.shared.isReady() else {
                Task { await LocalLLM.shared.ensureRunning() }
                return (basicClean(raw), .timeout)
            }
            out = await LocalLLM.shared.complete(messages: messages(system: system, user: user), maxTokens: 1024, timeout: timeout)
        case .ollama:
            var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = ollamaBody(system: system, user: user, numPredict: nil)
            req.timeoutInterval = timeout
            if let (d, _) = try? await session().data(for: req),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let m = o["message"] as? [String: Any] { out = m["content"] as? String }
        case .anthropic:
            guard let key = Keychain.get() else { return (basicClean(raw), .det) }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let body: [String: Any] = ["model": "claude-haiku-5-5", "max_tokens": 1024, "temperature": 0,
                "system": system, "messages": Cleanup.fewShot + [["role": "user", "content": user]]]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.timeoutInterval = timeout
            if let (d, _) = try? await session().data(for: req),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let c = o["content"] as? [[String: Any]] { out = c.first?["text"] as? String }
        }
        guard var text = out else { return (basicClean(raw), .timeout) }
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
        text = text.replacingOccurrences(of: "<<<", with: "").replacingOccurrences(of: ">>>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = fixArtifacts(text)
        if text.isEmpty { return (basicClean(raw), .timeout) }
        let g = guardOutput(raw: raw, hyp: text)
        return (g == raw ? basicClean(raw) : g, .llm)
    }
}
