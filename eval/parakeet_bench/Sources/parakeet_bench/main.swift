import FluidAudio
import Foundation
import Darwin

func peakRSSMB() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_maxrss) / 1_048_576  // bytes on macOS
}
func readWav(_ url: URL) throws -> [Float] {
    let d = try Data(contentsOf: url)
    let body = d.dropFirst(44)  // 16 kHz mono 16-bit PCM, canonical header
    return body.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
}

let args = CommandLine.arguments
let versions: [(String, AsrModelVersion)] = args.count > 1 ? args[1...].map { ($0, $0 == "v2" ? .v2 : .v3) } : [("v2", .v2), ("v3", .v3)]
let dataDir = URL(fileURLWithPath: NSString("~/Tools/murmur/eval/data").expandingTildeInPath)
let outDir = URL(fileURLWithPath: NSString("~/Tools/murmur/eval/out").expandingTildeInPath)
let ids: [String] = try String(contentsOf: dataDir.appendingPathComponent("set.jsonl"), encoding: .utf8)
    .split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["id"] as? String
    }
print("clips: \(ids.count)")
let clips = try ids.map { try readWav(dataDir.appendingPathComponent("\($0).wav")) }

for (name, ver) in versions {
    let t0 = Date()
    let models = try await AsrModels.downloadAndLoad(version: ver)
    let mgr = AsrManager(config: .default)
    try await mgr.loadModels(models)
    let loadS = Date().timeIntervalSince(t0)
    let layers = await mgr.decoderLayerCount
    for i in 0..<2 {
        var st = TdtDecoderState.make(decoderLayers: layers)
        _ = try await mgr.transcribe(clips[i], decoderState: &st)
    }
    var rows: [[String: Any]] = []
    var sampleTimings = ""
    for (i, s) in clips.enumerated() {
        var st = TdtDecoderState.make(decoderLayers: layers)
        let a = DispatchTime.now().uptimeNanoseconds
        let r = try await mgr.transcribe(s, decoderState: &st)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - a) / 1e6
        if i == 0, let tt = r.tokenTimings { sampleTimings = tt.prefix(5).map { "\($0.token)[\($0.startTime)-\($0.endTime) c=\($0.confidence)]" }.joined(separator: " ") }
        rows.append(["id": ids[i], "hyp": r.text, "ms": ms, "secs": Double(s.count) / 16000])
    }
    let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
    try data.write(to: outDir.appendingPathComponent("parakeet_\(name).json"))
    print("\(name): load_s=\(String(format: "%.2f", loadS)) peak_rss_mb=\(String(format: "%.0f", peakRSSMB()))")
    print("timings sample: \(sampleTimings)")
}
