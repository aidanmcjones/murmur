import FluidAudio
import Foundation

/// Parakeet (default: Ultra, moondream's post-trained TDT v3) via FluidAudio / CoreML.
/// On 250 held-out Wispr Flow clips Ultra had 2.8% WER vs WF's ASR, against 6.7% for v2, at the same speed. Produces the same `Segment`s as WhisperServer
/// so `SpeechGate.filter` applies unchanged.
actor ParakeetEngine {
    static let shared = ParakeetEngine()

    private var manager: AsrManager?
    private var layers = 2
    private var loadTask: Task<Bool, Never>?
    private(set) var isReady = false

    // Vocabulary boosting: a CTC keyword spotter re-scores the transcript against the audio (FluidAudio's
    // VocabularyBoostingSession is engine-independent; AsrManager has no built-in hook, so it is applied here).
    private var boosting: VocabularyBoostingSession?
    private var ctcModels: CtcModels?
    private var boostSig = ""
    private var boostTask: Task<Void, Never>?
    /// Test override for the `parakeetBoost` default.
    var boostOverride: Bool?
    /// Off: on the 80 eval clips (8 occurrences of dictionary terms) Ultra already got 7/8 right and boosting got the same 7/8
    /// at identical WER (3.81%), for +23-25 ms p50 latency in both the conservative and the recall setting.
    /// Opt in with `defaults write com.aidanjones.murmur parakeetBoost -bool true`; measure with `--asr-boost-eval <dir>`.
    static let boostDefault = false
    static var boostEnabled: Bool { UserDefaults.standard.object(forKey: "parakeetBoost") as? Bool ?? boostDefault }
    /// Dictation favours precision: a wrong replacement costs more than a miss (FluidAudio #967).
    static var boostThresholds: VocabularyBoostingSession.Thresholds {
        let env = ProcessInfo.processInfo.environment
        if env["MURMUR_PK_BOOST_MODE"] == "recall" { return .default }
        return .init(cbw: Float(env["MURMUR_PK_BOOST_CBW"] ?? "") ?? 0, minSimilarity: Float(env["MURMUR_PK_BOOST_SIM"] ?? "") ?? 0.7)
    }

    /// Plain vocabulary terms plus the targets of learned replacements; emails and long phrases are not spoken terms.
    static func boostTerms(_ entries: [DictEntry]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for e in entries {
            let t = ((e.replacement ?? "").isEmpty ? e.phrase : e.replacement ?? "").trimmingCharacters(in: .whitespaces)
            guard t.count >= 3, t.count <= 40, !t.contains("@"), t.split(separator: " ").count <= 3,
                  (e.replacement ?? "").isEmpty || e.learned == true,
                  seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
        }
        return out
    }

    /// Rebuilds the boosting session in the background when the dictionary's term set changed.
    func refreshBoosting() {
        let terms = Self.boostTerms(UserDictionary.load())
        let sig = terms.joined(separator: "\u{1}")
        if sig == boostSig { return }
        boostSig = sig
        boostTask?.cancel()
        boostTask = Task { await self.buildBoosting(terms, sig) }
    }

    func waitForBoosting() async { await boostTask?.value }

    private func buildBoosting(_ terms: [String], _ sig: String) async {
        guard !terms.isEmpty else { boosting = nil; return }
        do {
            let ctc: CtcModels
            if let c = ctcModels { ctc = c } else { ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m); ctcModels = ctc }
            let ctx = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
            let session = try await VocabularyBoostingSession(vocabulary: ctx, ctcModels: ctc, thresholds: Self.boostThresholds)
            if sig == boostSig { boosting = session }
            Self.log("boosting ready terms=\(terms.count)")
        } catch {
            Self.log("boosting failed: \(error)")
        }
    }

    static let minWordConfidence: Float = {
        if let e = ProcessInfo.processInfo.environment["MURMUR_PK_CONF"], let v = Float(e) { return v }
        return 0
    }()
    static let segmentGap = 0.5
    /// `defaults write com.aidanjones.murmur parakeetVersion v2` to go back.
    static var version: AsrModelVersion {
        switch UserDefaults.standard.string(forKey: "parakeetVersion") ?? "ultra" {
        case "v2": return .v2
        case "v3": return .v3
        default: return .ultra
        }
    }

    private static func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if !FileManager.default.fileExists(atPath: Paths.parakeetLog.path) {
            FileManager.default.createFile(atPath: Paths.parakeetLog.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: Paths.parakeetLog) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        }
    }

    /// Idempotent; concurrent callers share one load. Returns true when ready.
    @discardableResult
    func load() async -> Bool {
        if isReady { return true }
        if let t = loadTask { return await t.value }
        let t = Task { await self.doLoad() }
        loadTask = t
        let ok = await t.value
        if !ok { loadTask = nil }  // allow retry
        return ok
    }

    private func doLoad() async -> Bool {
        let t0 = Date()
        do {
            let models = try await AsrModels.downloadAndLoad(version: Self.version)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            layers = await m.decoderLayerCount
            manager = m
            isReady = true
            if Self.boostEnabled || boostOverride != nil { refreshBoosting() }
            Self.log(String(format: "loaded \(Self.version) in %.2fs", Date().timeIntervalSince(t0)))
            return true
        } catch {
            Self.log("load failed after \(String(format: "%.2f", Date().timeIntervalSince(t0)))s: \(error)")
            return false
        }
    }

    func transcribe(samples: [Float]) async -> [Segment]? {
        guard let m = manager else { return nil }
        // The model needs a minimum amount of audio; pad very short clips with silence.
        let minSamples = 16000
        let input = samples.count < minSamples ? samples + [Float](repeating: 0, count: minSamples - samples.count) : samples
        var st = TdtDecoderState.make(decoderLayers: layers)
        guard let r = try? await m.transcribe(input, decoderState: &st) else { return nil }
        var rescored: VocabularyRescorer.RescoreOutput?
        if boostOverride ?? Self.boostEnabled {
            refreshBoosting()
            if let b = boosting, let tm = r.tokenTimings, !tm.isEmpty {
                rescored = await b.rescore(text: r.text, tokenTimings: tm, audioSamples: input)
            }
        }
        guard let timings = r.tokenTimings, !timings.isEmpty else {
            let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [Segment(text: t, start: 0, end: Double(samples.count) / 16000)]
        }
        // Group tokens into words: a token starting with a space (or the SentencePiece marker) starts a word.
        struct Word { var text: String; var start: Double; var end: Double; var conf: Float; var n: Int }
        var words: [Word] = []
        var pendingStart = false
        for t in timings {
            // A bare "▁" token marks the *next* token as a word start (v3-family vocab splits "▁" from digits);
            // dropping it glued words together ("the11-hour").
            let startsWord = pendingStart || t.token.hasPrefix(" ") || t.token.hasPrefix("\u{2581}")
            let piece = t.token.replacingOccurrences(of: "\u{2581}", with: " ").trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { pendingStart = pendingStart || startsWord; continue }
            pendingStart = false
            if startsWord || words.isEmpty {
                words.append(Word(text: piece, start: t.startTime, end: t.endTime, conf: t.confidence, n: 1))
            } else {
                words[words.count - 1].text += piece
                words[words.count - 1].end = t.endTime
                words[words.count - 1].conf += t.confidence
                words[words.count - 1].n += 1
            }
        }
        words = words.filter { $0.conf / Float($0.n) >= Self.minWordConfidence }
        // Off by default: on 250 held-out clips this deleted the speaker's own sentence-final words
        // ("for me. You say" → "for say") far more often than it removed background speech.
        if UserDefaults.standard.bool(forKey: "pkWordGate") {
            words = Self.dropBackgroundWords(words.map { ($0, $0.start, $0.end) }, samples: samples).map(\.0)
        }
        var segs: [Segment] = []
        var cur: [Word] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            segs.append(Segment(text: cur.map(\.text).joined(separator: " "), start: f.start, end: l.end))
            cur = []
        }
        for w in words {
            if let l = cur.last, w.start - l.end >= Self.segmentGap { flush() }
            cur.append(w)
        }
        flush()
        var out = segs.map { Segment(text: Self.joinSpelledAcronyms($0.text), start: $0.start, end: $0.end) }
        if let rs = rescored, rs.wasModified {
            for rep in rs.replacements where rep.shouldReplace {
                guard let new = rep.replacementWord, !rep.originalWord.isEmpty else { continue }
                for i in out.indices {
                    if let r = out[i].text.range(of: rep.originalWord, options: .caseInsensitive) {
                        out[i].text.replaceSubrange(r, with: new)
                        break
                    }
                }
            }
        }
        return out
    }

    /// Headless: transcribes every clip of `<dir>/set.jsonl` with boosting off and on, one JSON line per clip.
    static func boostEval(dir: String) async -> Int32 {
        let realOut = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let eng = ParakeetEngine.shared
        guard await eng.load() else { return 1 }
        await eng.setBoostOverride(true)
        await eng.refreshBoosting()
        await eng.waitForBoosting()
        guard let text = try? String(contentsOfFile: dir + "/set.jsonl", encoding: .utf8) else { return 1 }
        var first = true
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8), let row = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let id = row["id"] as? String,
                  let samples = try? Resample.loadFile(URL(fileURLWithPath: "\(dir)/\(id).wav")), !samples.isEmpty else { continue }
            if first { first = false; _ = await eng.transcribe(samples: samples) }  // warm-up
            var rec: [String: Any] = ["id": id]
            for on in [false, true] {
                await eng.setBoostOverride(on)
                let t0 = Date()
                let segs = await eng.transcribe(samples: samples) ?? []
                rec[on ? "on" : "off"] = segs.map { $0.text }.joined(separator: " ")
                rec[on ? "onMs" : "offMs"] = Int(Date().timeIntervalSince(t0) * 1000)
            }
            if let o = try? JSONSerialization.data(withJSONObject: rec), let str = String(data: o, encoding: .utf8) {
                _ = (str + "\n").withCString { write(realOut, $0, strlen($0)) }
            }
        }
        return 0
    }

    func setBoostOverride(_ v: Bool?) { boostOverride = v }

    /// Parakeet transcribes background voices (TV, people nearby) far more readily than Whisper and
    /// interleaves them with the speaker's words, so segment-level gating misses them. Drop words that are
    /// much quieter than the speaker's typical word level, but only in runs of 2+ so a single softly
    /// spoken word of the user's survives.
    static func dropBackgroundWords<W>(_ words: [(W, Double, Double)], samples: [Float]) -> [(W, Double, Double)] {
        guard words.count >= 4 else { return words }
        let levels: [Float] = words.map { _, s, e in
            let a = max(0, min(samples.count, Int((s - 0.03) * 16000)))
            let b = max(a, min(samples.count, Int((e + 0.03) * 16000)))
            return SpeechGate.rms(samples[a..<b])
        }
        let ref = levels.sorted()[Int(Double(levels.count - 1) * 0.85)]
        let low = levels.map { $0 < 0.35 * ref }
        return words.indices.filter { i in
            !(low[i] && ((i > 0 && low[i - 1]) || (i + 1 < low.count && low[i + 1])))
        }.map { words[$0] }
    }

    /// "C L I" → "CLI", "A D D R" → "ADDR" (Parakeet spells out letter sequences).
    static func joinSpelledAcronyms(_ s: String) -> String {
        s.replacingOccurrences(of: #"(?<=\b[A-Z]) (?=[A-Z]\b)"#, with: "", options: .regularExpression)
    }
}
