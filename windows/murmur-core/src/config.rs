//! Settings stored as JSON (config.json) plus history entries. Port of Settings.swift's data model.

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// Push-to-talk key choices offered in the tray menu.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "n")]
pub enum PttKey {
    RightCtrl,
    CtrlWin,
    RightAlt,
    /// F1..F24
    F(u8),
}

impl PttKey {
    pub fn label(&self) -> String {
        match self {
            PttKey::RightCtrl => "Right Ctrl".into(),
            PttKey::CtrlWin => "Ctrl + Win".into(),
            PttKey::RightAlt => "Right Alt".into(),
            PttKey::F(n) => format!("F{n}"),
        }
    }
    /// Parses labels such as "right-ctrl", "ctrl+win", "right alt", "f9".
    pub fn parse(s: &str) -> Option<PttKey> {
        let t: String = s.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect();
        match t.as_str() {
            "rightctrl" | "rctrl" | "rightcontrol" => Some(PttKey::RightCtrl),
            "ctrlwin" | "controlwin" | "winctrl" => Some(PttKey::CtrlWin),
            "rightalt" | "ralt" | "altgr" => Some(PttKey::RightAlt),
            _ => {
                let n: u8 = t.strip_prefix('f')?.parse().ok()?;
                (1..=24).contains(&n).then_some(PttKey::F(n))
            }
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub ptt_key: PttKey,
    /// "local" (llama-server) or "none" (deterministic only).
    pub provider: String,
    pub learn_vocab: bool,
    pub always_llm: bool,
    /// "heard|wanted" pairs (lowercased) the user asked never to be offered again.
    pub rejected_pairs: BTreeSet<String>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            ptt_key: PttKey::RightCtrl,
            provider: "local".into(),
            learn_vocab: true,
            always_llm: false,
            rejected_pairs: BTreeSet::new(),
        }
    }
}

impl Config {
    pub fn parse(json: &str) -> Config {
        serde_json::from_str(json).unwrap_or_default()
    }
    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_default()
    }
}

/// One line of history.jsonl (same keys as the macOS app).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub ts: String,
    pub raw: String,
    pub cleaned: String,
    pub app: String,
    pub asr_ms: i64,
    pub llm_ms: i64,
    pub total_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub spec: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn roundtrip() {
        let mut c = Config::default();
        c.ptt_key = PttKey::F(9);
        c.rejected_pairs.insert("a|b".into());
        let back = Config::parse(&c.to_json());
        assert_eq!(back.ptt_key, PttKey::F(9));
        assert!(back.rejected_pairs.contains("a|b"));
        assert_eq!(Config::parse("garbage").ptt_key, PttKey::RightCtrl);
        assert_eq!(Config::parse("{\"learn_vocab\":false}").learn_vocab, false);
    }
    #[test]
    fn parse_keys() {
        assert_eq!(PttKey::parse("Right Ctrl"), Some(PttKey::RightCtrl));
        assert_eq!(PttKey::parse("ctrl+win"), Some(PttKey::CtrlWin));
        assert_eq!(PttKey::parse("F13"), Some(PttKey::F(13)));
        assert_eq!(PttKey::parse("f99"), None);
        assert_eq!(PttKey::parse("space"), None);
    }
}
