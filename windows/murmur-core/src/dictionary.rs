//! User dictionary: deterministic replacements incl. fuzzy learned ones (port of Settings.swift
//! UserDictionary and Pipeline.swift Fuzzy/Post).

use serde::{Deserialize, Serialize};

/// dictionary.json entry (same schema as the macOS app).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DictEntry {
    pub phrase: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replacement: Option<String>,
    /// Rule created from an accepted suggestion / manual add: also matched fuzzily.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub learned: Option<bool>,
}

impl DictEntry {
    pub fn term(phrase: &str) -> DictEntry {
        DictEntry { phrase: phrase.into(), replacement: None, learned: None }
    }
    pub fn learned(phrase: &str, replacement: &str) -> DictEntry {
        DictEntry { phrase: phrase.into(), replacement: Some(replacement.into()), learned: Some(true) }
    }
}

pub fn parse_dictionary(json: &str) -> Vec<DictEntry> {
    serde_json::from_str(json).unwrap_or_default()
}

pub fn dictionary_to_json(entries: &[DictEntry]) -> String {
    serde_json::to_string_pretty(entries).unwrap_or_else(|_| "[]".into())
}

pub mod fuzzy {
    use super::DictEntry;

    /// Lowercase, alphanumerics only, repeated characters collapsed: "Collab tree" -> "colabtre".
    pub fn norm(s: &str) -> String {
        let mut out = String::new();
        for c in s.to_lowercase().chars() {
            if (c.is_alphabetic() || c.is_numeric()) && out.chars().last() != Some(c) {
                out.push(c);
            }
        }
        out
    }

    pub fn eligible(e: &DictEntry) -> bool {
        matches!(&e.replacement, Some(r) if !r.is_empty()) && e.learned == Some(true)
    }

    fn word_ranges(text: &str) -> Vec<(usize, usize)> {
        let mut out = vec![];
        let mut start: Option<usize> = None;
        for (i, c) in text.char_indices() {
            if c.is_alphabetic() || c.is_numeric() {
                start.get_or_insert(i);
            } else if let Some(s) = start.take() {
                out.push((s, i));
            }
        }
        if let Some(s) = start {
            out.push((s, text.len()));
        }
        out
    }

    /// Replaces any 1-3 consecutive whole words (separated by spaces or hyphens) whose normalized form
    /// equals the normalized phrase.
    pub fn apply(text: &str, phrase: &str, replacement: &str) -> String {
        let target = norm(phrase);
        if target.chars().count() < 5 {
            return text.to_string();
        }
        let words = word_ranges(text);
        let joined = |i: usize, j: usize| {
            let gap = &text[words[i].1..words[j].0];
            !gap.is_empty() && gap.chars().all(|c| c == ' ' || c == '\t' || c == '-' || c == '\u{2013}')
        };
        let mut hits: Vec<(usize, usize)> = vec![];
        let mut i = 0;
        while i < words.len() {
            let mut matched = 0;
            let mut acc = String::new();
            for len in 1..=3 {
                if i + len > words.len() {
                    break;
                }
                if len > 1 && !joined(i + len - 2, i + len - 1) {
                    break;
                }
                acc.push_str(&norm(&text[words[i + len - 1].0..words[i + len - 1].1]));
                if acc == target {
                    matched = len;
                    break;
                }
                if acc.chars().count() > target.chars().count() {
                    break;
                }
            }
            if matched > 0 {
                hits.push((words[i].0, words[i + matched - 1].1));
                i += matched;
            } else {
                i += 1;
            }
        }
        let mut out = text.to_string();
        for (s, e) in hits.into_iter().rev() {
            out.replace_range(s..e, replacement);
        }
        out
    }
}

pub fn apply_dictionary(text: &str, entries: &[DictEntry]) -> String {
    let mut t = text.to_string();
    for e in entries {
        let rep = match &e.replacement {
            Some(r) if !r.is_empty() => r,
            _ => continue,
        };
        if e.phrase.is_empty() {
            continue;
        }
        let pat = format!(
            "(?i)(?<![\\p{{L}}\\p{{N}}_]){}(?![\\p{{L}}\\p{{N}}_])",
            fancy_regex::escape(&e.phrase)
        );
        if let Ok(r) = fancy_regex::Regex::new(&pat) {
            t = crate::replace_lit(&r, &t, rep);
        }
        // Swift runs the fuzzy pass in a `defer`, i.e. after the exact pass, even if the regex failed.
        if fuzzy::eligible(e) {
            t = fuzzy::apply(&t, &e.phrase, rep);
        }
    }
    t
}

/// Adds a leading space when pasting right after non-whitespace text.
pub fn finalize(text: &str, before: &str, dictionary: &[DictEntry]) -> String {
    let mut t = apply_dictionary(text, dictionary);
    if let Some(last) = before.chars().last() {
        if !last.is_whitespace() && !t.is_empty() {
            t = format!(" {t}");
        }
    }
    t
}

/// Terms handed to the cleanup LLM: plain vocabulary spellings (replacements are applied after cleanup).
pub fn vocabulary(entries: &[DictEntry]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut out = vec![];
    for e in entries {
        if !e.replacement.as_deref().unwrap_or("").is_empty() {
            continue;
        }
        let t = e.phrase.trim();
        if !t.is_empty() && seen.insert(t.to_lowercase()) {
            out.push(t.to_string());
        }
    }
    out
}

/// Adds the deterministic fix (heard -> wanted) and the plain vocabulary term; returns entries added.
pub fn add_learned(entries: &mut Vec<DictEntry>, heard: Option<&str>, wanted: &str) -> usize {
    let mut added = 0;
    let h = heard.unwrap_or("").trim();
    if !h.is_empty() {
        let hn = fuzzy::norm(h);
        let has_fix = entries.iter().any(|e| match &e.replacement {
            Some(r) if !r.is_empty() => {
                e.phrase.to_lowercase() == h.to_lowercase()
                    || (fuzzy::norm(&e.phrase) == hn && r.to_lowercase() == wanted.to_lowercase())
            }
            _ => false,
        });
        if !has_fix {
            entries.push(DictEntry::learned(h, wanted));
            added += 1;
        }
    }
    let has_term = entries
        .iter()
        .any(|e| e.phrase.to_lowercase() == wanted.to_lowercase() && e.replacement.as_deref().unwrap_or("").is_empty());
    if !has_term {
        entries.push(DictEntry::term(wanted));
        added += 1;
    }
    added
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuzzy_apply_cases() {
        let dict = vec![DictEntry::learned("collab tree", "Kolabtree")];
        let cases = [
            ("open Colab tree now", "open Kolabtree now"),
            ("open colab-tree now", "open Kolabtree now"),
            ("open Collabtree now", "open Kolabtree now"),
            ("open collab tree.", "open Kolabtree."),
            ("we should collaborate", "we should collaborate"),
            ("collab trees are fun", "collab trees are fun"),
        ];
        for (i, want) in cases {
            assert_eq!(apply_dictionary(i, &dict), want, "input {i}");
        }
        let hand = apply_dictionary("say Colab tree", &[DictEntry { phrase: "collab tree".into(), replacement: Some("Kolabtree".into()), learned: None }]);
        assert_eq!(hand, "say Colab tree");
    }

    #[test]
    fn exact_is_whole_word_and_case_insensitive() {
        let d = vec![DictEntry { phrase: "murmur".into(), replacement: Some("Murmur".into()), learned: None }];
        assert_eq!(apply_dictionary("a MURMUR and murmurs", &d), "a Murmur and murmurs");
        let d2 = vec![DictEntry { phrase: "c++".into(), replacement: Some("C plus plus".into()), learned: None }];
        assert_eq!(apply_dictionary("I like c++ a lot", &d2), "I like C plus plus a lot");
    }

    #[test]
    fn finalize_spacing() {
        assert_eq!(finalize("Hello", "foo", &[]), " Hello");
        assert_eq!(finalize("Hello", "foo ", &[]), "Hello");
        assert_eq!(finalize("Hello", "", &[]), "Hello");
    }

    #[test]
    fn learn_and_vocab() {
        let mut e = vec![];
        assert_eq!(add_learned(&mut e, Some("collab tree"), "Kolabtree"), 2);
        assert_eq!(add_learned(&mut e, Some("Collab Tree"), "Kolabtree"), 0);
        assert_eq!(vocabulary(&e), vec!["Kolabtree".to_string()]);
        let json = dictionary_to_json(&e);
        assert_eq!(parse_dictionary(&json), e);
        assert!(json.contains("\"learned\": true"));
    }
}
