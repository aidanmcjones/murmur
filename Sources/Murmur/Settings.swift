import Foundation
import Security
import SQLite3

enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var dictionary: URL { support.appendingPathComponent("dictionary.json") }
    static var history: URL { support.appendingPathComponent("history.jsonl") }
    static var parakeetLog: URL { support.appendingPathComponent("parakeet.log") }
    static var whisperLog: URL { support.appendingPathComponent("whisper-server.log") }
}

enum Res {
    static let bundle: Bundle = {
        if let u = Bundle.main.resourceURL?.appendingPathComponent("Murmur_Murmur.bundle"),
           let b = Bundle(url: u) { return b }
        return Bundle.module
    }()
    static func text(_ name: String, _ ext: String) -> String {
        guard let u = bundle.url(forResource: name, withExtension: ext),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return "" }
        return s
    }
}

enum Provider: String, CaseIterable {
    case local, ollama, anthropic, none
}

enum AsrEngine: String {
    case fast, accurate
}

/// Keycodes + device-dependent flag bits for modifier keys, so left/right are distinguishable.
enum KeyInfo {
    static let modifierBits: [Int: UInt64] = [
        61: 0x40, 54: 0x10, 62: 0x2000, 60: 0x04,
        58: 0x20, 55: 0x08, 59: 0x01, 56: 0x02,
    ]
    static let names: [Int: String] = [
        61: "Right Option", 54: "Right Command", 62: "Right Control", 60: "Right Shift",
        58: "Left Option", 55: "Left Command", 59: "Left Control", 56: "Left Shift",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    static func name(_ code: Int) -> String { names[code] ?? "Key \(code)" }
}

enum Settings {
    static var provider: Provider {
        get { Provider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .local }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "provider") }
    }
    static var asrEngine: AsrEngine {
        get { AsrEngine(rawValue: UserDefaults.standard.string(forKey: "asrEngine") ?? "") ?? .fast }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "asrEngine") }
    }
    static var useFn: Bool {
        get { UserDefaults.standard.object(forKey: "useFn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useFn") }
    }
    static var learnVocab: Bool {
        get { UserDefaults.standard.object(forKey: "learnVocab") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "learnVocab") }
    }
    /// "heard|wanted" pairs (lowercased) the user asked never to be offered again.
    static var rejectedPairs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "rejectedVocabPairs") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "rejectedVocabPairs") }
    }
    /// Optional extra push-to-talk key (virtual keycode); nil = none.
    static var customKey: Int? {
        get { UserDefaults.standard.object(forKey: "customKeyCode") as? Int }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: "customKeyCode") }
            else { UserDefaults.standard.removeObject(forKey: "customKeyCode") }
        }
    }
    /// Old single-choice `hotkey` setting -> custom key.
    static func migrateHotkey() {
        let d = UserDefaults.standard
        guard let old = d.string(forKey: "hotkey") else { return }
        if old == "rightOption", customKey == nil { customKey = 61 }
        d.removeObject(forKey: "hotkey")
    }
}

enum Keychain {
    private static let service = "com.aidanjones.murmur"
    private static let account = "anthropic-api-key"

    static func get() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct DictEntry: Codable, Equatable {
    var phrase: String
    var replacement: String?
}

enum UserDictionary {
    static func load() -> [DictEntry] {
        guard let d = try? Data(contentsOf: Paths.dictionary),
              let e = try? JSONDecoder().decode([DictEntry].self, from: d) else { return [] }
        return e
    }

    static func save(_ entries: [DictEntry]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let d = try? enc.encode(entries) { try? d.write(to: Paths.dictionary) }
    }

    /// Adds the deterministic fix (heard -> wanted) and the plain vocabulary term; returns entries added.
    @discardableResult
    static func addLearned(heard: String, wanted: String) -> Int {
        var entries = load()
        var added = 0
        let hasFix = entries.contains { $0.phrase.lowercased() == heard.lowercased() && !($0.replacement ?? "").isEmpty }
        if !hasFix { entries.append(DictEntry(phrase: heard, replacement: wanted)); added += 1 }
        let hasTerm = entries.contains { $0.phrase.lowercased() == wanted.lowercased() && ($0.replacement ?? "").isEmpty }
        if !hasTerm { entries.append(DictEntry(phrase: wanted)); added += 1 }
        if added > 0 { save(entries) }
        return added
    }

    static func ensureFile() {
        if !FileManager.default.fileExists(atPath: Paths.dictionary.path) { save([]) }
    }

    /// Terms handed to Whisper and the cleanup LLM: the spelling we want to see.
    static func vocabulary(_ entries: [DictEntry]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for e in entries {
            // Snippets/replacements are applied after cleanup; only plain terms bias ASR + LLM.
            guard e.replacement?.isEmpty ?? true else { continue }
            let t = e.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, seen.insert(t.lowercased()).inserted { out.append(t) }
        }
        return out
    }

    /// Returns number of entries added, or nil if the Wispr database could not be read.
    static func importWispr() -> Int? {
        let path = NSString("~/Library/Application Support/Wispr Flow/flow.sqlite").expandingTildeInPath
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?immutable=1", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT phrase, replacement FROM Dictionary WHERE isDeleted=0",
                                 -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var existing = load()
        var keys = Set(existing.map { $0.phrase.lowercased() })
        var added = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let p = sqlite3_column_text(stmt, 0) else { continue }
            let phrase = String(cString: p)
            var rep: String?
            if let r = sqlite3_column_text(stmt, 1) {
                let s = String(cString: r)
                if !s.isEmpty { rep = s }
            }
            if phrase.isEmpty || !keys.insert(phrase.lowercased()).inserted { continue }
            existing.append(DictEntry(phrase: phrase, replacement: rep))
            added += 1
        }
        save(existing)
        return added
    }
}

struct HistoryEntry: Codable {
    var ts: String
    var raw: String
    var cleaned: String
    var app: String
    var asrMs: Int
    var llmMs: Int
    var totalMs: Int
    var spec: Bool? = nil
    var mode: String? = nil
    enum CodingKeys: String, CodingKey {
        case ts, raw, cleaned, app, spec, mode
        case asrMs = "asr_ms", llmMs = "llm_ms", totalMs = "total_ms"
    }
}

enum History {
    static func append(_ e: HistoryEntry) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard var line = try? enc.encode(e) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: Paths.history) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: Paths.history)
        }
    }

    static func recent(_ n: Int = 20) -> [HistoryEntry] {
        guard let s = try? String(contentsOf: Paths.history, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        let all = s.split(separator: "\n").compactMap { try? dec.decode(HistoryEntry.self, from: Data($0.utf8)) }
        // Vocabulary-learning events share the file but are not transcripts.
        return all.filter { !($0.mode ?? "").hasPrefix("vocab-") }.suffix(n).reversed()
    }
}
