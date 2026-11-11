//! ASR -> speech gate -> cleanup (deterministic, or gated LLM with a deadline) -> dictionary.

use crate::{asr, llm, util::log};
use murmur_core::cleanup;
use murmur_core::config::Config;
use murmur_core::dictionary::{self, DictEntry};
use std::time::{Duration, Instant};

#[derive(Clone, Debug, Default)]
pub struct Ctx {
    /// Process image name of the focused app, e.g. "notepad.exe".
    pub exe: String,
    pub app_name: String,
    /// Text before the caret in the focused field (for the leading-space rule).
    pub before: String,
}

#[derive(Clone, Debug)]
pub struct PipelineResult {
    pub raw: String,
    pub cleaned: String,
    pub final_text: String,
    pub asr_ms: i64,
    pub llm_ms: i64,
    pub mode: &'static str,
}

fn clean(raw: &str, vocab: &[String], ctx: &Ctx, cfg: &Config, timeout: Duration) -> (String, &'static str) {
    if cfg.provider == "none" {
        return (raw.to_string(), "det");
    }
    if !cleanup::needs_llm(raw, !cfg.always_llm) {
        return (cleanup::basic_clean(raw), "det");
    }
    // Never block a dictation on model load: if the server isn't ready, start it and fall back.
    if !llm::is_ready() {
        llm::start_in_background();
        return (cleanup::basic_clean(raw), "timeout");
    }
    let system = cleanup::system_prompt(&ctx.exe, &ctx.app_name, vocab);
    let msgs = cleanup::messages(&system, &cleanup::wrap(raw));
    match llm::complete(&msgs, 1024, timeout).and_then(|t| cleanup::finish_llm_output(raw, &t)) {
        Some(t) => (t, "llm"),
        None => (cleanup::basic_clean(raw), "timeout"),
    }
}

/// Everything after audio capture. None when there is nothing to insert.
pub fn run(samples: &[f32], ctx: &Ctx, cfg: &Config, dict: &[DictEntry], llm_timeout: Duration) -> Result<Option<PipelineResult>, String> {
    let vocab = dictionary::vocabulary(dict);
    let t0 = Instant::now();
    asr::wait_ready(Duration::from_secs(120))?;
    let text = asr::transcribe(samples).ok_or_else(|| "speech recognition failed".to_string())?;
    let t1 = Instant::now();
    let raw = cleanup::speech_gate(&text, samples);
    log(&format!("pipeline: samples={} rawLen={} asr={}ms", samples.len(), raw.chars().count(), (t1 - t0).as_millis()));
    if raw.is_empty() {
        return Ok(None);
    }
    let (cleaned, mode) = clean(&raw, &vocab, ctx, cfg, llm_timeout);
    let t2 = Instant::now();
    log(&format!("pipeline: cleanup {mode} {}ms len={}", (t2 - t1).as_millis(), cleaned.chars().count()));
    let final_text = dictionary::finalize(&cleaned, &ctx.before, dict);
    Ok(Some(PipelineResult {
        raw,
        cleaned,
        final_text,
        asr_ms: (t1 - t0).as_millis() as i64,
        llm_ms: (t2 - t1).as_millis() as i64,
        mode,
    }))
}
