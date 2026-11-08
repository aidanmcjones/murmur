import FluidAudio
import Foundation

/// Parakeet TDT v2 (English) via FluidAudio / CoreML. Produces the same `Segment`s as WhisperServer
/// so `SpeechGate.filter` applies unchanged.
actor ParakeetEngine {
    static let shared = ParakeetEngine()

    private var manager: AsrManager?
    private var layers = 2
    private var loadTask: Task<Bool, Never>?
    private(set) var isReady = false

    static let minWordConfidence: Float = {
        if let e = ProcessInfo.processInfo.environment["MURMUR_PK_CONF"], let v = Float(e) { return v }
        return 0
    }()
    static let segmentGap = 0.5

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
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            layers = await m.decoderLayerCount
            manager = m
            isReady = true
            Self.log(String(format: "loaded v2 in %.2fs", Date().timeIntervalSince(t0)))
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
        guard let timings = r.tokenTimings, !timings.isEmpty else {
            let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [Segment(text: t, start: 0, end: Double(samples.count) / 16000)]
        }
        // Group tokens into words: a token starting with a space (or the SentencePiece marker) starts a word.
        struct Word { var text: String; var start: Double; var end: Double; var conf: Float; var n: Int }
        var words: [Word] = []
        for t in timings {
            let startsWord = t.token.hasPrefix(" ") || t.token.hasPrefix("\u{2581}")
            let piece = t.token.replacingOccurrences(of: "\u{2581}", with: " ").trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
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
        words = Self.dropBackgroundWords(words.map { ($0, $0.start, $0.end) }, samples: samples).map(\.0)
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
        return segs.map { Segment(text: Self.joinSpelledAcronyms($0.text), start: $0.start, end: $0.end) }
    }

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
