import Foundation

struct PipelineResult {
    var raw: String
    var cleaned: String
    var final: String
    var asrMs: Int
    var llmMs: Int
}

enum Post {
    static func applyDictionary(_ text: String, _ entries: [DictEntry]) -> String {
        var t = text
        for e in entries {
            guard let rep = e.replacement, !rep.isEmpty, !e.phrase.isEmpty else { continue }
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
    static func run(samples: [Float], ctx: AppContext) async -> PipelineResult? {
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
        if Settings.asrEngine == .fast, await ParakeetEngine.shared.isReady {
            parakeetSegs = await ParakeetEngine.shared.transcribe(samples: samples)
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
        let cleaned = await Cleanup.clean(raw: raw, vocab: vocab, before: ctx.before,
                                          bundleId: ctx.bundleId, name: ctx.appName)
        let t2 = now()
        DebugLog.log("pipeline: cleanup \(Int(t2 - t1))ms cancelled=\(Task.isCancelled) len=\(cleaned.count)")
        let final = Post.finalize(cleaned, before: ctx.before, dictionary: dict)
        return PipelineResult(raw: raw, cleaned: cleaned, final: final, asrMs: Int(t1 - t0), llmMs: Int(t2 - t1))
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
        guard let r = await Pipeline.run(samples: samples, ctx: ctx) else { return 0 }
        _ = r.final.withCString { write(realOut, $0, strlen($0)) }
        _ = write(realOut, "\n", 1)
        FileHandle.standardError.write(Data("[asr \(r.asrMs)ms, llm \(r.llmMs)ms] raw: \(r.raw)\n".utf8))
        return 0
    }
}
