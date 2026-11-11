//! Simulates the user's edits to the pasted text from key events alone (works where UI Automation can't
//! read the field). Port of ReplayModel.swift. Frozen ("uncertain") models keep the last known-good text,
//! except after undo which discards it.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Move {
    Left,
    Right,
    WordLeft,
    WordRight,
    LineStart,
    LineEnd,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    Text(String),
    Backspace,
    ForwardDelete,
    DeleteWord,
    DeleteLine,
    Move(Move, bool),
    SelectAll,
    Undo,
    Unsupported,
    /// A selection reported by the UI after a mouse selection, Ctrl+A or a shift-move past the pasted text.
    Select(Selection),
}

/// Shortest selected text trusted when the UI gave no range.
const MIN_TEXT_ONLY_SELECTION: usize = 4;

/// Selected text and/or its range. `start`/`end` are UTF-16 offsets relative to the start of the original paste
/// in the field (negative = before it); only set when the field value is readable. `via` is informational.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Selection {
    pub text: Option<String>,
    pub start: Option<i64>,
    pub end: Option<i64>,
    pub via: String,
}

impl Selection {
    /// From an absolute range in the field value: relative offsets only when the paste's start is known.
    pub fn from_abs(text: Option<String>, location: Option<i64>, length: Option<i64>, region_start: Option<i64>, via: &str) -> Option<Selection> {
        let mut s = Selection { text, start: None, end: None, via: via.into() };
        if let (Some(rs), Some(l), Some(n)) = (region_start, location, length) {
            if l >= 0 && n >= 0 {
                s.start = Some(l - rs);
                s.end = Some(l + n - rs);
            }
        }
        if s.text.is_none() && s.start.is_none() { None } else { Some(s) }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Counts {
    pub text: u32,
    pub delete: u32,
    pub nav: u32,
    pub mouse: u32,
    pub other: u32,
}

#[derive(Clone, Debug)]
pub struct ReplayModel {
    original: String,
    /// Characters of `original` before / after the paste (learned from selections crossing its boundary).
    lead: usize,
    trail: usize,
    /// UTF-16 offset of chars[0] relative to the start of the original paste (<= 0).
    origin: i64,
    chars: Vec<char>,
    cursor: usize,
    anchor: usize,
    pub frozen: Option<String>,
    discarded: bool,
    awaiting_caret: bool,
    queue: Vec<Event>,
    pub counts: Counts,
}

fn is_word(c: char) -> bool {
    c.is_alphanumeric() || c == '_' || c == '\'' || c == '\u{2019}'
}

impl ReplayModel {
    pub fn new(pasted: &str) -> Self {
        let chars: Vec<char> = pasted.chars().collect();
        let cursor = chars.len();
        ReplayModel {
            original: pasted.to_string(),
            lead: 0,
            trail: 0,
            origin: 0,
            chars,
            cursor,
            anchor: cursor,
            frozen: None,
            discarded: false,
            awaiting_caret: false,
            queue: vec![],
            counts: Counts::default(),
        }
    }

    /// The edited pasted text, or None when unchanged / discarded.
    pub fn result(&self) -> Option<String> {
        if self.discarded {
            return None;
        }
        let s: String = self.chars.iter().collect();
        if s == self.original { None } else { Some(s) }
    }

    /// What `result` is diffed against: the paste, extended by neighbouring text a selection revealed.
    pub fn base_text(&self) -> &str {
        &self.original
    }

    /// The candidate for the replayed edit. With neighbouring text in the base, the heard words must touch the
    /// paste itself.
    pub fn candidate(&self, dictionary: &[crate::dictionary::DictEntry], rejected: &std::collections::HashSet<String>) -> Option<crate::vocab::Candidate> {
        let r = self.result()?;
        let c = crate::vocab::candidate(&self.original, &r, dictionary, rejected)?;
        if self.lead == 0 && self.trail == 0 {
            return Some(c);
        }
        let base: Vec<char> = self.original.chars().collect();
        let h: Vec<char> = c.heard.chars().collect();
        if h.is_empty() || h.len() > base.len() {
            return None;
        }
        let (lo, hi) = (self.lead, base.len() - self.trail);
        let eq = |a: char, b: char| a == b || a.to_lowercase().eq(b.to_lowercase());
        for i in 0..=(base.len() - h.len()) {
            if (0..h.len()).all(|k| eq(base[i + k], h[k])) && i < hi && i + h.len() > lo {
                return Some(c);
            }
        }
        None
    }

    fn sel(&self) -> (usize, usize) {
        (self.anchor.min(self.cursor), self.anchor.max(self.cursor))
    }

    fn freeze(&mut self, kind: &str, discard: bool) {
        if self.frozen.is_none() {
            self.frozen = Some(kind.to_string());
        }
        if discard {
            self.discarded = true;
        }
        self.awaiting_caret = false;
        self.queue.clear();
    }

    fn word_left(&self, i: usize) -> usize {
        let mut j = i;
        while j > 0 && !is_word(self.chars[j - 1]) {
            j -= 1;
        }
        while j > 0 && is_word(self.chars[j - 1]) {
            j -= 1;
        }
        j
    }

    fn word_right(&self, i: usize) -> usize {
        let mut j = i;
        while j < self.chars.len() && !is_word(self.chars[j]) {
            j += 1;
        }
        while j < self.chars.len() && is_word(self.chars[j]) {
            j += 1;
        }
        j
    }

    fn is_nl(c: char) -> bool {
        matches!(c, '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    }

    fn line_start(&self, i: usize) -> Option<usize> {
        let mut j = i as isize - 1;
        while j >= 0 {
            if Self::is_nl(self.chars[j as usize]) {
                return Some(j as usize + 1);
            }
            j -= 1;
        }
        None
    }

    fn line_end(&self, i: usize) -> Option<usize> {
        (i..self.chars.len()).find(|&j| Self::is_nl(self.chars[j]))
    }

    fn replace_selection(&mut self, new: &[char]) {
        let (a, b) = self.sel();
        self.chars.splice(a..b, new.iter().copied());
        self.cursor = a + new.len();
        self.anchor = self.cursor;
    }

    fn delete_range(&mut self, a: usize, b: usize) {
        self.chars.drain(a..b);
        self.cursor = a;
        self.anchor = a;
    }

    pub fn apply(&mut self, e: Event) {
        if self.frozen.is_some() {
            return;
        }
        if self.awaiting_caret {
            self.queue.push(e);
            return;
        }
        let has_sel = {
            let (a, b) = self.sel();
            a != b
        };
        match e {
            Event::Text(s) => {
                self.counts.text += 1;
                let v: Vec<char> = s.chars().collect();
                self.replace_selection(&v);
            }
            Event::Backspace => {
                self.counts.delete += 1;
                if has_sel {
                    self.replace_selection(&[]);
                } else if self.cursor == 0 {
                    self.freeze("boundary", false);
                } else {
                    self.delete_range(self.cursor - 1, self.cursor);
                }
            }
            Event::ForwardDelete => {
                self.counts.delete += 1;
                if has_sel {
                    self.replace_selection(&[]);
                } else if self.cursor >= self.chars.len() {
                    self.freeze("boundary", false);
                } else {
                    self.delete_range(self.cursor, self.cursor + 1);
                }
            }
            Event::DeleteWord => {
                self.counts.delete += 1;
                if has_sel {
                    self.replace_selection(&[]);
                } else if self.cursor == 0 {
                    self.freeze("boundary", false);
                } else {
                    let w = self.word_left(self.cursor);
                    self.delete_range(w, self.cursor);
                }
            }
            Event::DeleteLine => {
                self.counts.delete += 1;
                if has_sel {
                    self.replace_selection(&[]);
                } else if let Some(s) = self.line_start(self.cursor).filter(|s| *s < self.cursor) {
                    self.delete_range(s, self.cursor);
                } else {
                    self.freeze("line-boundary", false);
                }
            }
            Event::Move(m, select) => {
                self.counts.nav += 1;
                let (lo, hi) = self.sel();
                let collapse = !select && has_sel;
                let target = match m {
                    Move::Left => if collapse { Some(lo) } else if self.cursor > 0 { Some(self.cursor - 1) } else { None },
                    Move::Right => if collapse { Some(hi) } else if self.cursor < self.chars.len() { Some(self.cursor + 1) } else { None },
                    Move::WordLeft => if collapse || self.cursor == 0 { None } else { Some(self.word_left(self.cursor)) },
                    Move::WordRight => if collapse || self.cursor >= self.chars.len() { None } else { Some(self.word_right(self.cursor)) },
                    Move::LineStart => self.line_start(if select { self.cursor } else { lo }),
                    Move::LineEnd => self.line_end(if select { self.cursor } else { hi }),
                };
                match target {
                    None => self.freeze("boundary", false),
                    Some(t) => {
                        self.cursor = t;
                        if !select {
                            self.anchor = t;
                        }
                    }
                }
            }
            Event::Select(sel) => {
                self.counts.nav += 1;
                self.select(&sel);
            }
            Event::SelectAll => {
                self.counts.other += 1;
                self.freeze("select-all", false);
            }
            Event::Undo => {
                self.counts.other += 1;
                self.freeze("undo", true);
            }
            Event::Unsupported => {
                self.counts.other += 1;
                self.freeze("unsupported", false);
            }
        }
    }

    fn char_index_utf16(&self, u: i64) -> Option<usize> {
        let mut acc: i64 = 0;
        for (i, c) in self.chars.iter().enumerate() {
            if acc == u {
                return Some(i);
            }
            if acc > u {
                return None;
            }
            acc += c.len_utf16() as i64;
        }
        if acc == u { Some(self.chars.len()) } else { None }
    }

    fn occurrences(t: &[char], hay: &[char]) -> Vec<usize> {
        if t.is_empty() || t.len() > hay.len() {
            return vec![];
        }
        (0..=(hay.len() - t.len())).filter(|&i| hay[i..i + t.len()] == *t).collect()
    }

    /// Splits `text` into UTF-16 prefix / middle / suffix; None when a cut falls inside a character.
    fn split(text: &str, before: usize, after: usize) -> Option<(Vec<char>, Vec<char>, Vec<char>)> {
        let u: Vec<u16> = text.encode_utf16().collect();
        if before + after > u.len() {
            return None;
        }
        let a = String::from_utf16(&u[..before]).ok()?;
        let b = String::from_utf16(&u[before..u.len() - after]).ok()?;
        let c = String::from_utf16(&u[u.len() - after..]).ok()?;
        Some((a.chars().collect(), b.chars().collect(), c.chars().collect()))
    }

    fn extend(&mut self, before: &[char], after: &[char]) {
        if !before.is_empty() {
            let b: String = before.iter().collect();
            self.chars.splice(0..0, before.iter().copied());
            self.original = format!("{b}{}", self.original);
            self.lead += before.len();
            self.origin -= b.encode_utf16().count() as i64;
            self.cursor += before.len();
            self.anchor += before.len();
        }
        if !after.is_empty() {
            self.chars.extend_from_slice(after);
            let a: String = after.iter().collect();
            self.original.push_str(&a);
            self.trail += after.len();
        }
    }

    /// Keeps the selection's direction (see ReplayModel.setSelection).
    fn set_selection(&mut self, lo: usize, hi: usize) {
        if lo != hi && self.anchor == hi {
            self.cursor = lo;
        } else {
            self.anchor = lo;
            self.cursor = hi;
        }
    }

    fn select(&mut self, s: &Selection) {
        if let (Some(a), Some(b)) = (s.start, s.end) {
            if a <= b {
                let (u0, u1) = (a - self.origin, b - self.origin);
                let total: i64 = self.chars.iter().map(|c| c.len_utf16() as i64).sum();
                if u1 < 0 || u0 > total || (u0 != u1 && (u1 <= 0 || u0 >= total)) {
                    self.freeze("select-outside", false);
                    return;
                }
                if u0 >= 0 && u1 <= total {
                    if let (Some(i0), Some(i1)) = (self.char_index_utf16(u0), self.char_index_utf16(u1)) {
                        let cur: String = self.chars[i0..i1].iter().collect();
                        if s.text.is_none() || s.text.as_deref() == Some(cur.as_str()) {
                            self.set_selection(i0, i1);
                            return;
                        }
                    }
                }
                // Crossing the boundary: the selected text supplies the neighbouring characters.
                if let Some(t) = &s.text {
                    if t.encode_utf16().count() as i64 == u1 - u0 && (u0 < 0 || u1 > total) {
                        if let Some((pre, mid, post)) = Self::split(t, (-u0).max(0) as usize, (u1 - total).max(0) as usize) {
                            if let (Some(i0), Some(i1)) = (self.char_index_utf16(u0.max(0)), self.char_index_utf16(u1.min(total))) {
                                if self.chars[i0..i1] == mid[..] && (pre.is_empty() || i0 == 0) && (post.is_empty() || i1 == self.chars.len()) {
                                    self.extend(&pre, &post);
                                    let start = if pre.is_empty() { i0 } else { 0 };
                                    self.set_selection(start, start + pre.len() + mid.len() + post.len());
                                    return;
                                }
                            }
                        }
                    }
                }
            }
        }
        let text = match &s.text {
            Some(t) if !t.is_empty() => t,
            _ => {
                self.freeze("select-unknown", false);
                return;
            }
        };
        let t: Vec<char> = text.chars().collect();
        let hits = Self::occurrences(&t, &self.chars);
        if !hits.is_empty() {
            // Without a range, a short or repeated text may have been selected elsewhere in the field ("the"):
            // only a unique occurrence of >= 4 characters is trusted, anything else is uncertain.
            if hits.len() != 1 || t.len() < MIN_TEXT_ONLY_SELECTION {
                self.freeze(if hits.len() > 1 { "select-ambiguous" } else { "select-short" }, false);
                return;
            }
            self.set_selection(hits[0], hits[0] + t.len());
            return;
        }
        let whole = Self::occurrences(&self.chars, &t);
        if whole.len() == 1 && !self.chars.is_empty() {
            let w = whole[0];
            let n = self.chars.len();
            let (pre, post) = (t[..w].to_vec(), t[w + n..].to_vec());
            self.extend(&pre, &post);
            let n2 = self.chars.len();
            self.set_selection(0, n2);
            return;
        }
        self.freeze(if whole.len() > 1 { "select-ambiguous" } else { "select-outside" }, false);
    }

    /// Starts a selection lookup (mouse-down, Ctrl+A, shift-move past the paste): keys queue until `resolve`.
    pub fn await_selection(&mut self) {
        if self.frozen.is_none() {
            self.awaiting_caret = true;
        }
    }

    pub fn awaiting(&self) -> bool {
        self.awaiting_caret
    }

    /// Applies the looked-up selection (it already reflects the triggering key), then the queued keys.
    pub fn resolve(&mut self, s: Option<Selection>, fallback: Option<Event>, fail_kind: &str) {
        if !self.awaiting_caret {
            return;
        }
        self.awaiting_caret = false;
        let q = std::mem::take(&mut self.queue);
        if let Some(s) = s {
            self.apply(Event::Select(s));
        } else if let Some(f) = fallback {
            self.apply(f);
        } else {
            self.freeze(fail_kind, false);
            return;
        }
        for e in q {
            self.apply(e);
        }
    }

    /// True when the model cannot place this selection itself and the learner should ask the UI for it.
    pub fn selection_needs_lookup(&self, e: &Event) -> bool {
        if self.frozen.is_some() || self.awaiting_caret {
            return false;
        }
        if *e == Event::SelectAll {
            return true;
        }
        match e {
            Event::Move(m, true) => match m {
                Move::Left | Move::WordLeft => self.cursor == 0,
                Move::Right | Move::WordRight => self.cursor >= self.chars.len(),
                Move::LineStart | Move::LineEnd => true,
            },
            _ => false,
        }
    }

    /// A click moves the caret somewhere unknown. With `lookup`, events queue until `resolve_caret`.
    pub fn mouse_down(&mut self, lookup: bool) {
        if self.frozen.is_some() {
            return;
        }
        self.counts.mouse += 1;
        if lookup {
            self.awaiting_caret = true;
        } else {
            self.freeze("mouse", false);
        }
    }

    /// Caret/selection read via UI Automation relative to the pasted text; None or out of range freezes.
    pub fn resolve_caret(&mut self, location: Option<usize>, length: usize) {
        if !self.awaiting_caret {
            return;
        }
        self.awaiting_caret = false;
        let q = std::mem::take(&mut self.queue);
        match location {
            Some(l) if l + length <= self.chars.len() => {
                self.anchor = l;
                self.cursor = l + length;
                for e in q {
                    self.apply(e);
                }
            }
            _ => self.freeze("mouse", false),
        }
    }

    pub fn summary(&self) -> String {
        format!(
            "text={} delete={} nav={} mouse={} other={} frozen={}",
            self.counts.text, self.counts.delete, self.counts.nav, self.counts.mouse, self.counts.other,
            self.frozen.as_deref().unwrap_or("no")
        )
    }
}

// Windows virtual-key codes used by `event_for_key`.
pub const VK_BACK: u32 = 0x08;
pub const VK_TAB: u32 = 0x09;
pub const VK_RETURN: u32 = 0x0D;
pub const VK_ESCAPE: u32 = 0x1B;
pub const VK_PRIOR: u32 = 0x21;
pub const VK_NEXT: u32 = 0x22;
pub const VK_END: u32 = 0x23;
pub const VK_HOME: u32 = 0x24;
pub const VK_LEFT: u32 = 0x25;
pub const VK_UP: u32 = 0x26;
pub const VK_RIGHT: u32 = 0x27;
pub const VK_DOWN: u32 = 0x28;
pub const VK_DELETE: u32 = 0x2E;

#[derive(Clone, Copy, Debug, Default)]
pub struct Mods {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub win: bool,
}

/// Maps a key press to a model event; None means "ignore" (harmless).
/// `chars` is the text the key produced (ToUnicode), empty for non-printing keys.
/// AltGr arrives as Ctrl+Alt; callers pass `Mods{ctrl:false,alt:false}` for it when `chars` is non-empty.
pub fn event_for_key(vk: u32, m: Mods, chars: &str) -> Option<Event> {
    match vk {
        VK_BACK => {
            return Some(if m.ctrl { Event::DeleteWord } else if m.alt || m.win { Event::Unsupported } else { Event::Backspace })
        }
        VK_DELETE => {
            return Some(if m.ctrl || m.alt || m.win { Event::Unsupported } else { Event::ForwardDelete })
        }
        VK_LEFT | VK_RIGHT => {
            if m.alt || m.win {
                return Some(Event::Unsupported);
            }
            let left = vk == VK_LEFT;
            let mv = if m.ctrl {
                if left { Move::WordLeft } else { Move::WordRight }
            } else if left {
                Move::Left
            } else {
                Move::Right
            };
            return Some(Event::Move(mv, m.shift));
        }
        VK_HOME | VK_END => {
            if m.ctrl || m.alt || m.win {
                return Some(Event::Unsupported);
            }
            return Some(Event::Move(if vk == VK_HOME { Move::LineStart } else { Move::LineEnd }, m.shift));
        }
        VK_UP | VK_DOWN | VK_PRIOR | VK_NEXT | VK_TAB | VK_ESCAPE => return Some(Event::Unsupported),
        VK_RETURN => {
            return Some(if m.shift && !m.ctrl && !m.alt { Event::Text("\n".into()) } else { Event::Unsupported })
        }
        0x41 if m.ctrl && !m.alt && !m.shift => return Some(Event::SelectAll), // Ctrl+A
        0x5A if m.ctrl => return Some(Event::Undo),                              // Ctrl+Z (and redo)
        0x59 if m.ctrl => return Some(Event::Undo),                              // Ctrl+Y
        0x43 if m.ctrl && !m.alt => return None,                                 // Ctrl+C
        _ => {}
    }
    if m.ctrl || m.alt || m.win || chars.is_empty() {
        return Some(Event::Unsupported);
    }
    if chars.chars().any(|c| (c as u32) < 0x20 || (0x7F..=0x9F).contains(&(c as u32))) {
        return Some(Event::Unsupported);
    }
    Some(Event::Text(chars.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vocab;
    use std::collections::HashSet;

    const P: &str = "take control of my collab tree tab";

    fn run(start: &str, evs: &[Event]) -> ReplayModel {
        let mut m = ReplayModel::new(start);
        for e in evs {
            m.apply(e.clone());
        }
        m
    }
    fn left(n: usize, sel: bool) -> Vec<Event> {
        vec![Event::Move(Move::Left, sel); n]
    }
    fn cat(mut a: Vec<Event>, b: Vec<Event>) -> Vec<Event> {
        a.extend(b);
        a
    }

    #[test]
    fn backspace_and_candidate() {
        let evs = cat(cat(left(4, false), vec![Event::Backspace; 11]), vec![Event::Text("Kolabtree".into())]);
        let m = run(P, &evs);
        assert_eq!(m.result().as_deref(), Some("take control of my Kolabtree tab"));
        assert!(m.frozen.is_none());
        let c = vocab::candidate(P, &m.result().unwrap(), &[], &HashSet::new());
        assert_eq!(vocab::describe(&c), "collab tree -> Kolabtree");
    }

    #[test]
    fn words_and_selection() {
        assert_eq!(run("send it to john", &[Event::DeleteWord, Event::Text("John".into())]).result().as_deref(), Some("send it to John"));
        assert_eq!(run("one two three", &[Event::Move(Move::WordLeft, false), Event::DeleteWord]).result().as_deref(), Some("one three"));
        let evs = cat(vec![Event::Move(Move::WordLeft, false); 3], vec![Event::Move(Move::WordRight, true), Event::Text("Kolab".into())]);
        assert_eq!(run(P, &evs).result().as_deref(), Some("take control of my Kolab tree tab"));
        let evs = cat(cat(left(4, false), left(11, true)), vec![Event::Text("Kolabtree".into())]);
        assert_eq!(run(P, &evs).result().as_deref(), Some("take control of my Kolabtree tab"));
        let m = run("abcd", &[Event::Move(Move::Left, false), Event::Move(Move::Left, false), Event::ForwardDelete, Event::Move(Move::Right, false), Event::Text("X".into())]);
        let r = m.result().unwrap();
        assert!(r == "abXd" || r == "abdX", "{r}");
    }

    #[test]
    fn freezing() {
        let m = run(P, &cat(left(4, false), vec![Event::Backspace, Event::Undo]));
        assert_eq!(m.frozen.as_deref(), Some("undo"));
        assert!(m.result().is_none());
        let evs = cat(vec![Event::Backspace, Event::Text("c".into())], cat(left(5, false), vec![Event::Text("zzz".into())]));
        let m = run("ab", &evs);
        assert_eq!(m.frozen.as_deref(), Some("boundary"));
        assert_eq!(m.result().as_deref(), Some("ac"));
        let m = run(P, &[Event::Backspace, Event::SelectAll, Event::Text("q".into())]);
        assert_eq!(m.frozen.as_deref(), Some("select-all"));
        assert_eq!(m.result().as_deref(), Some("take control of my collab tree ta"));
        let m = run("one two", &[Event::SelectAll, Event::Text("three".into())]);
        assert!(m.frozen.as_deref() == Some("select-all") && m.result().is_none());
        let m = run("abc", &[Event::Text("d".into()), Event::Undo, Event::Text("e".into())]);
        assert!(m.result().is_none() && m.frozen.as_deref() == Some("undo"));
        let m = run("abc", &[Event::Unsupported, Event::Text("x".into())]);
        assert!(m.frozen.as_deref() == Some("unsupported") && m.result().is_none());
    }

    #[test]
    fn lines() {
        assert_eq!(run("a\nb c", &[Event::Move(Move::LineStart, false), Event::Text("X".into())]).result().as_deref(), Some("a\nXb c"));
        let m = run("b c", &[Event::Move(Move::LineStart, false)]);
        assert!(matches!(m.frozen.as_deref(), Some("line-boundary") | Some("boundary")));
        assert_eq!(run("a\nb c", &[Event::DeleteLine, Event::Text("Z".into())]).result().as_deref(), Some("a\nZ"));
        assert_eq!(run("a\nbcd", &[Event::Move(Move::LineStart, true), Event::Text("X".into())]).result().as_deref(), Some("a\nX"));
        let evs = cat(left(3, false), vec![Event::Move(Move::LineEnd, false), Event::Text("!".into())]);
        assert_eq!(run("a\nbcd\ne", &evs).result().as_deref(), Some("a\nbcd!\ne"));
        let evs = vec![Event::Move(Move::WordLeft, true), Event::Move(Move::Left, false), Event::Text("_".into())];
        assert_eq!(run("hello world", &evs).result().as_deref(), Some("hello _world"));
        assert_eq!(run("don't stop", &[Event::DeleteWord, Event::DeleteWord]).result().as_deref(), Some(""));
        let evs = vec![Event::Move(Move::WordLeft, false), Event::Move(Move::WordLeft, true), Event::Text("B".into())];
        assert_eq!(run("alpha beta gamma", &evs).result().as_deref(), Some("alpha Bgamma"));
        let evs = vec![Event::Move(Move::WordLeft, true), Event::Move(Move::WordLeft, true), Event::Backspace];
        assert_eq!(run("alpha beta", &evs).result().as_deref(), Some(""));
    }

    #[test]
    fn mouse() {
        let mut m = ReplayModel::new("hello wrld");
        m.mouse_down(true);
        m.apply(Event::Text("o".into()));
        m.resolve_caret(Some(9), 0);
        assert_eq!(m.result().as_deref(), Some("hello wrlod"));
        let mut m = ReplayModel::new("hello wrld");
        m.mouse_down(true);
        m.apply(Event::Text("o".into()));
        m.resolve_caret(Some(8), 0);
        assert_eq!(m.result().as_deref(), Some("hello wrold"));
        let mut m = ReplayModel::new("hello");
        m.mouse_down(true);
        m.resolve_caret(Some(99), 0);
        assert_eq!(m.frozen.as_deref(), Some("mouse"));
        let mut m = ReplayModel::new("hello");
        m.mouse_down(false);
        assert_eq!(m.frozen.as_deref(), Some("mouse"));
    }

    #[test]
    fn key_mapping() {
        let none = Mods::default();
        assert_eq!(event_for_key(VK_BACK, Mods { ctrl: true, ..none }, ""), Some(Event::DeleteWord));
        assert_eq!(event_for_key(VK_BACK, none, ""), Some(Event::Backspace));
        assert_eq!(event_for_key(VK_RIGHT, Mods { ctrl: true, shift: true, ..none }, ""), Some(Event::Move(Move::WordRight, true)));
        assert_eq!(event_for_key(VK_END, Mods { shift: true, ..none }, ""), Some(Event::Move(Move::LineEnd, true)));
        assert_eq!(event_for_key(0x5A, Mods { ctrl: true, ..none }, "z"), Some(Event::Undo));
        assert_eq!(event_for_key(0x41, Mods { ctrl: true, ..none }, "a"), Some(Event::SelectAll));
        assert_eq!(event_for_key(0x4B, none, "k"), Some(Event::Text("k".into())));
        assert_eq!(event_for_key(VK_RETURN, none, "\r"), Some(Event::Unsupported));
        assert_eq!(event_for_key(0x56, Mods { ctrl: true, ..none }, "v"), Some(Event::Unsupported));
        assert_eq!(event_for_key(0x43, Mods { ctrl: true, ..none }, "c"), None);
    }
}
