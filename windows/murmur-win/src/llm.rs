//! Murmur-owned llama.cpp server (llama-server.exe, CPU build) for LLM cleanup.

use crate::util::{app_dir, gguf_path, llama_server_path, log};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub const PORT: u16 = 8179;

static CHILD: Mutex<Option<Child>> = Mutex::new(None);
static STARTING: Mutex<bool> = Mutex::new(false);

fn base() -> String {
    format!("http://127.0.0.1:{PORT}")
}

pub fn available() -> bool {
    llama_server_path().exists() && gguf_path().exists()
}

fn agent(timeout: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new().timeout(timeout).build()
}

/// llama-server answers /health with 200 only once the model is loaded.
pub fn is_ready() -> bool {
    agent(Duration::from_millis(400)).get(&format!("{}/health", base())).call().map(|r| r.status() == 200).unwrap_or(false)
}

#[cfg(windows)]
fn attach_to_job(child: &Child) {
    use std::os::windows::io::AsRawHandle;
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::System::JobObjects::*;
    unsafe {
        if let Ok(job) = CreateJobObjectW(None, None) {
            let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let _ = SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const std::ffi::c_void,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            );
            let _ = AssignProcessToJobObject(job, HANDLE(child.as_raw_handle()));
            // The job handle is intentionally leaked: when Murmur exits (or crashes) Windows closes it and
            // kills llama-server with it.
        }
    }
}

fn spawn() -> bool {
    let mut guard = CHILD.lock().unwrap();
    if let Some(c) = guard.as_mut() {
        if matches!(c.try_wait(), Ok(None)) {
            return true;
        }
    }
    if !available() {
        log("llm: llama-server.exe or the cleanup model is missing; deterministic cleanup only");
        return false;
    }
    let logf = std::fs::OpenOptions::new().create(true).append(true).open(app_dir().join("llama-server.log")).ok();
    let mut cmd = Command::new(llama_server_path());
    cmd.args(["-m", &gguf_path().to_string_lossy(), "--host", "127.0.0.1", "--port", &PORT.to_string(), "-c", "4096", "--jinja", "-np", "1"]);
    cmd.stdin(Stdio::null());
    match logf {
        Some(f) => {
            if let Ok(f2) = f.try_clone() {
                cmd.stderr(Stdio::from(f2));
            }
            cmd.stdout(Stdio::from(f));
        }
        None => {
            cmd.stdout(Stdio::null()).stderr(Stdio::null());
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    match cmd.spawn() {
        Ok(c) => {
            #[cfg(windows)]
            attach_to_job(&c);
            log("llm: llama-server started");
            *guard = Some(c);
            true
        }
        Err(e) => {
            log(&format!("llm: cannot start llama-server: {e}"));
            false
        }
    }
}

/// Starts the server if needed and waits (up to `max`) until the model is loaded.
pub fn ensure_running(max: Duration) -> bool {
    if is_ready() {
        return true;
    }
    {
        let mut s = STARTING.lock().unwrap();
        if *s {
            return false;
        }
        *s = true;
    }
    let ok = (|| {
        if !spawn() {
            return false;
        }
        let t0 = Instant::now();
        while t0.elapsed() < max {
            if is_ready() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        false
    })();
    *STARTING.lock().unwrap() = false;
    ok
}

/// Kicks off a background start (never blocks a dictation on model load).
pub fn start_in_background() {
    std::thread::spawn(|| {
        let t0 = Instant::now();
        let ok = ensure_running(Duration::from_secs(180));
        log(&format!("llm: background start ok={ok} after {} ms", t0.elapsed().as_millis()));
        if ok {
            // Prewarm the prompt cache with the shared system prompt + few-shot (first CPU prompt eval is slow).
            let sys = murmur_core::cleanup::system_prompt("", "", &[]);
            let msgs = murmur_core::cleanup::messages(&sys, &murmur_core::cleanup::wrap("ok"));
            let t1 = Instant::now();
            let _ = complete(&msgs, 1, Duration::from_secs(120));
            log(&format!("llm: prewarm took {} ms", t1.elapsed().as_millis()));
        }
    });
}

pub fn shutdown() {
    if let Some(mut c) = CHILD.lock().unwrap().take() {
        let _ = c.kill();
    }
}

/// One chat completion; None on any error or when `timeout` passes.
pub fn complete(messages: &[(String, String)], max_tokens: u32, timeout: Duration) -> Option<String> {
    let msgs: Vec<serde_json::Value> =
        messages.iter().map(|(r, c)| serde_json::json!({"role": r, "content": c})).collect();
    let body = serde_json::json!({"messages": msgs, "temperature": 0, "max_tokens": max_tokens, "cache_prompt": true});
    let resp = agent(timeout).post(&format!("{}/v1/chat/completions", base())).send_json(body).ok()?;
    let v: serde_json::Value = resp.into_json().ok()?;
    v["choices"][0]["message"]["content"].as_str().map(|s| s.to_string())
}
