//! Application controller: settings, the dictation session state machine, history, startup registration.

use crate::hotkey::{self, Cmd};
use crate::pipeline::{self, Ctx};
use crate::ui::{self, UiCmd};
use crate::uia::LCmd;
use crate::util::*;
use crate::{audio::Recorder, win32};
use murmur_core::config::{Config, HistoryEntry, PttKey};
use murmur_core::dictionary;
use murmur_core::vocab::pair_key;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{OnceLock, RwLock};
use std::time::{Duration, Instant};

fn cfg_lock() -> &'static RwLock<Config> {
    static C: OnceLock<RwLock<Config>> = OnceLock::new();
    C.get_or_init(|| {
        let c = std::fs::read_to_string(config_path()).map(|s| Config::parse(&s)).unwrap_or_default();
        RwLock::new(c)
    })
}

pub fn config() -> Config {
    cfg_lock().read().unwrap().clone()
}

pub fn update_config(f: impl FnOnce(&mut Config)) {
    let mut g = cfg_lock().write().unwrap();
    f(&mut g);
    let _ = std::fs::write(config_path(), g.to_json());
}

pub fn set_ptt_key(k: PttKey) {
    update_config(|c| c.ptt_key = k.clone());
    hotkey::set_key(k);
}

pub fn set_learn(on: bool) {
    update_config(|c| c.learn_vocab = on);
}

pub fn set_llm(on: bool) {
    update_config(|c| c.provider = if on { "local".into() } else { "none".into() });
}

const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";

fn reg(args: &[&str]) -> bool {
    use std::os::windows::process::CommandExt;
    std::process::Command::new("reg.exe")
        .args(args)
        .creation_flags(0x0800_0000)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub fn startup_enabled() -> bool {
    reg(&["query", RUN_KEY, "/v", "Murmur"])
}

pub fn set_startup(on: bool) {
    if on {
        let exe = std::env::current_exe().map(|p| format!("\"{}\"", p.display())).unwrap_or_default();
        reg(&["add", RUN_KEY, "/v", "Murmur", "/t", "REG_SZ", "/d", &exe, "/f"]);
    } else {
        reg(&["delete", RUN_KEY, "/v", "Murmur", "/f"]);
    }
}

pub fn open_dictionary() {
    let p = dictionary_path();
    if !p.exists() {
        save_dictionary(&[]);
    }
    let _ = std::process::Command::new("notepad.exe").arg(p).spawn();
}

pub fn open_data_dir() {
    let _ = std::process::Command::new("explorer.exe").arg(app_dir()).spawn();
}

pub fn log_vocab_event(mode: &str, heard: &str, wanted: &str, app: &str) {
    append_history(&HistoryEntry {
        ts: iso_now(),
        raw: heard.into(),
        cleaned: wanted.into(),
        app: app.into(),
        asr_ms: 0,
        llm_ms: 0,
        total_ms: 0,
        spec: None,
        mode: Some(mode.into()),
    });
}

/// Button on the suggestion pop-up: 0 = Add, 1 = Dismiss, 2 = Don't suggest.
pub fn on_suggestion(heard: &str, wanted: &str, action: usize) {
    match action {
        0 => {
            let mut d = load_dictionary();
            let n = dictionary::add_learned(&mut d, Some(heard), wanted);
            if n > 0 {
                save_dictionary(&d);
            }
            log(&format!("learn: accepted {heard} -> {wanted} (+{n})"));
            log_vocab_event("vocab-add", heard, wanted, "");
        }
        1 => {
            log(&format!("learn: dismissed {heard} -> {wanted}"));
            log_vocab_event("vocab-dismiss", heard, wanted, "");
        }
        _ => {
            update_config(|c| {
                c.rejected_pairs.insert(pair_key(heard, wanted));
            });
            log(&format!("learn: rejected {heard} -> {wanted}"));
            log_vocab_event("vocab-reject", heard, wanted, "");
        }
    }
}

// ---- dictation sessions --------------------------------------------------------------------------

struct Session {
    exe: String,
    probe: Receiver<String>,
    started: Instant,
}

fn finish(s: Session, rec: &Recorder, learner: &Sender<LCmd>) {
    let samples = rec.stop();
    let held = s.started.elapsed();
    log(&format!("finish: samples={} held={}ms", samples.len(), held.as_millis()));
    if samples.len() < 4800 {
        ui::post(UiCmd::Hide);
        return;
    }
    if samples.iter().all(|v| *v == 0.0) {
        ui::post(UiCmd::Toast("The microphone returned silence. Check Windows Settings > Privacy > Microphone.".into()));
        return;
    }
    ui::post(UiCmd::Transcribing);
    let before = s.probe.recv_timeout(Duration::from_millis(150)).unwrap_or_default();
    let ctx = Ctx { app_name: win32::friendly_name(&s.exe), exe: s.exe.clone(), before };
    let cfg = config();
    let dict = load_dictionary();
    let t0 = Instant::now();
    let budget = Duration::from_millis((murmur_core::cleanup::RELEASE_BUDGET_SECS * 1000.0) as u64);
    match pipeline::run(&samples, &ctx, &cfg, &dict, budget) {
        Ok(Some(r)) => {
            ui::post(UiCmd::Hide);
            let text = r.final_text.clone();
            let pasted = text.trim().to_string();
            let exe = s.exe.clone();
            let ok = crate::clip::paste(&text, || {
                let _ = learner.send(LCmd::Pasted { text: pasted.clone(), exe: exe.clone() });
            });
            log(&format!("done: mode={} paste={ok} total={}ms", r.mode, t0.elapsed().as_millis()));
            append_history(&HistoryEntry {
                ts: iso_now(),
                raw: r.raw,
                cleaned: r.cleaned,
                app: s.exe,
                asr_ms: r.asr_ms,
                llm_ms: r.llm_ms,
                total_ms: t0.elapsed().as_millis() as i64,
                spec: None,
                mode: Some(r.mode.into()),
            });
        }
        Ok(None) => ui::post(UiCmd::Hide),
        Err(e) => {
            log(&format!("pipeline error: {e}"));
            ui::post(UiCmd::Toast(e));
        }
    }
}

pub fn run_controller(rx: Receiver<Cmd>, rec: Recorder, learner: Sender<LCmd>) {
    let mut session: Option<Session> = None;
    while let Ok(c) = rx.recv() {
        match c {
            Cmd::Start => {
                let _ = learner.send(LCmd::Stop);
                let (ptx, prx) = channel();
                let _ = learner.send(LCmd::Probe(ptx));
                let exe = win32::foreground_exe();
                match rec.start() {
                    Ok(()) => {
                        session = Some(Session { exe, probe: prx, started: Instant::now() });
                        ui::post(UiCmd::Listening);
                    }
                    Err(e) => {
                        log(&format!("start failed: {e}"));
                        ui::post(UiCmd::Toast(e));
                        hotkey::reset();
                    }
                }
            }
            Cmd::Cancel => {
                if session.take().is_some() {
                    let _ = rec.stop();
                    ui::post(UiCmd::Hide);
                }
            }
            Cmd::Stop => {
                if let Some(s) = session.take() {
                    finish(s, &rec, &learner);
                }
            }
        }
    }
}
