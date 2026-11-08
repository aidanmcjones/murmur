import Foundation

/// Murmur-owned llama.cpp server for cleanup. Weights are mlock'ed so macOS can't page them
/// out under memory pressure (the reason ollama stalled 5-10 s per request on this machine).
final class LocalLLM {
    static let shared = LocalLLM()
    static let port = 8179
    let base = URL(string: "http://127.0.0.1:\(LocalLLM.port)")!
    private let lock = NSLock()
    private var _process: Process?
    private var _inflight: Task<Bool, Never>?

    static func modelPath() -> String? {
        let fm = FileManager.default
        var cands: [String] = []
        if let e = ProcessInfo.processInfo.environment["MURMUR_LLM"] { cands.append(e) }
        cands.append(Paths.support.appendingPathComponent("models/qwen3-4b-instruct-2507-q4_K_M.gguf").path)
        cands.append(NSString("~/Tools/murmur/models/qwen3-4b-instruct-2507-q4_K_M.gguf").expandingTildeInPath)
        return cands.first { fm.fileExists(atPath: $0) }
    }

    private func isUp() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 1
        guard let (_, r) = try? await URLSession.shared.data(for: req) else { return false }
        return (r as? HTTPURLResponse)?.statusCode == 200
    }

    @discardableResult
    func ensureRunning() async -> Bool {
        let (t, owner) = claim()
        let ok = await t.value
        if owner { clearInflight() }
        return ok
    }

    private func claim() -> (Task<Bool, Never>, Bool) {
        lock.lock(); defer { lock.unlock() }
        if let t = _inflight { return (t, false) }
        let t = Task { await self.startIfNeeded() }
        _inflight = t
        return (t, true)
    }
    private func clearInflight() { lock.lock(); _inflight = nil; lock.unlock() }
    private func current() -> Process? { lock.lock(); defer { lock.unlock() }; return _process }
    private func setProcess(_ p: Process) { lock.lock(); _process = p; lock.unlock() }

    private func startIfNeeded() async -> Bool {
        if await isUp() { return true }
        if let cur = current(), cur.isRunning { return await waitUp(cur) }
        guard let model = Self.modelPath(),
              let exe = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { FileHandle.standardError.write(Data("murmur: llama-server or cleanup model not found\n".utf8)); return false }
        let p = Process()
        // Same parent-death wrapper as whisper-server: the server exits when Murmur does.
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"P=$PPID; "$0" "$@" & W=$!; trap 'kill $W 2>/dev/null; exit' TERM INT; while kill -0 $P 2>/dev/null && kill -0 $W 2>/dev/null; do sleep 1; done; kill $W 2>/dev/null"#,
                       exe, "-m", model, "--host", "127.0.0.1", "--port", "\(Self.port)", "-c", "4096",
                       "-ngl", "99", "--load-mode", "mlock", "--jinja", "-np", "1"]
        let log = Paths.support.appendingPathComponent("llama-server.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        do { try p.run() } catch { return false }
        setProcess(p)
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
}
