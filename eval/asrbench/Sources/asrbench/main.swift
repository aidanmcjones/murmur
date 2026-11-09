import FluidAudio
import Foundation

// Usage: asrbench <dataDir> <outDir> <vocab.json|-> engine...
// engines: v2 ultra unified, optional "+voc" suffix for CTC vocabulary boosting.
func readWav(_ url: URL) throws -> [Float] {
    let d = try Data(contentsOf: url)
    // Find the "data" chunk instead of assuming a 44-byte header.
    var i = 12
    while i + 8 <= d.count {
        let id = String(decoding: d[i..<i+4], as: UTF8.self)
        let sz = Int(d[i+4]) | Int(d[i+5]) << 8 | Int(d[i+6]) << 16 | Int(d[i+7]) << 24
        if id == "data" {
            let body = d[(i+8)..<min(d.count, i+8+sz)]
            return body.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
        }
        i += 8 + sz + (sz & 1)
    }
    return []
}
func ms(_ a: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - a) / 1e6 }

let args = CommandLine.arguments
let dataDir = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[2])
let vocabPath = args[3]
let engines = Array(args[4...])
let ids: [String] = try String(contentsOf: dataDir.appendingPathComponent("set.jsonl"), encoding: .utf8)
    .split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["id"] as? String }
let clips = try ids.map { try readWav(dataDir.appendingPathComponent("\($0).wav")) }
print("clips: \(clips.count)"); fflush(stdout)

var vocab: CustomVocabularyContext?
if vocabPath != "-" {
    let arr = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: vocabPath))) as! [[String: Any]]
    vocab = CustomVocabularyContext(terms: arr.map { CustomVocabularyTerm(text: $0["text"] as! String, aliases: $0["aliases"] as? [String]) })
}
var ctc: CtcModels?

for eng in engines {
    let useVoc = eng.hasSuffix("+voc")
    let base = useVoc ? String(eng.dropLast(4)) : eng
    let t0 = DispatchTime.now().uptimeNanoseconds
    var session: VocabularyBoostingSession?
    if useVoc, let v = vocab {
        if ctc == nil { ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m) }
        session = try await VocabularyBoostingSession(vocabulary: v, ctcModels: ctc!)
    }
    var run: ([Float]) async throws -> String
    if base == "unified" {
        let m = UnifiedAsrManager()
        try await m.loadModels()
        if useVoc, let v = vocab { try await m.configureVocabularyBoosting(vocabulary: v, ctcModels: ctc!) }
        run = { s in try await m.transcribe(s) }
    } else {
        let ver: AsrModelVersion = base == "v2" ? .v2 : base == "ultra" ? .ultra : base == "bark3clean" ? .bark3Clean : .v3
        let models = try await AsrModels.downloadAndLoad(version: ver)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        let layers = await m.decoderLayerCount
        let sess = session
        run = { s in
            let input = s.count < 16000 ? s + [Float](repeating: 0, count: 16000 - s.count) : s
            var st = TdtDecoderState.make(decoderLayers: layers)
            let r = try await m.transcribe(input, decoderState: &st)
            if let sess, let o = await sess.rescore(text: r.text, tokenTimings: r.tokenTimings ?? [], audioSamples: input) { return o.text }
            return r.text
        }
    }
    let loadMs = ms(t0)
    for i in 0..<2 { _ = try? await run(clips[i]) }
    var rows: [[String: Any]] = []
    for (i, s) in clips.enumerated() {
        let a = DispatchTime.now().uptimeNanoseconds
        let text = (try? await run(s)) ?? ""
        rows.append(["id": ids[i], "hyp": text, "ms": ms(a), "secs": Double(s.count) / 16000])
    }
    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]).write(to: outDir.appendingPathComponent("asr_\(eng).json"))
    let lat = rows.map { $0["ms"] as! Double }.sorted()
    print("\(eng): load_ms=\(Int(loadMs)) p50=\(Int(lat[lat.count/2]))ms p90=\(Int(lat[Int(Double(lat.count)*0.9)]))ms"); fflush(stdout)
}
