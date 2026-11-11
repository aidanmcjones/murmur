import Foundation

struct Segment {
    var text: String
    var start: Double  // seconds
    var end: Double
}

final class WhisperServer {
    static let shared = WhisperServer()
    private let base = URL(string: "http://127.0.0.1:8178")!
    private let lock = NSLock()
    private var _process: Process?
    private var process: Process? {
        get { lock.lock(); defer { lock.unlock() }; return _process }
        set { lock.lock(); defer { lock.unlock() }; _process = newValue }
    }

    static func modelPath() -> String? {
        let fm = FileManager.default
        var cands: [String] = []
        if let e = ProcessInfo.processInfo.environment["MURMUR_MODEL"] { cands.append(e) }
        cands.append(Paths.support.appendingPathComponent("models/ggml-large-v3-turbo.bin").path)
        cands.append(NSString("~/Tools/murmur/models/ggml-large-v3-turbo.bin").expandingTildeInPath)
        return cands.first { fm.fileExists(atPath: $0) }
    }

    private func isUp() async -> Bool {
        var req = URLRequest(url: base)
        req.timeoutInterval = 1
        do {
            let (_, r) = try await URLSession.shared.data(for: req)
            return r is HTTPURLResponse
        } catch { return false }
    }

    private var inflight: Task<Bool, Never>?

    private func claimInflight() -> (Task<Bool, Never>, owner: Bool) {
        lock.lock(); defer { lock.unlock() }
        if let t = inflight { return (t, false) }
        let t = Task { await self.startIfNeeded() }
        inflight = t
        return (t, true)
    }

    private func clearInflight() {
        lock.lock(); defer { lock.unlock() }
        inflight = nil
    }

    @discardableResult
    func ensureRunning() async -> Bool {
        let (t, owner) = claimInflight()
        let ok = await t.value
        if owner { clearInflight() }
        return ok
    }

    private func startIfNeeded() async -> Bool {
        if await isUp() { return true }
        if let cur = process, cur.isRunning { return await waitUp(cur) }
        guard let model = Self.modelPath(), let exe = Paths.binary("whisper-server") else {
            FileHandle.standardError.write(Data("murmur: whisper model or whisper-server not found\n".utf8)); return false
        }
        let p = Process()
        // sh wrapper: the server dies when murmur does (even on SIGKILL) or when sh is terminated.
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"P=$PPID; "$0" "$@" & W=$!; trap 'kill $W 2>/dev/null; exit' TERM INT; while kill -0 $P 2>/dev/null && kill -0 $W 2>/dev/null; do sleep 1; done; kill $W 2>/dev/null"#,
                       exe, "-m", model, "--host", "127.0.0.1", "--port", "8178", "-t", "8"]
        if !FileManager.default.fileExists(atPath: Paths.whisperLog.path) {
            FileManager.default.createFile(atPath: Paths.whisperLog.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: Paths.whisperLog) {
            p.standardOutput = h; p.standardError = h
        }
        do { try p.run() } catch {
            FileHandle.standardError.write(Data("murmur: cannot start whisper-server: \(error)\n".utf8)); return false
        }
        process = p
        return await waitUp(p)
    }

    private func waitUp(_ p: Process) async -> Bool {
        for _ in 0..<120 {
            if await isUp() { return true }
            if !p.isRunning { return false }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if let p = _process, p.isRunning { p.terminate() }
        _process = nil
    }

    static func wav(from samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let dataLen = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataLen)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataLen)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            u16(UInt16(bitPattern: v))
        }
        return d
    }

    func transcribe(samples: [Float], prompt: String) async -> [Segment]? {
        let boundary = "murmur-\(UUID().uuidString)"
        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(Self.wav(from: samples))
        body.append(Data("\r\n".utf8))
        field("response_format", "verbose_json")
        field("temperature", "0")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: base.appendingPathComponent("inference"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let segs = obj["segments"] as? [[String: Any]] else {
            let t = (obj["text"] as? String) ?? ""
            return [Segment(text: t, start: 0, end: Double(samples.count) / 16000)]
        }
        // verbose_json start/end are in seconds (verified against whisper-server output).
        return segs.map {
            Segment(text: ($0["text"] as? String) ?? "",
                    start: ($0["start"] as? Double) ?? 0,
                    end: ($0["end"] as? Double) ?? 0)
        }
    }
}

enum SpeechGate {
    static func rms(_ s: ArraySlice<Float>) -> Float {
        guard !s.isEmpty else { return 0 }
        var acc: Float = 0
        for v in s { acc += v * v }
        return (acc / Float(s.count)).squareRoot()
    }

    static let hallucinations: Set<String> = [
        "thank you", "thank you.", "thanks for watching", "thanks for watching!", "you", "thank you for watching",
        "thank you for watching.", "thank you for watching!", "bye", "bye.",
    ]

    /// Returns the cleaned raw transcript, or "" when nothing should be inserted.
    static func filter(_ segments: [Segment], samples: [Float]) -> String {
        var segs = segments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let overall = rms(samples[...])
        if segs.count >= 2, UserDefaults.standard.object(forKey: "segGate") as? Bool ?? true {
            let levels = segs.map { s -> Float in
                let a = max(0, min(samples.count, Int(s.start * 16000)))
                let b = max(a, min(samples.count, Int(s.end * 16000)))
                return rms(samples[a..<b])
            }
            let loudest = levels.max() ?? 0
            segs = zip(segs, levels).filter { $0.1 >= 0.4 * loudest }.map { $0.0 }
        }
        var text = segs.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
        // Whisper labels non-speech as *Music*, [BLANK_AUDIO], (sighs) etc. — never dictation.
        text = text.replacingOccurrences(of: #"\*[^*\n]{1,40}\*|\[[^\]\n]{1,40}\]|♪+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if overall < 0.01, hallucinations.contains(text.lowercased()) { return "" }
        return text
    }
}
