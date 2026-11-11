//! Spell-check substitute for NSSpellChecker: a bundled English word list (gzip, lowercase, one word per line).

use std::collections::HashSet;
use std::io::Read;
use std::sync::OnceLock;

static WORDS_GZ: &[u8] = include_bytes!("../data/words.txt.gz");

fn words() -> &'static HashSet<String> {
    static W: OnceLock<HashSet<String>> = OnceLock::new();
    W.get_or_init(|| {
        let mut s = String::new();
        let _ = flate2::read::GzDecoder::new(WORDS_GZ).read_to_string(&mut s);
        s.lines().map(|l| l.to_string()).collect()
    })
}

fn known_plain(w: &str) -> bool {
    words().contains(w)
}

/// True when the word is a known English word (handles simple contractions and possessives).
pub fn is_known(word: &str) -> bool {
    let w = word.to_lowercase().replace('\u{2019}', "'");
    if let Some(p) = w.find('\'') {
        let (pre, suf) = (&w[..p], &w[p + 1..]);
        if pre.is_empty() {
            return false;
        }
        let suf_ok = matches!(suf, "s" | "t" | "re" | "ve" | "ll" | "d" | "m" | "");
        let pre_ok = known_plain(pre) || (suf == "t" && pre.ends_with('n') && known_plain(&pre[..pre.len() - 1]));
        return suf_ok && pre_ok;
    }
    known_plain(&w)
}

/// Mirrors `checkSpelling(of:)` flagging a token: unknown when it has letters and is not a known word.
/// Tokens mixing digits and letters (GPT4, H2P) count as unknown; pure numbers are ignored.
pub fn unknown(word: &str) -> bool {
    if !word.chars().any(|c| c.is_alphabetic()) {
        return false;
    }
    if word.chars().any(|c| c.is_numeric()) {
        return true;
    }
    !is_known(word)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn basics() {
        assert!(is_known("receive") && is_known("Friday") && is_known("don't") && is_known("John's"));
        assert!(unknown("glorp") && unknown("Zyntrex") && unknown("Kolabtree") && unknown("GPT4"));
        assert!(!unknown("3") && !unknown("occurred"));
    }
}
