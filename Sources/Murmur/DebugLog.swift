import Foundation

/// Cheap always-on event log: one timestamped line per event.
enum DebugLog {
    private static let q = DispatchQueue(label: "murmur.debuglog")
    private static let fh: FileHandle? = {
        let dir = NSString("~/Library/Application Support/Murmur").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/debug.log"
        if let a = try? FileManager.default.attributesOfItem(atPath: path), (a[.size] as? Int ?? 0) > 2_000_000 {
            try? FileManager.default.removeItem(atPath: path)
        }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let h = FileHandle(forWritingAtPath: path)
        _ = try? h?.seekToEnd()
        return h
    }()

    static func log(_ s: String) {
        let t = Date().timeIntervalSince1970
        q.async {
            let ms = Int(t * 1000) % 1000
            var tm = tm(); var tt = time_t(t)
            localtime_r(&tt, &tm)
            let line = String(format: "%02d:%02d:%02d.%03d %@\n", tm.tm_hour, tm.tm_min, tm.tm_sec, ms, s)
            try? fh?.write(contentsOf: Data(line.utf8))
        }
    }
}
