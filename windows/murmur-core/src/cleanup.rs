//! Deterministic cleanup, LLM gating and the LLM drift guard (port of Cleanup.swift + SpeechGate).

use crate::{re, replace_lit};
use fancy_regex::Regex;
use std::sync::OnceLock;

pub const PROMPT_TEMPLATE: &str =
    include_str!("../../../Sources/Murmur/Resources/cleanup_prompt.txt");
pub const STYLES_JSON: &str = include_str!("../../../Sources/Murmur/Resources/styles.json");
pub const FEWSHOT_JSON: &str = include_str!("../../../Sources/Murmur/Resources/fewshot.json");

/// Cleanup budget after key release (same as the macOS app).
pub const RELEASE_BUDGET_SECS: f64 = 0.9;

const MESSAGING_EXE: &[&str] = &[
    "slack", "discord", "whatsapp", "telegram", "signal", "teams", "ms-teams", "wechat", "messenger",
];
const EMAIL_EXE: &[&str] = &[
    "outlook", "olk", "winword", "onenote", "thunderbird", "notepad", "wordpad", "mailbird", "evernote",
];
const AI_EXE: &[&str] = &[
    "windowsterminal", "wt", "cmd", "powershell", "pwsh", "conhost", "alacritty", "wezterm-gui", "wezterm",
    "kitty", "warp", "code", "cursor", "claude", "codex", "mintty", "hyper", "windsurf",
];

/// Style bucket for the focused app. `exe` is the process image name (with or without ".exe", any case).
pub fn style_key(exe: &str) -> &'static str {
    let lower = exe.trim().to_lowercase();
    let e = lower.trim_end_matches(".exe");
    if MESSAGING_EXE.contains(&e) {
        "messaging"
    } else if EMAIL_EXE.contains(&e) {
        "email"
    } else if AI_EXE.contains(&e) {
        "ai"
    } else {
        "default"
    }
}

pub fn system_prompt(exe: &str, app_name: &str, vocab: &[String]) -> String {
    let styles: std::collections::HashMap<String, String> =
        serde_json::from_str(STYLES_JSON).unwrap_or_default();
    let style = styles
        .get(style_key(exe))
        .or_else(|| styles.get("default"))
        .cloned()
        .unwrap_or_default();
    PROMPT_TEMPLATE
        .replace("{{APP}}", if app_name.is_empty() { "the active app" } else { app_name })
        .replace("{{STYLE}}", &style)
        .replace("{{VOCAB}}", &vocab.join(", "))
}

pub fn wrap(raw: &str) -> String {
    format!("<<<\n{raw}\n>>>")
}

/// Few-shot (role, content) pairs shared with the eval harness.
pub fn few_shot() -> Vec<(String, String)> {
    let pairs: Vec<Vec<String>> = serde_json::from_str(FEWSHOT_JSON).unwrap_or_default();
    let mut out = vec![];
    for p in pairs {
        if p.len() >= 2 {
            out.push(("user".to_string(), wrap(&p[0])));
            out.push(("assistant".to_string(), p[1].clone()));
        }
    }
    out
}

/// OpenAI-style chat messages: system, few-shot, user.
pub fn messages(system: &str, user: &str) -> Vec<(String, String)> {
    let mut m = vec![("system".to_string(), system.to_string())];
    m.extend(few_shot());
    m.push(("user".to_string(), user.to_string()));
    m
}

// ---- drift guard -------------------------------------------------------------------------------

fn num_word(w: &str) -> Option<&'static str> {
    Some(match w {
        "zero" => "0", "one" => "1", "two" => "2", "three" => "3", "four" => "4", "five" => "5",
        "six" => "6", "seven" => "7", "eight" => "8", "nine" => "9", "ten" => "10",
        _ => return None,
    })
}

pub fn norm_words(s: &str) -> Vec<String> {
    let lowered = s.to_lowercase().replace('\u{2019}', "'");
    let cleaned: String = lowered
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '\'' || c == '%' || c == '_' { c } else { ' ' })
        .collect();
    cleaned
        .split(' ')
        .filter(|w| !w.is_empty())
        .map(|w| num_word(w).map(String::from).unwrap_or_else(|| w.to_string()))
        .collect()
}

pub fn lcs(a: &[String], b: &[String]) -> usize {
    let mut d = vec![0usize; b.len() + 1];
    for x in a {
        let mut prev = 0;
        for j in 0..b.len() {
            let t = d[j + 1];
            d[j + 1] = if *x == b[j] { prev + 1 } else { d[j + 1].max(d[j]) };
            prev = t;
        }
    }
    d[b.len()]
}

fn profanity() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| re(r"(?i)fuck|shit|damn|bitch|\bass\b"))
}

fn count_matches(r: &Regex, s: &str) -> usize {
    r.find_iter(s).flatten().count()
}

/// Reject LLM output that drifted (answered the prompt, echoed context, hallucinated): returns `raw` then.
pub fn guard_output(raw: &str, hyp: &str) -> String {
    static ART: OnceLock<Regex> = OnceLock::new();
    let art = ART.get_or_init(|| re(r"\w-\s?['\u{2019} ]?t\b"));
    let r = norm_words(raw);
    let h = norm_words(hyp);
    let novel = (h.len() - lcs(&r, &h).min(h.len())) as f64 / (h.len().max(1)) as f64;
    let hw = hyp.split_whitespace().count() as f64;
    let rw = raw.split_whitespace().count() as f64;
    let ok = novel <= 0.08
        && h.len() as f64 >= 0.6 * r.len() as f64
        && hw <= 1.5 * rw + 6.0
        && count_matches(profanity(), hyp) >= count_matches(profanity(), raw)
        && !art.is_match(hyp).unwrap_or(false);
    if ok { hyp.to_string() } else { raw.to_string() }
}

// ---- deterministic cleanup ---------------------------------------------------------------------

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Words (`\w+` runs) with byte ranges.
fn word_spans(s: &str) -> Vec<(usize, usize)> {
    let mut spans = vec![];
    let mut start: Option<usize> = None;
    for (i, c) in s.char_indices() {
        if is_word_char(c) {
            if start.is_none() {
                start = Some(i);
            }
        } else if let Some(st) = start.take() {
            spans.push((st, i));
        }
    }
    if let Some(st) = start {
        spans.push((st, s.len()));
    }
    spans
}

/// `(?i)\b(\w+)(?: \1\b)+` -> `$1` (a word repeated with single spaces collapses to its first occurrence).
fn collapse_stutters(s: &str) -> String {
    let spans = word_spans(s);
    let mut out = String::new();
    let mut last = 0;
    let mut i = 0;
    while i < spans.len() {
        let (a, b) = spans[i];
        let mut j = i;
        while j + 1 < spans.len() {
            let (na, nb) = spans[j + 1];
            if &s[spans[j].1..na] == " " && s[na..nb].to_lowercase() == s[a..b].to_lowercase() {
                j += 1;
            } else {
                break;
            }
        }
        if j > i {
            out.push_str(&s[last..b]);
            last = spans[j].1;
        }
        i = j + 1;
    }
    out.push_str(&s[last..]);
    out
}

fn has_adjacent_repeat(s: &str) -> bool {
    let spans = word_spans(s);
    spans.windows(2).any(|w| {
        &s[w[0].1..w[1].0] == " " && s[w[0].0..w[0].1].to_lowercase() == s[w[1].0..w[1].1].to_lowercase()
    })
}

/// Deterministic cleanup: strip fillers and stutters, tidy spacing, capitalize the first letter.
pub fn basic_clean(raw: &str) -> String {
    static R1: OnceLock<Regex> = OnceLock::new();
    static R3: OnceLock<Regex> = OnceLock::new();
    static R4: OnceLock<Regex> = OnceLock::new();
    static R5: OnceLock<Regex> = OnceLock::new();
    let r1 = R1.get_or_init(|| re(r"(?i)(^|\s)(um+|uh+|erm+|hmm+)[,.\u{2026}]*(?=\s|$)"));
    let r3 = R3.get_or_init(|| re(r"\s+([,.?!])"));
    let r4 = R4.get_or_init(|| re(r"\s{2,}"));
    let r5 = R5.get_or_init(|| re(r"^[,.\s]+"));
    let mut t = replace_lit(r1, raw, " ");
    t = collapse_stutters(&t);
    t = r3.replace_all(&t, "$1").into_owned();
    t = replace_lit(r4, &t, " ");
    t = replace_lit(r5, &t, "");
    // Swift trims .whitespaces (spaces/tabs, not newlines).
    t = t.trim_matches(|c: char| c == ' ' || c == '\t' || c == '\u{a0}').to_string();
    if let Some(f) = t.chars().next() {
        if f.is_lowercase() {
            let up: String = f.to_uppercase().collect();
            t = format!("{up}{}", &t[f.len_utf8()..]);
        }
    }
    if t.is_empty() { raw.to_string() } else { t }
}

fn needs_llm_pattern() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        re(concat!(
            r"(?i)\b(um+|uh+|actually|no wait|wait no|scratch that|i mean|or rather|comma|period|question mark|",
            r"new ?line|new paragraph|colon|bullet|number one|firstly|secondly)\b"
        ))
    })
}

/// True when the transcript has something deterministic cleanup can't fix (self-corrections, fillers,
/// spoken punctuation/commands, repeated words). `gate_enabled=false` ("alwaysLLM") makes it always true.
pub fn needs_llm(raw: &str, gate_enabled: bool) -> bool {
    if !gate_enabled {
        return true;
    }
    needs_llm_pattern().is_match(raw).unwrap_or(false) || has_adjacent_repeat(raw)
}

/// Small-model output artifacts seen in history ("don-'t").
pub fn fix_artifacts(s: &str) -> String {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| re(r"(\p{L})-['\u{2019}](\p{L})")).replace_all(s, "$1'$2").into_owned()
}

/// What the app does with the LLM's reply: strip think blocks and wrapper markers, fix artifacts, guard.
/// Returns None when the reply is unusable (empty) -> caller falls back to `basic_clean`.
pub fn finish_llm_output(raw: &str, llm_text: &str) -> Option<String> {
    let mut text = llm_text.to_string();
    if let Some(p) = text.find("</think>") {
        text = text[p + "</think>".len()..].to_string();
    }
    text = text.replace("<<<", "").replace(">>>", "");
    text = text.trim().to_string();
    text = fix_artifacts(&text);
    if text.is_empty() {
        return None;
    }
    let g = guard_output(raw, &text);
    Some(if g == raw { basic_clean(raw) } else { g })
}

// ---- speech gate -------------------------------------------------------------------------------

pub fn rms(s: &[f32]) -> f32 {
    if s.is_empty() {
        return 0.0;
    }
    (s.iter().map(|v| v * v).sum::<f32>() / s.len() as f32).sqrt()
}

const HALLUCINATIONS: &[&str] = &[
    "thank you", "thank you.", "thanks for watching", "thanks for watching!", "you",
    "thank you for watching", "thank you for watching.", "thank you for watching!", "bye", "bye.",
];

/// Returns the transcript to use, or "" when nothing should be inserted.
pub fn speech_gate(text: &str, samples: &[f32]) -> String {
    static R1: OnceLock<Regex> = OnceLock::new();
    static R2: OnceLock<Regex> = OnceLock::new();
    let r1 = R1.get_or_init(|| re(r"\*[^*\n]{1,40}\*|\[[^\]\n]{1,40}\]|\u{266A}+"));
    let r2 = R2.get_or_init(|| re(r"\s{2,}"));
    let t = replace_lit(r1, text.trim(), " ");
    let t = replace_lit(r2, &t, " ");
    let t = t.trim().to_string();
    if rms(samples) < 0.01 && HALLUCINATIONS.contains(&t.to_lowercase().as_str()) {
        return String::new();
    }
    t
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic() {
        assert_eq!(basic_clean("um so the the plan is uh good"), "So the plan is good");
        assert_eq!(basic_clean("please send the report by friday ."), "Please send the report by friday.");
        assert_eq!(basic_clean("hello hello world"), "Hello world");
        assert_eq!(basic_clean("Stop STOP now"), "Stop now");
        assert_eq!(basic_clean("the thesis"), "The thesis");
    }

    #[test]
    fn gate() {
        assert!(!needs_llm("Please send the report by Friday.", true));
        assert!(needs_llm("send it um tomorrow", true));
        assert!(needs_llm("no wait I mean tuesday", true));
        assert!(needs_llm("we we should go", true));
        assert!(!needs_llm("the thesis is that", true));
        assert!(needs_llm("anything", false));
        assert!(needs_llm("add a comma here", true));
    }

    #[test]
    fn guard() {
        let raw = "um so the launch is moved to friday uh i think";
        assert_eq!(guard_output(raw, "The launch is moved to Friday, I think."), "The launch is moved to Friday, I think.");
        assert_eq!(guard_output(raw, "Sure! Here is a poem about launches and so on and on."), raw);
        assert_eq!(guard_output("what the shit is this", "What the heck is this"), "what the shit is this");
        assert_eq!(guard_output("dont go", "don-'t go"), "dont go");
        assert_eq!(fix_artifacts("don-'t"), "don't");
    }

    #[test]
    fn prompt_and_style() {
        assert_eq!(style_key("slack.exe"), "messaging");
        assert_eq!(style_key("Code"), "ai");
        assert_eq!(style_key("chrome"), "default");
        let p = system_prompt("slack", "Slack", &["Kolabtree".into(), "Murmur".into()]);
        assert!(p.contains("Kolabtree, Murmur"));
        assert!(!p.contains("{{"));
        assert!(few_shot().len() >= 2);
        assert_eq!(wrap("x"), "<<<\nx\n>>>");
    }

    #[test]
    fn llm_finish() {
        let raw = "um send it on friday";
        assert_eq!(finish_llm_output(raw, "<<<\nSend it on Friday.\n>>>").unwrap(), "Send it on Friday.");
        assert!(finish_llm_output(raw, "  ").is_none());
        assert_eq!(finish_llm_output("hello there", "</think>Hello there."), Some("Hello there.".into()));
    }

    #[test]
    fn gate_hallucination() {
        assert_eq!(speech_gate("Thank you.", &[0.0; 100]), "");
        assert_eq!(speech_gate("Thank you.", &[0.5; 100]), "Thank you.");
        assert_eq!(speech_gate("[BLANK_AUDIO] hello", &[0.5; 10]), "hello");
    }
}
