//! Paths, logging, time formatting.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// %APPDATA%\Murmur (override with MURMUR_APPDATA): dictionary.json, history.jsonl, config.json, debug.log.
pub fn app_dir() -> PathBuf {
    let p = std::env::var_os("MURMUR_APPDATA")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("APPDATA").map(|a| PathBuf::from(a).join("Murmur")))
        .unwrap_or_else(|| PathBuf::from("."));
    let _ = std::fs::create_dir_all(&p);
    p
}

pub fn exe_dir() -> PathBuf {
    std::env::current_exe().ok().and_then(|e| e.parent().map(|p| p.to_path_buf())).unwrap_or_else(|| PathBuf::from("."))
}

/// Model directory: MURMUR_MODELS_DIR, else <exe dir>\models.
pub fn models_dir() -> PathBuf {
    std::env::var_os("MURMUR_MODELS_DIR").map(PathBuf::from).unwrap_or_else(|| exe_dir().join("models"))
}

pub fn parakeet_dir() -> PathBuf {
    models_dir().join("sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8")
}

pub fn gguf_path() -> PathBuf {
    models_dir().join("qwen3-4b-instruct-2507-q4_K_M.gguf")
}

pub fn llama_server_path() -> PathBuf {
    exe_dir().join("llama-server.exe")
}

pub fn dictionary_path() -> PathBuf {
    app_dir().join("dictionary.json")
}

pub fn history_path() -> PathBuf {
    app_dir().join("history.jsonl")
}

pub fn config_path() -> PathBuf {
    app_dir().join("config.json")
}

static LOG: Mutex<Option<std::fs::File>> = Mutex::new(None);

pub fn hms_ms() -> String {
    let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let secs = d.as_secs() % 86_400;
    format!("{:02}:{:02}:{:02}.{:03}", secs / 3600, (secs / 60) % 60, secs % 60, d.subsec_millis())
}

/// Always-on event log (UTC timestamps), rotated at 2 MB.
pub fn log(msg: &str) {
    let mut g = match LOG.lock() {
        Ok(g) => g,
        Err(e) => e.into_inner(),
    };
    if g.is_none() {
        let path = app_dir().join("debug.log");
        if std::fs::metadata(&path).map(|m| m.len() > 2_000_000).unwrap_or(false) {
            let _ = std::fs::remove_file(&path);
        }
        *g = OpenOptions::new().create(true).append(true).open(path).ok();
    }
    if let Some(f) = g.as_mut() {
        let _ = writeln!(f, "{}Z {}", hms_ms(), msg);
    }
    if std::env::var_os("MURMUR_LOG_STDERR").is_some() {
        eprintln!("{}Z {}", hms_ms(), msg);
    }
}

/// ISO-8601 UTC timestamp for history entries.
pub fn iso_now() -> String {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // civil_from_days (Howard Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, (rem / 60) % 60, rem % 60)
}

pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

pub fn load_dictionary() -> Vec<murmur_core::dictionary::DictEntry> {
    std::fs::read_to_string(dictionary_path()).map(|s| murmur_core::dictionary::parse_dictionary(&s)).unwrap_or_default()
}

pub fn save_dictionary(e: &[murmur_core::dictionary::DictEntry]) {
    let _ = std::fs::write(dictionary_path(), murmur_core::dictionary::dictionary_to_json(e));
}

pub fn append_history(e: &murmur_core::config::HistoryEntry) {
    if let Ok(line) = serde_json::to_string(e) {
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(history_path()) {
            let _ = writeln!(f, "{line}");
        }
    }
}
