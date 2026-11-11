#![cfg_attr(windows, windows_subsystem = "windows")]
//! Murmur for Windows: hold a key, speak, release; cleaned text is pasted where you are typing.

mod asr;
mod audio;
mod llm;
mod pipeline;
mod util;
mod wav;

#[cfg(windows)]
mod app;
#[cfg(windows)]
mod clip;
#[cfg(windows)]
mod hotkey;
#[cfg(windows)]
mod ui;
#[cfg(windows)]
mod uia;
#[cfg(windows)]
mod win32;

use std::path::PathBuf;

fn arg_val(args: &[String], key: &str) -> Option<String> {
    args.iter().position(|a| a == key).and_then(|i| args.get(i + 1)).cloned()
}

#[cfg(windows)]
fn attach_console() {
    use windows::core::w;
    use windows::Win32::Foundation::GENERIC_WRITE;
    use windows::Win32::Storage::FileSystem::*;
    use windows::Win32::System::Console::*;
    unsafe {
        let _ = AttachConsole(ATTACH_PARENT_PROCESS);
        for which in [STD_OUTPUT_HANDLE, STD_ERROR_HANDLE] {
            let bad = GetStdHandle(which).map(|h| h.is_invalid() || h.0.is_null()).unwrap_or(true);
            if bad {
                if let Ok(h) = CreateFileW(w!("CONOUT$"), GENERIC_WRITE.0, FILE_SHARE_WRITE, None, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, None) {
                    let _ = SetStdHandle(which, h);
                }
            }
        }
    }
}

/// `murmur --transcribe file.wav`: headless ASR + cleanup, prints the text that would be pasted.
fn transcribe(args: &[String]) -> i32 {
    util::log(&format!("transcribe: args={args:?}"));
    let Some(file) = arg_val(args, "--transcribe") else { return 2 };
    let samples = match wav::load_16k(&PathBuf::from(&file)) {
        Ok(s) if !s.is_empty() => s,
        Ok(_) => {
            eprintln!("murmur: {file} has no audio");
            return 1;
        }
        Err(e) => {
            eprintln!("murmur: cannot read {e}");
            return 1;
        }
    };
    let mut cfg = murmur_core::config::Config::default();
    if args.iter().any(|a| a == "--no-llm") {
        cfg.provider = "none".into();
    }
    let exe = arg_val(args, "--app").unwrap_or_default();
    let ctx = pipeline::Ctx { app_name: exe.trim_end_matches(".exe").to_string(), exe, before: arg_val(args, "--before").unwrap_or_default() };
    let dict = util::load_dictionary();
    util::log(&format!("transcribe: {} samples loaded", samples.len()));
    match pipeline::run(&samples, &ctx, &cfg, &dict, std::time::Duration::from_secs(30)) {
        Ok(Some(r)) => {
            println!("{}", r.final_text);
            eprintln!("[asr {}ms, llm {}ms {}] raw: {}", r.asr_ms, r.llm_ms, r.mode, r.raw);
            0
        }
        Ok(None) => {
            eprintln!("murmur: no speech recognized");
            0
        }
        Err(e) => {
            eprintln!("murmur: {e}");
            1
        }
    }
}

/// `murmur --llm-selftest`: starts llama-server, runs one cleanup request, checks the guarded result.
fn llm_selftest() -> i32 {
    use murmur_core::cleanup;
    if !llm::available() {
        eprintln!("murmur: llama-server.exe or the cleanup model is missing");
        return 1;
    }
    let t0 = std::time::Instant::now();
    if !llm::ensure_running(std::time::Duration::from_secs(240)) {
        eprintln!("murmur: llama-server did not become ready");
        return 1;
    }
    eprintln!("server ready after {} ms", t0.elapsed().as_millis());
    // The server we reached must be our own freshly launched child (random port, child alive), not a stranger.
    match llm::child_pid() {
        Some(pid) => eprintln!("llama-server is our child, pid {pid}, port {}", llm::port()),
        None => {
            eprintln!("murmur: ready server is not our own child process");
            return 1;
        }
    }
    let raw = "um so can you uh send me the file by friday";
    let sys = cleanup::system_prompt("notepad.exe", "Notepad", &[]);
    let msgs = cleanup::messages(&sys, &cleanup::wrap(raw));
    let t1 = std::time::Instant::now();
    let reply = llm::complete(&msgs, 256, std::time::Duration::from_secs(120));
    eprintln!("completion took {} ms: {reply:?}", t1.elapsed().as_millis());
    let out = reply.and_then(|r| cleanup::finish_llm_output(raw, &r));
    llm::shutdown();
    match out {
        Some(t) => {
            println!("{t}");
            0
        }
        None => 1,
    }
}

#[cfg(windows)]
fn run_app(args: &[String]) -> i32 {
    use windows::core::w;
    use windows::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS};
    use windows::Win32::System::Threading::CreateMutexW;
    use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};

    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let _ = CreateMutexW(None, true, w!("Local\\MurmurWindowsSingleton"));
        if GetLastError() == ERROR_ALREADY_EXISTS {
            return 0; // already running
        }
    }
    util::log(&format!("murmur {} starting", env!("CARGO_PKG_VERSION")));
    if let Some(k) = arg_val(args, "--ptt").and_then(|s| murmur_core::config::PttKey::parse(&s)) {
        app::update_config(|c| c.ptt_key = k);
    }
    let test_wav = arg_val(args, "--test-audio").map(PathBuf::from);
    let rec = match audio::Recorder::new(test_wav.as_deref()) {
        Ok(r) => r,
        Err(e) => {
            util::log(&format!("audio init failed: {e}"));
            return 1;
        }
    };
    asr::start_loading();
    if app::config().provider != "none" && llm::available() {
        llm::start_in_background();
    }
    if let Err(e) = ui::init() {
        util::log(&format!("ui init failed: {e}"));
        return 1;
    }
    let learner = uia::spawn();
    let (tx, rx) = std::sync::mpsc::channel();
    if let Err(e) = hotkey::install(app::config().ptt_key, tx, learner.clone()) {
        util::log(&e);
        ui::post(ui::UiCmd::Toast(e));
    }
    let l2 = learner.clone();
    std::thread::spawn(move || app::run_controller(rx, rec, l2));
    util::log(&format!("ready; push-to-talk key: {}", app::config().ptt_key.label()));
    ui::message_loop();
    llm::shutdown();
    util::log("quit");
    0
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--version") {
        #[cfg(windows)]
        attach_console();
        println!("murmur {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    if args.iter().any(|a| a == "--llm-selftest") {
        #[cfg(windows)]
        attach_console();
        std::process::exit(llm_selftest());
    }
    if args.iter().any(|a| a == "--transcribe") {
        #[cfg(windows)]
        attach_console();
        std::process::exit(transcribe(&args));
    }
    #[cfg(windows)]
    {
        if args.iter().any(|a| a == "--uia-read-focused") {
            attach_console();
            std::thread::sleep(std::time::Duration::from_millis(arg_val(&args, "--delay-ms").and_then(|s| s.parse().ok()).unwrap_or(0)));
            match uia::read_focused_text() {
                Some(t) => println!("{t}"),
                None => {
                    eprintln!("murmur: focused element has no readable text");
                    std::process::exit(1);
                }
            }
            return;
        }
        std::process::exit(run_app(&args));
    }
    #[cfg(not(windows))]
    {
        eprintln!("murmur-win only runs on Windows (use the macOS app in this repository on a Mac).");
        std::process::exit(2);
    }
}
