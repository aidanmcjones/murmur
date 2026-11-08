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
    static func guardOutput(raw: String, hyp: String) -> String {
        let r = normWords(raw), h = normWords(hyp)
        let novel = Double(h.count - lcs(r, h)) / Double(max(h.count, 1))
        let hw = hyp.split(whereSeparator: \.isWhitespace).count, rw = raw.split(whereSeparator: \.isWhitespace).count
        return (novel <= 0.2 && Double(h.count) >= 0.3 * Double(r.count) && Double(hw) <= 1.5 * Double(rw) + 6) ? hyp : raw
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

    private static func localRequest(system: String, user: String, maxTokens: Int) -> URLRequest {
        var req = URLRequest(url: LocalLLM.shared.base.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["messages": [["role": "system", "content": system]] + Cleanup.fewShot + [["role": "user", "content": user]],
                                   "temperature": 0, "max_tokens": maxTokens, "cache_prompt": true]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Fallback when the LLM is unavailable: at least strip obvious fillers.
    static func basicClean(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: #"(?i)\b(um+|uh+|erm|hmm+)\b[,.…]*\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let f = t.first, f.isLowercase { t = f.uppercased() + t.dropFirst() }
        return t.isEmpty ? raw : t
    }

    static func prewarm(bundleId: String, name: String) async {
        if Settings.provider == .local {
            guard await LocalLLM.shared.ensureRunning() else { return }
            let sys = systemPrompt(bundleId: bundleId, name: name, vocab: UserDictionary.vocabulary(UserDictionary.load()))
            _ = try? await session().data(for: localRequest(system: sys, user: wrap("ok"), maxTokens: 1))
            return
        }
        guard Settings.provider == .ollama else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = ollamaBody(system: systemPrompt(bundleId: bundleId, name: name, vocab: UserDictionary.vocabulary(UserDictionary.load())), user: wrap("ok"), numPredict: 1)
        _ = try? await session().data(for: req)
    }

    /// Returns cleaned text, or the raw transcript on any failure/timeout.
    static func clean(raw: String, vocab: [String], before: String, bundleId: String, name: String) async -> String {
        let system = systemPrompt(bundleId: bundleId, name: name, vocab: vocab)
        let user = wrap(raw)
        var out: String?
        switch Settings.provider {
        case .none:
            return raw
        case .local:
            // Never block a dictation on model load: if the server isn't ready, start it and fall back.
            guard await LocalLLM.shared.isReady() else {
                Task { await LocalLLM.shared.ensureRunning() }
                return basicClean(raw)
            }
            if let (d, _) = try? await session().data(for: localRequest(system: system, user: user, maxTokens: 1024)),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let ch = o["choices"] as? [[String: Any]], let m = ch.first?["message"] as? [String: Any] { out = m["content"] as? String }
        case .ollama:
            var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = ollamaBody(system: system, user: user, numPredict: nil)
            if let (d, _) = try? await session().data(for: req),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let m = o["message"] as? [String: Any] { out = m["content"] as? String }
        case .anthropic:
            guard let key = Keychain.get() else { return raw }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let body: [String: Any] = ["model": "claude-haiku-5-5", "max_tokens": 1024, "temperature": 0,
                "system": system, "messages": Cleanup.fewShot + [["role": "user", "content": user]]]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            if let (d, _) = try? await session().data(for: req),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let c = o["content"] as? [[String: Any]] { out = c.first?["text"] as? String }
        }
        guard var text = out else { return basicClean(raw) }
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
        text = text.replacingOccurrences(of: "<<<", with: "").replacingOccurrences(of: ">>>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? raw : guardOutput(raw: raw, hyp: text)
    }
}
