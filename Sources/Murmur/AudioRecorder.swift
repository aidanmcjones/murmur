import AVFoundation

enum Resample {
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    static func to16kMono(_ converter: AVAudioConverter, _ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = 16000 / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    static func loadFile(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return [] }
        try f.read(into: buf)
        guard let conv = AVAudioConverter(from: f.processingFormat, to: target) else { return [] }
        return to16kMono(conv, buf)
    }
}

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var running = false
    var onLevel: ((Float) -> Void)?
    /// Fired on main when the max duration is hit; the owner should run its normal stop path.
    var onLimit: (() -> Void)?
    static let maxSeconds: TimeInterval = 360
    private var generation = 0

    func start() -> Bool {
        guard !running else { return true }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, let conv = AVAudioConverter(from: fmt, to: Resample.target) else { return false }
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            let out = Resample.to16kMono(conv, buf)
            if out.isEmpty { return }
            self.lock.lock(); self.samples.append(contentsOf: out); self.lock.unlock()
            let level = SpeechGate.rms(out[...])
            DispatchQueue.main.async { self.onLevel?(level) }
        }
        do { try engine.start() } catch {
            input.removeTap(onBus: 0); return false
        }
        running = true
        generation += 1
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxSeconds) { [weak self] in
            guard let self, self.running, self.generation == g else { return }
            self.onLimit?()
        }
        return true
    }

    func stop() -> [Float] {
        guard running else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}
