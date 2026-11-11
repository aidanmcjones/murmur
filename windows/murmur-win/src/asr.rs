//! Speech recognition: sherpa-onnx with NVIDIA Parakeet TDT 0.6B v2 (int8 ONNX, CPU).

use crate::util::{log, parakeet_dir};
use sherpa_onnx::{OfflineRecognizer, OfflineRecognizerConfig, OfflineTransducerModelConfig};
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

enum State {
    NotStarted,
    Loading,
    Ready(OfflineRecognizer),
    Failed(String),
}

struct Shared {
    state: Mutex<State>,
    cv: Condvar,
}

fn shared() -> &'static Shared {
    static S: OnceLock<Shared> = OnceLock::new();
    S.get_or_init(|| Shared { state: Mutex::new(State::NotStarted), cv: Condvar::new() })
}

fn build() -> Result<OfflineRecognizer, String> {
    let dir = parakeet_dir();
    let f = |n: &str| dir.join(n).to_string_lossy().to_string();
    for n in ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"] {
        if !dir.join(n).exists() {
            return Err(format!("speech model file missing: {} (run scripts\\setup.ps1)", dir.join(n).display()));
        }
    }
    let mut cfg = OfflineRecognizerConfig::default();
    cfg.model_config.transducer = OfflineTransducerModelConfig {
        encoder: Some(f("encoder.int8.onnx")),
        decoder: Some(f("decoder.int8.onnx")),
        joiner: Some(f("joiner.int8.onnx")),
    };
    cfg.model_config.tokens = Some(f("tokens.txt"));
    cfg.model_config.model_type = Some("nemo_transducer".into());
    cfg.model_config.provider = Some("cpu".into());
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    cfg.model_config.num_threads = cores.clamp(2, 6) as i32;
    cfg.decoding_method = Some("greedy_search".into());
    OfflineRecognizer::create(&cfg).ok_or_else(|| "sherpa-onnx could not load the Parakeet model".to_string())
}

/// Loads the model on a background thread (idempotent).
pub fn start_loading() {
    let s = shared();
    {
        let mut st = s.state.lock().unwrap();
        if !matches!(*st, State::NotStarted) {
            return;
        }
        *st = State::Loading;
    }
    std::thread::spawn(|| {
        let t0 = Instant::now();
        let r = build();
        let s = shared();
        let mut st = s.state.lock().unwrap();
        match r {
            Ok(rec) => {
                log(&format!("asr: parakeet loaded in {} ms", t0.elapsed().as_millis()));
                *st = State::Ready(rec);
            }
            Err(e) => {
                log(&format!("asr: load failed: {e}"));
                *st = State::Failed(e);
            }
        }
        s.cv.notify_all();
    });
}

pub fn is_ready() -> bool {
    matches!(*shared().state.lock().unwrap(), State::Ready(_))
}

/// Blocks until the model is loaded (or failed / timed out). Returns Err with a user-facing reason.
pub fn wait_ready(timeout: Duration) -> Result<(), String> {
    start_loading();
    let s = shared();
    let deadline = Instant::now() + timeout;
    let mut st = s.state.lock().unwrap();
    loop {
        match &*st {
            State::Ready(_) => return Ok(()),
            State::Failed(e) => return Err(e.clone()),
            _ => {}
        }
        let now = Instant::now();
        if now >= deadline {
            return Err("speech model is still loading".into());
        }
        st = s.cv.wait_timeout(st, deadline - now).unwrap().0;
    }
}

/// Transcribes 16 kHz mono samples. Parakeet returns punctuated, capitalized text.
pub fn transcribe(samples: &[f32]) -> Option<String> {
    let st = shared().state.lock().unwrap();
    let rec = match &*st {
        State::Ready(r) => r,
        _ => return None,
    };
    let mut padded = samples.to_vec();
    // Parakeet wants a little trailing silence, and very short clips need padding.
    padded.extend(std::iter::repeat(0.0).take(8000));
    if padded.len() < 16_000 {
        padded.resize(16_000, 0.0);
    }
    let stream = rec.create_stream();
    stream.accept_waveform(16_000, &padded);
    rec.decode(&stream);
    stream.get_result().map(|r| r.text.trim().to_string())
}
