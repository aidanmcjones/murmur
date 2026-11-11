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
                    Move::LineStart => self.line_start(self.cursor),
                    Move::LineEnd => self.line_end(self.cursor),
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
