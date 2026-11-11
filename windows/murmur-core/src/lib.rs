//! Platform-independent core of Murmur (Windows port). Ported from the Swift sources
//! (Cleanup.swift, Pipeline.swift, Settings.swift, VocabLearner.swift, VocabRules.swift, ReplayModel.swift).

pub mod cleanup;
pub mod config;
pub mod dictionary;
pub mod replay;
pub mod spell;
pub mod vocab;

pub(crate) fn re(pat: &str) -> fancy_regex::Regex {
    fancy_regex::Regex::new(pat).expect("valid regex")
}

/// Replaces every match of `re` in `text` with the literal `rep` (no `$` expansion).
pub(crate) fn replace_lit(re: &fancy_regex::Regex, text: &str, rep: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for m in re.find_iter(text).flatten() {
        out.push_str(&text[last..m.start()]);
        out.push_str(rep);
        last = m.end();
    }
    out.push_str(&text[last..]);
    out
}
