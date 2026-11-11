//! Context probe + vocabulary learner on a dedicated COM thread (UI Automation).
//! After a paste the learner watches the focused field: UIA value diff (exact, then fuzzy for terminals),
//! with the keystroke-replay model as the fallback where UIA cannot read the field.

use crate::hotkey::LEARNING;
use crate::util::{load_dictionary, log};
use crate::win32;
use murmur_core::replay::{event_for_key, Event, Mods, ReplayModel};
use murmur_core::vocab::{self, Candidate};
use std::collections::HashSet;
use std::sync::atomic::Ordering;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};
use windows::core::Interface;
use windows::Win32::System::Com::*;
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::GetWindowThreadProcessId;

pub const MAX_CHARS: usize = 50_000;
const WATCH_SECS: u64 = 45;
const DEBOUNCE: Duration = Duration::from_millis(2500);
const FOCUS_GRACE: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, Default)]
pub struct KeyMods {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub win: bool,
}

pub enum LCmd {
    Pasted { text: String, exe: String },
    Key { vk: u32, mods: KeyMods, chars: String },
    Mouse,
    Stop,
    /// Text before the caret in the focused field.
    Probe(Sender<String>),
}

/// Characters a key press produces in the active layout (empty for non-printing keys).
pub fn key_chars(vk: u32, scan: u32) -> String {
    unsafe {
        let mut state = [0u8; 256];
        let set = |s: &mut [u8; 256], vk: usize, on: bool| {
            if on {
                s[vk] = 0x80;
            }
        };
        let shift = win32::is_down(0xA0) || win32::is_down(0xA1);
        let ctrl = win32::is_down(0xA2) || win32::is_down(0xA3);
        let alt = win32::is_down(0xA4) || win32::is_down(0xA5);
        set(&mut state, 0x10, shift);
        set(&mut state, 0xA0, win32::is_down(0xA0));
        set(&mut state, 0xA1, win32::is_down(0xA1));
        set(&mut state, 0x11, ctrl);
        set(&mut state, 0x12, alt);
        if GetKeyState(0x14) & 1 != 0 {
            state[0x14] = 1;
        }
        let (fg, _) = win32::foreground();
        let tid = GetWindowThreadProcessId(fg, None);
        let hkl = GetKeyboardLayout(tid);
        let mut buf = [0u16; 8];
        // Flag 0x4: do not change the keyboard state (dead keys), Windows 10 1607+.
        let n = ToUnicodeEx(vk, scan, &state, &mut buf, 0x4, hkl);
        if n > 0 { String::from_utf16_lossy(&buf[..n as usize]) } else { String::new() }
    }
}

// ---- UI Automation -----------------------------------------------------------------------------

pub struct Field {
    /// Text with "\r\n" normalized to "\n".
    pub text: String,
    /// Caret/selection start as a UTF-16 offset into `text`.
    pub caret: Option<usize>,
    pub password: bool,
}

pub struct Uia {
    auto: IUIAutomation,
}

fn utf16_len(s: &str) -> usize {
    s.encode_utf16().count()
}

impl Uia {
    pub fn new() -> Option<Uia> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let auto: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok()?;
            Some(Uia { auto })
        }
    }

    pub fn focused(&self) -> Option<IUIAutomationElement> {
        unsafe { self.auto.GetFocusedElement().ok() }
    }

    pub fn same(&self, a: &IUIAutomationElement, b: &IUIAutomationElement) -> bool {
        unsafe { self.auto.CompareElements(a, b).map(|v| v.as_bool()).unwrap_or(false) }
    }

    pub fn read(&self, el: &IUIAutomationElement) -> Option<Field> {
        unsafe {
            if el.CurrentIsPassword().map(|b| b.as_bool()).unwrap_or(false) {
                return Some(Field { text: String::new(), caret: None, password: true });
            }
            if let Ok(unk) = el.GetCurrentPattern(UIA_TextPatternId) {
                if let Ok(tp) = unk.cast::<IUIAutomationTextPattern>() {
                    if let Ok(doc) = tp.DocumentRange() {
                        if let Ok(t) = doc.GetText((MAX_CHARS + 1) as i32) {
                            let raw = t.to_string();
                            if raw.chars().count() > MAX_CHARS {
                                return None;
                            }
                            let mut caret = None;
                            if let Ok(sel) = tp.GetSelection() {
                                if sel.Length().unwrap_or(0) > 0 {
                                    if let (Ok(r), Ok(pre)) = (sel.GetElement(0), doc.Clone()) {
                                        if pre
                                            .MoveEndpointByRange(TextPatternRangeEndpoint_End, &r, TextPatternRangeEndpoint_Start)
                                            .is_ok()
                                        {
                                            if let Ok(p) = pre.GetText((MAX_CHARS + 1) as i32) {
                                                caret = Some(utf16_len(&p.to_string().replace("\r\n", "\n")));
                                            }
                                        }
                                    }
                                }
                            }
                            return Some(Field { text: raw.replace("\r\n", "\n"), caret, password: false });
                        }
                    }
                }
            }
            if let Ok(unk) = el.GetCurrentPattern(UIA_ValuePatternId) {
                if let Ok(vp) = unk.cast::<IUIAutomationValuePattern>() {
                    if let Ok(v) = vp.CurrentValue() {
                        let raw = v.to_string();
                        if raw.chars().count() > MAX_CHARS {
                            return None;
                        }
                        return Some(Field { text: raw.replace("\r\n", "\n"), caret: None, password: false });
                    }
                }
            }
            None
        }
    }

    pub fn pid(&self, el: &IUIAutomationElement) -> u32 {
        unsafe { el.CurrentProcessId().unwrap_or(0) as u32 }
    }
}

/// Text before the caret (empty when unknown).
fn before_caret(f: &Field) -> String {
    let Some(c) = f.caret else { return String::new() };
    let u: Vec<u16> = f.text.encode_utf16().collect();
    let end = c.min(u.len());
    let start = end.saturating_sub(200);
    String::from_utf16_lossy(&u[start..end])
}

/// Debug/CI helper: prints the focused element's text via UI Automation.
pub fn read_focused_text() -> Option<String> {
    let u = Uia::new()?;
    let el = u.focused()?;
    u.read(&el).map(|f| f.text)
}

// ---- learner -----------------------------------------------------------------------------------

struct Watch {
    pasted: String,
    exe: String,
    pid: u32,
    element: Option<IUIAutomationElement>,
    snapshot: String,
    last_value: String,
    /// Pasted region in UTF-16 offsets of `snapshot`.
    region: Option<(usize, usize)>,
    dirty_at: Option<Instant>,
    started: Instant,
    focus_lost_since: Option<Instant>,
    replay: ReplayModel,
    attempts: Vec<Instant>,
    resolved: bool,
    pending_mouse: Option<Instant>,
}

fn find_region(value: &str, text: &str, caret: Option<usize>) -> Option<(usize, usize)> {
    let len = utf16_len(text);
    let v: Vec<u16> = value.encode_utf16().collect();
    let t: Vec<u16> = text.encode_utf16().collect();
    if let Some(loc) = caret {
        if loc >= len && loc <= v.len() && v[loc - len..loc] == t[..] {
            return Some((loc - len, loc));
        }
    }
    let i = value.rfind(text)?;
    let start = utf16_len(&value[..i]);
    Some((start, start + len))
}

fn pending_watch(text: &str, exe: &str, pid: u32) -> Watch {
    let now = Instant::now();
    Watch {
        pasted: text.to_string(),
        exe: exe.to_string(),
        pid,
        element: None,
        snapshot: String::new(),
        last_value: String::new(),
        region: None,
        dirty_at: None,
        started: now,
        focus_lost_since: None,
        replay: ReplayModel::new(text),
        attempts: [150u64, 500, 1000, 2000].iter().map(|ms| now + Duration::from_millis(*ms)).collect(),
        resolved: false,
        pending_mouse: None,
    }
}

fn stop(w: &mut Option<Watch>) {
    if let Some(x) = w.take() {
        log(&format!("learn: stop; replay {}", x.replay.summary()));
    }
    LEARNING.store(false, Ordering::Relaxed);
}

fn begin(uia: &Uia, w: &mut Watch, last: bool) -> bool {
    // true = done (found, replay-only, or aborted)
    let (_, fpid) = win32::foreground();
    if fpid != w.pid {
        return true;
    }
    let focused = uia.focused();
    if let Some(el) = focused {
        if let Some(f) = uia.read(&el) {
            if f.password {
                w.replay = ReplayModel::new("");
                w.resolved = true;
                w.pasted.clear();
                return true;
            }
            let region = find_region(&f.text, &w.pasted, f.caret);
            let fuzzy_ok = region.is_none() && vocab::fuzzy_contains(&w.pasted, &f.text);
            if region.is_some() || fuzzy_ok {
                w.element = Some(el);
                w.snapshot = f.text.clone();
                w.last_value = f.text;
                w.region = region;
                w.resolved = true;
                log(&format!("learn: uia readable exact={}", region.is_some()));
                return true;
            }
        }
    }
    if last {
        log("learn: uia unreadable, replay-only");
        w.resolved = true;
        return true;
    }
    false
}

fn evaluate(uia: &Uia, w: &Watch, final_: bool) -> Option<(Candidate, &'static str)> {
    let dict = load_dictionary();
    let rej: HashSet<String> = crate::app::config().rejected_pairs.into_iter().collect();
    let mut ax_now = None;
    if let Some(el) = &w.element {
        if let Some(f) = uia.read(el) {
            ax_now = Some(f.text);
        }
    }
    let replay_text = w.replay.result();
    let _ = final_;
    if let Some(v) = &ax_now {
        if let Some((rs, re)) = w.region {
            if let Some((o, n)) = vocab::edited_region(&w.snapshot, v, rs, re) {
                if utf16_len(&n) <= utf16_len(&o) * 3 + 200 {
                    if let Some(c) = vocab::candidate(&o, &n, &dict, &rej) {
                        return Some((c, "uia-exact"));
                    }
                }
            }
        }
        if *v != w.snapshot {
            if let Some(c) = vocab::fuzzy_candidate(&w.pasted, v, &dict, &rej) {
                return Some((c, "uia-fuzzy"));
            }
        }
    }
    if let Some(r) = replay_text {
        if let Some(c) = vocab::candidate(&w.pasted, &r, &dict, &rej) {
            return Some((c, "replay"));
        }
    }
    None
}

struct Learner {
    uia: Option<Uia>,
    watch: Option<Watch>,
    last_suggested: Option<(String, Instant)>,
}

impl Learner {
    fn suggest(&mut self, c: Candidate, tier: &str) {
        let key = format!("{}->{}", c.heard.to_lowercase(), c.wanted);
        if let Some((k, at)) = &self.last_suggested {
            if *k == key && at.elapsed() < Duration::from_secs(60) {
                return;
            }
        }
        self.last_suggested = Some((key, Instant::now()));
        log(&format!("learn: tier={tier} suggest {} -> {}", c.heard, c.wanted));
        crate::app::log_vocab_event("vocab-suggest", &c.heard, &c.wanted, &self.watch.as_ref().map(|w| w.exe.clone()).unwrap_or_default());
        crate::ui::post(crate::ui::UiCmd::Suggest { heard: c.heard, wanted: c.wanted });
    }

    fn tick(&mut self) {
        let Some(uia) = &self.uia else { return };
        let Some(w) = self.watch.as_mut() else { return };
        let now = Instant::now();
        // Locate the field: retry at 0.15 / 0.5 / 1 / 2 s.
        if !w.resolved {
            if let Some(at) = w.attempts.first().copied() {
                if now >= at {
                    w.attempts.remove(0);
                    let last = w.attempts.is_empty();
                    begin(uia, w, last);
                    if w.pasted.is_empty() {
                        stop(&mut self.watch);
                        return;
                    }
                }
            }
        }
        // A click moved the caret: resolve it from UIA shortly after.
        if let Some(at) = w.pending_mouse {
            if now >= at {
                w.pending_mouse = None;
                let loc = match (&w.element, w.region) {
                    (Some(el), Some((rs, _))) => uia.read(el).and_then(|f| f.caret).and_then(|c| c.checked_sub(rs)),
                    _ => None,
                };
                w.replay.resolve_caret(loc, 0);
            }
        }
        let (_, fpid) = win32::foreground();
        if w.started.elapsed() > Duration::from_secs(WATCH_SECS) || fpid != w.pid {
            self.finish();
            return;
        }
        if let Some(el) = &w.element {
            match uia.focused() {
                Some(cur) if uia.same(&cur, el) => {
                    w.focus_lost_since = None;
                    if let Some(f) = uia.read(el) {
                        if f.password {
                            stop(&mut self.watch);
                            return;
                        }
                        if f.text != w.last_value {
                            w.last_value = f.text;
                            w.dirty_at = Some(now);
                        }
                    }
                }
                other => {
                    if let Some(c) = other {
                        if uia.read(&c).map(|f| f.password).unwrap_or(false) {
                            stop(&mut self.watch);
                            return;
                        }
                    }
                    let since = *w.focus_lost_since.get_or_insert(now);
                    if now - since > FOCUS_GRACE {
                        self.finish();
                        return;
                    }
                }
            }
        }
        let w = self.watch.as_mut().unwrap();
        if let Some(d) = w.dirty_at {
            if now - d >= DEBOUNCE {
                w.dirty_at = None;
                if let Some((c, tier)) = evaluate(uia, w, false) {
                    self.suggest(c, tier);
                    stop(&mut self.watch);
                }
            }
        }
    }

    /// Ends the watch, evaluating once if there are pending edits.
    fn finish(&mut self) {
        if let (Some(uia), Some(w)) = (&self.uia, &self.watch) {
            if let Some((c, tier)) = evaluate(uia, w, true) {
                self.suggest(c, tier);
            }
        }
        stop(&mut self.watch);
    }

    fn cmd(&mut self, c: LCmd) {
        match c {
            LCmd::Pasted { text, exe } => {
                stop(&mut self.watch);
                if !crate::app::config().learn_vocab || text.is_empty() {
                    return;
                }
                let (_, pid) = win32::foreground();
                if pid == 0 {
                    return;
                }
                log(&format!("learn: watching app={exe} len={}", text.chars().count()));
                self.watch = Some(pending_watch(&text, &exe, pid));
                LEARNING.store(true, Ordering::Relaxed);
            }
            LCmd::Key { vk, mut mods, chars } => {
                let Some(w) = self.watch.as_mut() else { return };
                let (_, fpid) = win32::foreground();
                if fpid != w.pid {
                    w.replay.apply(Event::Unsupported);
                    return;
                }
                if mods.ctrl && mods.alt && !chars.is_empty() {
                    mods.ctrl = false; // AltGr
                    mods.alt = false;
                }
                if let Some(e) = event_for_key(vk, Mods { ctrl: mods.ctrl, alt: mods.alt, shift: mods.shift, win: mods.win }, &chars) {
                    w.replay.apply(e);
                    w.dirty_at = Some(Instant::now());
                }
            }
            LCmd::Mouse => {
                let Some(w) = self.watch.as_mut() else { return };
                w.dirty_at = Some(Instant::now());
                if w.element.is_none() || w.region.is_none() {
                    w.replay.mouse_down(false);
                } else {
                    w.replay.mouse_down(true);
                    w.pending_mouse = Some(Instant::now() + Duration::from_millis(120));
                }
            }
            LCmd::Stop => stop(&mut self.watch),
            LCmd::Probe(reply) => {
                let before = match &self.uia {
                    Some(u) => u
                        .focused()
                        .and_then(|el| u.read(&el))
                        .filter(|f| !f.password)
                        .map(|f| before_caret(&f))
                        .unwrap_or_default(),
                    None => String::new(),
                };
                let _ = reply.send(before);
            }
        }
    }
}

pub fn spawn() -> Sender<LCmd> {
    let (tx, rx): (Sender<LCmd>, Receiver<LCmd>) = channel();
    std::thread::spawn(move || {
        let mut l = Learner { uia: Uia::new(), watch: None, last_suggested: None };
        if l.uia.is_none() {
            log("learn: UI Automation unavailable");
        }
        loop {
            match rx.recv_timeout(Duration::from_millis(250)) {
                Ok(c) => l.cmd(c),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => break,
            }
            l.tick();
        }
    });
    tx
}
