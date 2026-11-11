//! Vocabulary-learning diff logic: finds a "heard -> wanted" correction between pasted and edited text
//! (port of VocabDiff in VocabLearner.swift + VocabRules.swift).

use crate::dictionary::DictEntry;
use crate::spell::unknown as unknown_to_spell_checker;
use std::collections::HashSet;
use std::time::{Duration, Instant};

#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub heard: String,
    pub wanted: String,
    pub score: f64,
}

#[derive(Clone, Debug)]
struct Tok {
    raw: String,
    word: String,
}

/// Box-drawing / block characters used by TUIs for borders become spaces.
fn decoration_free(s: &str) -> String {
    s.chars().map(|c| if ('\u{2500}'..='\u{259F}').contains(&c) { ' ' } else { c }).collect()
}

fn is_punct_or_symbol(c: char) -> bool {
    !c.is_alphanumeric() && !c.is_whitespace() && !c.is_control()
}

fn tokenize(s: &str) -> Vec<Tok> {
    decoration_free(s)
        .split(char::is_whitespace)
        .filter(|p| !p.is_empty())
        .filter_map(|part| {
            let w = part.trim_matches(is_punct_or_symbol);
            if w.is_empty() { None } else { Some(Tok { raw: part.to_string(), word: w.to_string() }) }
        })
        .collect()
}

pub fn pair_key(heard: &str, wanted: &str) -> String {
    format!("{}|{}", heard.to_lowercase(), wanted.to_lowercase())
}

pub fn levenshtein(a: &[char], b: &[char]) -> usize {
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut cur = vec![0usize; b.len() + 1];
        cur[0] = i;
        for j in 1..=b.len() {
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + usize::from(a[i - 1] != b[j - 1]));
        }
        prev = cur;
    }
    prev[b.len()]
}

fn norm(ws: &[String]) -> Vec<char> {
    ws.concat().to_lowercase().chars().filter(|c| *c != '-' && !c.is_whitespace()).collect()
}

pub fn similarity(a: &[String], b: &[String]) -> f64 {
    let (x, y) = (norm(a), norm(b));
    let m = x.len().max(y.len());
    if m == 0 { 1.0 } else { 1.0 - levenshtein(&x, &y) as f64 / m as f64 }
}

fn all_punct_num(w: &str) -> bool {
    w.chars().all(|c| c.is_numeric() || is_punct_or_symbol(c))
}

/// Capital not at sentence start, digits, internal caps/acronym, or unknown to the spell checker.
fn looks_like_vocab(t: &Tok, sentence_start: bool) -> bool {
    let w = &t.word;
    if all_punct_num(w) {
        return false;
    }
    if w.chars().any(|c| c.is_numeric()) {
        return true;
    }
    if w.chars().skip(1).any(|c| c.is_uppercase()) {
        return true;
    }
    if let Some(f) = w.chars().next() {
        if f.is_uppercase() && !sentence_start {
            return true;
        }
    }
    unknown_to_spell_checker(w)
}

type Range2 = (std::ops::Range<usize>, std::ops::Range<usize>);

/// Word-level LCS hunks: (range in a, range in b) of non-matching stretches.
fn hunks(a: &[Tok], b: &[Tok]) -> Vec<Range2> {
    let (n, m) = (a.len(), b.len());
    let mut l = vec![vec![0i32; m + 1]; n + 1];
    if n > 0 && m > 0 {
        for i in (0..n).rev() {
            for j in (0..m).rev() {
                l[i][j] = if a[i].word == b[j].word { l[i + 1][j + 1] + 1 } else { l[i + 1][j].max(l[i][j + 1]) };
            }
        }
    }
    let mut out = vec![];
    let (mut i, mut j, mut si, mut sj) = (0usize, 0usize, 0usize, 0usize);
    while i < n || j < m {
        if i < n && j < m && a[i].word == b[j].word {
            if i > si || j > sj {
                out.push((si..i, sj..j));
            }
            i += 1;
            j += 1;
            si = i;
            sj = j;
        } else if j < m && (i == n || l[i][j + 1] >= l[i + 1][j]) {
            j += 1;
        } else {
            i += 1;
        }
    }
    if i > si || j > sj {
        out.push((si..i, sj..j));
    }
    out
}

// ---- phonetic / initialism evidence (VocabRules.swift) -----------------------------------------

pub fn phonetic_key(word: &str) -> String {
    let mut w: Vec<char> = word.to_lowercase().chars().filter(|c| c.is_ascii_alphabetic()).collect();
    if w.is_empty() {
        return String::new();
    }
    let vowels = ['a', 'e', 'i', 'o', 'u'];
    for pre in ["kn", "gn", "pn", "ae", "wr"] {
        if w.len() > 1 && w[..2].iter().collect::<String>() == pre {
            w.remove(0);
        }
    }
    if w.first() == Some(&'x') {
        w[0] = 's';
    }
    let mut out = String::new();
    let at = |k: isize| -> char { if k >= 0 && (k as usize) < w.len() { w[k as usize] } else { '\0' } };
    let mut i: isize = 0;
    while (i as usize) < w.len() {
        let c = w[i as usize];
        if c == at(i - 1) && c != 'c' {
            i += 1;
            continue;
        }
        match c {
            'a' | 'e' | 'i' | 'o' | 'u' => {
                if i == 0 {
                    out.push('A')
                }
            }
            'b' => {
                if !(i as usize == w.len() - 1 && at(i - 1) == 'm') {
                    out.push('B')
                }
            }
            'c' => {
                if at(i + 1) == 'h' {
                    out.push('X');
                    i += 1;
                } else if "iey".contains(at(i + 1)) {
                    if at(i - 1) != 's' {
                        out.push('S')
                    }
                } else if at(i - 1) != 'k' {
                    out.push('K')
                }
            }
            'd' => {
                if at(i + 1) == 'g' && "iey".contains(at(i + 2)) {
                    out.push('J');
                    i += 1;
                } else {
                    out.push('T')
                }
            }
            'g' => {
                if at(i + 1) == 'h' {
                    i += 1;
                } else if "iey".contains(at(i + 1)) {
                    out.push('J')
                } else {
                    out.push('K')
                }
            }
            'h' => {
                if vowels.contains(&at(i + 1)) && !"csptg".contains(at(i - 1)) {
                    out.push('H')
                }
            }
            'k' => {
                if at(i - 1) != 'c' {
                    out.push('K')
                }
            }
            'p' => {
                if at(i + 1) == 'h' {
                    out.push('F');
                    i += 1;
                } else {
                    out.push('P')
                }
            }
            'q' => out.push('K'),
            's' => {
                if at(i + 1) == 'h' {
                    out.push('X');
                    i += 1;
                } else {
                    out.push('S')
                }
            }
            't' => {
                if at(i + 1) == 'h' {
                    out.push('0');
                    i += 1;
                } else if at(i + 1) == 'i' && "ao".contains(at(i + 2)) {
                    out.push('X')
                } else {
                    out.push('T')
                }
            }
            'v' => out.push('F'),
            'w' | 'y' => {
                if vowels.contains(&at(i + 1)) {
                    out.push(c.to_ascii_uppercase())
                }
            }
            'x' => out.push_str("KS"),
            'z' => out.push('S'),
            _ => out.push(c.to_ascii_uppercase()),
        }
        i += 1;
    }
    out
}

pub fn phonetic_similarity(a: &[String], b: &[String]) -> f64 {
    let x: Vec<char> = a.iter().map(|s| phonetic_key(s)).collect::<String>().chars().collect();
    let y: Vec<char> = b.iter().map(|s| phonetic_key(s)).collect::<String>().chars().collect();
    if x.len().min(y.len()) < 3 {
        return 0.0;
    }
    1.0 - levenshtein(&x, &y) as f64 / x.len().max(y.len()) as f64
}

fn number_word(w: &str) -> Option<&'static str> {
    Some(match w {
        "zero" => "0", "one" => "1", "two" => "2", "three" => "3", "four" => "4", "five" => "5",
        "six" => "6", "seven" => "7", "eight" => "8", "nine" => "9", "ten" => "10",
        _ => return None,
    })
}

/// Initials (and number words as digits) of the heard phrase appear in order in the new token(s).
pub fn initialism_match(old: &[String], new: &[String]) -> bool {
    let mut syms: Vec<char> = vec![];
    for w in old {
        let l = w.to_lowercase();
        if let Some(d) = number_word(&l) {
            syms.extend(d.chars());
        } else if let Some(f) = l.chars().find(|c| c.is_alphabetic() || c.is_numeric()) {
            syms.push(f);
        }
    }
    let target: Vec<char> = new.concat().to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect();
    if syms.len() < 2 || target.first() != syms.first() {
        return false;
    }
    let mut k = 0;
    for c in &target {
        if k < syms.len() && *c == syms[k] {
            k += 1;
        }
    }
    k == syms.len()
}

/// A plain misspelling of a common word ("recieve" -> "receive"): the new word is lowercase and known, the old
/// one unknown and within 2 edits. macOS also requires the system speller to rank it in its top 3; without a
/// speller we approximate "common word" by length (rare long terms such as zooxanthellae are never typo fixes).
pub fn is_common_typo_fix(old: &str, new: &str) -> bool {
    if new.chars().count() > 11 || !new.chars().all(|c| c.is_lowercase()) || !old.chars().all(|c| c.is_alphabetic()) {
        return false;
    }
    if unknown_to_spell_checker(new) || !unknown_to_spell_checker(old) {
        return false;
    }
    let o: Vec<char> = old.to_lowercase().chars().collect();
    let n: Vec<char> = new.chars().collect();
    levenshtein(&o, &n) <= 2
}

/// Strongly vocab-like: digits, internal caps, acronym, or unknown to the spell checker.
pub fn strong_vocab(w: &str) -> bool {
    if w.chars().any(|c| c.is_numeric()) {
        return true;
    }
    if w.chars().skip(1).any(|c| c.is_uppercase()) {
        return true;
    }
    if w.chars().count() >= 2 && w.chars().all(|c| c.is_uppercase()) {
        return true;
    }
    unknown_to_spell_checker(w)
}

// ---- candidate ---------------------------------------------------------------------------------

pub fn candidate(pasted: &str, edited: &str, dictionary: &[DictEntry], rejected: &HashSet<String>) -> Option<Candidate> {
    let a = tokenize(pasted);
    let b = tokenize(edited);
    if a.is_empty() || b.is_empty() || a.len() > 4000 || b.len() > 4000 {
        return None;
    }
    let mut best: Option<Candidate> = None;
    for (ra, rb) in hunks(&a, &b) {
        if !(1..=3).contains(&ra.len()) || !(1..=3).contains(&rb.len()) {
            continue;
        }
        let old: Vec<String> = a[ra.clone()].iter().map(|t| t.word.clone()).collect();
        let new: Vec<String> = b[rb.clone()].iter().map(|t| t.word.clone()).collect();
        let heard = old.join(" ");
        let wanted = new.join(" ");
        let case_only = heard.to_lowercase() == wanted.to_lowercase();
        if case_only && !new.iter().any(|w| unknown_to_spell_checker(w)) {
            continue;
        }
        let mut vocab = false;
        for (k, t) in b[rb.clone()].iter().enumerate() {
            let idx = rb.start + k;
            let start = idx == 0 || ".!?".contains(b[idx - 1].raw.chars().last().unwrap_or(' '));
            if looks_like_vocab(t, start) {
                vocab = true;
                break;
            }
        }
        let sim = similarity(&old, &new);
        // A real word replacing a non-word that sounds alike (e.g. zoanthellae -> zooxanthellae).
        if !vocab && sim >= 0.7 && !case_only && old.iter().any(|w| unknown_to_spell_checker(w)) {
            vocab = true;
        }
        if !vocab {
            continue;
        }
        if old.len() == 1 && new.len() == 1 && is_common_typo_fix(&old[0], &new[0]) {
            continue;
        }
        let (no, nn) = (norm(&old), norm(&new));
        let same_first = no.first() == nn.first();
        let len_ratio = no.len().min(nn.len()) as f64 / (1.max(no.len().max(nn.len()))) as f64;
        if !(sim >= 0.5 || (same_first && len_ratio >= 0.7)) {
            // Loosened path: <=3 heard words by <=2 new tokens with extra evidence.
            let strong_ok = rb.len() <= 2
                && new.iter().all(|w| strong_vocab(w))
                && (phonetic_similarity(&old, &new) >= 0.7
                    || initialism_match(&old, &new)
                    || (old.len() == 1
                        && new.len() == 1
                        && new[0].chars().any(|c| c.is_alphabetic())
                        && unknown_to_spell_checker(&new[0])));
            // A proper noun the ASR heard as a similar-sounding common word.
            let proper_ok = old.len() == 1
                && new.len() == 1
                && new[0].chars().next().map(|c| c.is_uppercase()).unwrap_or(false)
                && phonetic_similarity(&old, &new) >= 0.65;
            if !(strong_ok || proper_ok) {
                continue;
            }
        }
        if rejected.contains(&pair_key(&heard, &wanted)) {
            continue;
        }
        if dictionary.iter().any(|e| {
            e.phrase.to_lowercase() == heard.to_lowercase()
                && e.replacement.as_deref().unwrap_or("").to_lowercase() == wanted.to_lowercase()
        }) {
            continue;
        }
        let c = Candidate { heard, wanted, score: sim + if case_only { 0.0 } else { 0.1 } };
        if best.as_ref().map(|b| c.score > b.score).unwrap_or(true) {
            best = Some(c);
        }
    }
    best
}

pub fn describe(c: &Option<Candidate>) -> String {
    c.as_ref().map(|c| format!("{} -> {}", c.heard, c.wanted)).unwrap_or_else(|| "none".into())
}

// ---- fuzzy anchoring (terminals / TUIs where the whole buffer redraws) ------------------------

pub const FUZZY_MAX_PASTED: usize = 60;
pub const FUZZY_TAIL_TOKENS: usize = 2_000;
pub const FUZZY_BUDGET: Duration = Duration::from_millis(50);

fn lcs_len(a: &[String], b: &[String]) -> usize {
    if a.is_empty() || b.is_empty() {
        return 0;
    }
    let mut prev = vec![0usize; b.len() + 1];
    let mut cur = prev.clone();
    for x in a {
        for j in 1..=b.len() {
            cur[j] = if *x == b[j - 1] { prev[j - 1] + 1 } else { prev[j].max(cur[j - 1]) };
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

fn capped_paste(pasted: &str) -> String {
    let t = tokenize(pasted);
    if t.len() <= FUZZY_MAX_PASTED {
        pasted.to_string()
    } else {
        t[t.len() - FUZZY_MAX_PASTED..].iter().map(|t| t.raw.clone()).collect::<Vec<_>>().join(" ")
    }
}

#[derive(Clone, Debug)]
pub struct Window {
    pub text: String,
    pub matched: usize,
    pub end: usize,
}

pub fn fuzzy_windows(pasted: &str, buffer: &str, deadline: Instant) -> Vec<Window> {
    let p: Vec<String> = tokenize(&capped_paste(pasted)).iter().map(|t| t.word.to_lowercase()).collect();
    let tail: String = {
        let keep = FUZZY_TAIL_TOKENS * 12;
        let chars: Vec<char> = buffer.chars().collect();
        if chars.len() > keep { chars[chars.len() - keep..].iter().collect() } else { buffer.to_string() }
    };
    let mut bt = tokenize(&tail);
    if p.is_empty() {
        return vec![];
    }
    if bt.len() > FUZZY_TAIL_TOKENS {
        bt = bt[bt.len() - FUZZY_TAIL_TOKENS..].to_vec();
    }
    let b: Vec<String> = bt.iter().map(|t| t.word.to_lowercase()).collect();
    let need = if p.len() <= 3 { p.len().saturating_sub(2) } else { (0.6 * p.len() as f64).ceil() as usize };
    let pset: HashSet<&String> = p.iter().collect();
    let mut found: Vec<(usize, usize, usize)> = vec![];
    for len in 1.max(p.len().saturating_sub(3))..=(p.len() + 3) {
        if len > b.len() {
            break;
        }
        for s in (0..=(b.len() - len)).rev() {
            if s & 15 == 0 && Instant::now() > deadline {
                break;
            }
            if need > 0 && !b[s..s + len].iter().any(|w| pset.contains(w)) {
                continue;
            }
            let m = lcs_len(&p, &b[s..s + len]);
            if m >= need {
                found.push((s, s + len, m));
            }
        }
    }
    found.sort_by(|x, y| {
        y.2.cmp(&x.2).then(y.1.cmp(&x.1)).then(y.0.cmp(&x.0))
    });
    found
        .into_iter()
        .take(400)
        .map(|(s, e, m)| Window {
            text: bt[s..e].iter().map(|t| t.word.clone()).collect::<Vec<_>>().join(" "),
            matched: m,
            end: e,
        })
        .collect()
}

/// True when the pasted text appears (nearly) intact in the buffer.
pub fn fuzzy_contains(pasted: &str, buffer: &str) -> bool {
    let n = tokenize(&capped_paste(pasted)).len();
    fuzzy_windows(pasted, buffer, Instant::now() + FUZZY_BUDGET).first().map(|w| w.matched == n).unwrap_or(false)
}

pub fn fuzzy_candidate(pasted: &str, buffer: &str, dictionary: &[DictEntry], rejected: &HashSet<String>) -> Option<Candidate> {
    fuzzy_candidate_with_budget(pasted, buffer, dictionary, rejected, FUZZY_BUDGET)
}

pub fn fuzzy_candidate_with_budget(
    pasted: &str,
    buffer: &str,
    dictionary: &[DictEntry],
    rejected: &HashSet<String>,
    budget: Duration,
) -> Option<Candidate> {
    let deadline = Instant::now() + budget;
    let pasted = capped_paste(pasted);
    let pn = tokenize(&pasted).len();
    let mut tried = 0;
    let short = pn <= 3;
    let wins = fuzzy_windows(&pasted, buffer, deadline);
    let intact_end = wins.iter().filter(|w| w.matched == pn).map(|w| w.end).max();
    for w in &wins {
        if Instant::now() > deadline {
            break;
        }
        if w.matched == pn {
            continue;
        }
        if let Some(ie) = intact_end {
            if ie >= w.end {
                continue;
            }
        }
        if short {
            let a: Vec<String> = tokenize(&pasted).into_iter().map(|t| t.word).collect();
            let b: Vec<String> = tokenize(&w.text).into_iter().map(|t| t.word).collect();
            if similarity(&a, &b) < 0.6 {
                continue;
            }
        }
        tried += 1;
        if tried > 60 {
            break;
        }
        if let Some(c) = candidate(&pasted, &w.text, dictionary, rejected) {
            return Some(c);
        }
    }
    None
}

/// Maps the pasted region [rs, re) (UTF-16 offsets, as UI Automation reports them) of `old` through the edit
/// to `new`; returns (oldRegion, newRegion).
pub fn edited_region(old: &str, new: &str, rs: usize, re: usize) -> Option<(String, String)> {
    let o: Vec<u16> = old.encode_utf16().collect();
    let n: Vec<u16> = new.encode_utf16().collect();
    if re > o.len() || rs >= re {
        return None;
    }
    let mut cp = 0;
    while cp < o.len() && cp < n.len() && o[cp] == n[cp] {
        cp += 1;
    }
    let mut cs = 0;
    while cs < o.len() - cp && cs < n.len() - cp && o[o.len() - 1 - cs] == n[n.len() - 1 - cs] {
        cs += 1;
    }
    let zone_end = o.len() - cs;
    if cp >= re || zone_end <= rs {
        return None;
    }
    let s1 = rs.min(cp);
    let e1 = if re >= zone_end {
        (re as isize + (n.len() as isize - o.len() as isize)) as isize
    } else {
        (n.len() - cs) as isize
    };
    if e1 <= s1 as isize || e1 as usize > n.len() {
        return None;
    }
    Some((String::from_utf16_lossy(&o[rs..re]), String::from_utf16_lossy(&n[s1..e1 as usize])))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cand(p: &str, e: &str) -> String {
        describe(&candidate(p, e, &[], &HashSet::new()))
    }
    fn check(p: &str, e: &str, want: Option<&str>) {
        assert_eq!(cand(p, e), want.unwrap_or("none"), "\"{p}\" -> \"{e}\"");
    }

    #[test]
    fn swift_cases() {
        check("take control of my collab tree tab", "take control of my Kolabtree tab", Some("collab tree -> Kolabtree"));
        check("file it into the Neely AI forward repo", "file it into the Neeley AI Forward repo", Some("Neely -> Neeley"));
        check("I think we should ship it", "I think we should launch it on Friday", None);
        check("send it to john", "send it to John", None);
        check("how does zoanthellae bleach coral", "how does zooxanthellae bleach coral", Some("zoanthellae -> zooxanthellae"));
        check("let's meet at 3", "let's meet at 4", None);
    }

    #[test]
    fn rules() {
        check("ask the glorp team to join", "ask the Zyntrex team to join", Some("glorp -> Zyntrex"));
        check("we use the frobnic tool", "we use the zyntrexo tool", Some("frobnic -> zyntrexo"));
        check("open the hub two plan today", "open the H2P plan today", Some("hub two -> H2P"));
        check("see ticket one now", "see T1D1 QA now", Some("ticket one -> T1D1 QA"));
        check("the ay pee eye docs", "the API docs", None);
        check("call the model gpt four", "call the model GPT4", Some("gpt four -> GPT4"));
        check("use the ex eye ess dock", "use the XyZ dock", None);
        for (bad, good) in [("recieve", "receive"), ("definately", "definitely"), ("teh", "the"), ("seperate", "separate"),
                            ("occured", "occurred"), ("untill", "until")] {
            check(&format!("I will {bad} it soon"), &format!("I will {good} it soon"), None);
        }
        check("ship it", "launch it", None);
        check("move the meeting soon", "move the Tuesday soon", None);
        check("let's meet at 3", "let's meet at 4", None);
        check("send to john", "send to John", None);
        check("send it forward", "send it Forward", None);
        check("ask the team", "ask the Forward", None);
        check("I like the red one", "I like the Blue one", None);
        assert!(phonetic_similarity(&["fonetik".into()], &["phonetic".into()]) >= 0.7);
        assert!(phonetic_similarity(&["collab".into(), "tree".into()], &["Kolabtree".into()]) >= 0.7);
        assert!(phonetic_similarity(&["ship".into()], &["launch".into()]) < 0.7);
        assert!(initialism_match(&["week".into(), "one".into()], &["W1A".into()]));
        assert!(!initialism_match(&["one".into(), "week".into()], &["W1A".into()]));
        assert!(!initialism_match(&["week".into()], &["W1A".into()]));
        assert!(!strong_vocab("Tuesday") && !strong_vocab("John") && !strong_vocab("Forward"));
        assert!(strong_vocab("TXHES") && strong_vocab("W1A") && strong_vocab("FBPase"));
    }

    #[test]
    fn anchor() {
        let old = "Intro line.\ntake control of my collab tree tab\nOutro.";
        let new = "Intro line!!\ntake control of my Kolabtree tab\nOutro.";
        let needle = "take control of my collab tree tab";
        let rs = old.encode_utf16().count() - "\nOutro.".encode_utf16().count() - needle.encode_utf16().count();
        let (o, n) = edited_region(old, new, rs, rs + needle.encode_utf16().count()).unwrap();
        assert_eq!(cand(&o, &n), "collab tree -> Kolabtree");
        assert!(edited_region("abc", "abc", 0, 3).is_none());
    }

    fn tui(prompt: &str, spinner: &str) -> String {
        format!(
            "\u{256d}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256e}\n\u{2502} \u{273b} Welcome to Claude Code!    \u{2502}\n\u{2570}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256f}\n> earlier thing I asked about the repo\n{spinner} Pondering\u{2026} (esc to interrupt)\n\u{256d}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256e}\n\u{2502} > {prompt}\n\u{2570}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256f}\n  ? for shortcuts"
        )
    }

    #[test]
    fn tui_cases() {
        let none = HashSet::new();
        let long = "take control of my collab tree tab and then list the open windows";
        let long_e = "take control of my Kolabtree tab and then list the open windows";
        let cases = [("Collab tree", "Kolabtree", "single"), (long, long_e, "sentence"), (long, long_e, "wrapped")];
        for (p, e, name) in cases {
            let mut before = tui(p, "\u{2736}");
            let mut after = tui(e, "\u{273b}");
            if name == "wrapped" {
                before = before.replace("my collab", "my\n\u{2502}   collab");
                after = after.replace("my Kolabtree", "my\n\u{2502}   Kolabtree");
            }
            let got = describe(&fuzzy_candidate(p, &after, &[], &none));
            let present = fuzzy_contains(p, &before) || p.split(' ').count() <= 3;
            assert_eq!(got, "collab tree -> Kolabtree".replace("collab tree", if name == "single" { "Collab tree" } else { "collab tree" }), "{name}");
            assert!(present, "{name} present");
        }
        assert_eq!(describe(&fuzzy_candidate("Collab tree", &tui("Collab tree", "\u{273b}"), &[], &none)), "none");
        let older = "> an older note mentioning a collar here\n\u{2736} Pondering\n\u{2502} > collab \u{2502}\n";
        assert_eq!(describe(&fuzzy_candidate("collab", &older.replace('\u{2736}', "\u{273b}"), &[], &none)), "none");
        let older_sim = "> please file Colab tree notes\n\u{2736} Thinking\n\u{2502} > Collab tree \u{2502}\n";
        assert_eq!(describe(&fuzzy_candidate("Collab tree", older_sim, &[], &none)), "none");
        let hist = tui("Collab tree", "\u{2736}").replace("> earlier thing I asked about the repo", "> Collab tree");
        let g2 = fuzzy_candidate("Collab tree", &hist.replace("\u{2502} > Collab tree", "\u{2502} > Kolabtree"), &[], &none);
        assert_eq!(describe(&g2), "Collab tree -> Kolabtree");
    }

    #[test]
    fn fuzzy_perf() {
        let vocab = ["the", "collab", "tree", "open", "window", "and", "then", "list", "my", "tab", "take", "control", "of"];
        let mut seed: u64 = 42;
        let mut rnd = || {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (seed >> 33) as usize
        };
        let long: Vec<&str> = (0..150).map(|_| vocab[rnd() % vocab.len()]).collect();
        let long = long.join(" ");
        let big: Vec<&str> = (0..12_000).map(|_| vocab[rnd() % vocab.len()]).collect();
        let big = format!("{} {}", big.join(" "), long.replace("tree", "Kolabtree"));
        let t0 = Instant::now();
        let _ = fuzzy_candidate(&long, &big, &[], &HashSet::new());
        // The budget bounds the work (generous bound for slow CI runners).
        assert!(t0.elapsed() < Duration::from_millis(500), "{:?}", t0.elapsed());
    }

    #[test]
    fn rejected_and_known_pairs_are_skipped() {
        let mut rej = HashSet::new();
        rej.insert(pair_key("collab tree", "Kolabtree"));
        assert!(candidate("my collab tree tab", "my Kolabtree tab", &[], &rej).is_none());
        let d = vec![DictEntry::learned("collab tree", "Kolabtree")];
        assert!(candidate("my collab tree tab", "my Kolabtree tab", &d, &HashSet::new()).is_none());
    }
}
