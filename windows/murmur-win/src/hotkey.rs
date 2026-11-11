//! Global push-to-talk via a low-level keyboard hook (WH_KEYBOARD_LL) and a mouse hook for the learner.
//! Hold the key to dictate; Esc cancels; a double tap starts hands-free; pressing another key while a
//! modifier-style key is held cancels silently (it was a shortcut, not dictation).

use crate::util::log;
use crate::win32::{self, MAGIC};
use murmur_core::config::PttKey;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{HINSTANCE, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::*;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Cmd {
    Start,
    Stop,
    Cancel,
}

/// Events for the vocabulary learner (only forwarded while it is watching).
pub static LEARNING: AtomicBool = AtomicBool::new(false);
/// Set while the state lock is held; the actual SendInput happens after it is released.
static INJECT_DISARM: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Mode {
    Idle,
    Holding,
    HandsFree,
}

struct State {
    ptt: PttKey,
    mode: Mode,
    key_held: bool,
    ignore_release: bool,
    down_time: Instant,
    last_tap: Option<Instant>,
    down: [bool; 256],
    /// Set once a Win/Alt key took part in a chord, so its release can be disarmed (no Start menu / menu bar).
    disarm: bool,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);
static TX: OnceLock<Sender<Cmd>> = OnceLock::new();
static LEARNER_TX: OnceLock<Sender<crate::uia::LCmd>> = OnceLock::new();

const MIN_HOLD: Duration = Duration::from_millis(250);
const DOUBLE_TAP: Duration = Duration::from_millis(500);

const VK_LCTRL: usize = 0xA2;
const VK_RCTRL: usize = 0xA3;
const VK_LALT: usize = 0xA4;
const VK_RALT: usize = 0xA5;
const VK_LWIN: usize = 0x5B;
const VK_RWIN: usize = 0x5C;
const VK_ESC: usize = 0x1B;
const VK_SPACE: usize = 0x20;

fn is_modifier(vk: usize) -> bool {
    matches!(vk, 0xA0..=0xA5 | 0x5B | 0x5C | 0x10 | 0x11 | 0x12)
}

fn ptt_vk_set(k: &PttKey) -> Vec<usize> {
    match k {
        PttKey::RightCtrl => vec![VK_RCTRL],
        PttKey::CtrlWin => vec![VK_LCTRL, VK_RCTRL, VK_LWIN, VK_RWIN],
        PttKey::RightAlt => vec![VK_RALT],
        PttKey::F(n) => vec![0x70 + (*n as usize - 1)],
    }
}

fn is_modifier_style(k: &PttKey) -> bool {
    !matches!(k, PttKey::F(_))
}

impl State {
    fn ptt_held(&self) -> bool {
        match &self.ptt {
            PttKey::RightCtrl => self.down[VK_RCTRL],
            PttKey::CtrlWin => (self.down[VK_LCTRL] || self.down[VK_RCTRL]) && (self.down[VK_LWIN] || self.down[VK_RWIN]),
            PttKey::RightAlt => self.down[VK_RALT],
            PttKey::F(n) => self.down[0x70 + (*n as usize - 1)],
        }
    }
}

fn send(c: Cmd) {
    if let Some(tx) = TX.get() {
        let _ = tx.send(c);
    }
}

/// Core state machine (port of Hotkey.swift `setDown`).
fn set_down(st: &mut State, down: bool) {
    if down == st.key_held {
        return;
    }
    st.key_held = down;
    let now = Instant::now();
    log(&format!("hotkey {} mode={:?} ignoreRelease={}", if down { "down" } else { "up" }, st.mode, st.ignore_release));
    if down {
        match st.mode {
            Mode::HandsFree => {
                st.mode = Mode::Idle;
                st.ignore_release = true;
                send(Cmd::Stop);
            }
            Mode::Idle => {
                st.mode = Mode::Holding;
                st.down_time = now;
                send(Cmd::Start);
            }
            Mode::Holding => {}
        }
    } else {
        if st.ignore_release {
            st.ignore_release = false;
            return;
        }
        if st.mode != Mode::Holding {
            return;
        }
        if now - st.down_time < MIN_HOLD {
            if st.last_tap.map(|t| now - t < DOUBLE_TAP).unwrap_or(false) {
                log("hotkey -> handsFree (double tap)");
                st.mode = Mode::HandsFree;
                st.last_tap = None;
            } else {
                log("hotkey short hold -> cancel");
                st.mode = Mode::Idle;
                st.last_tap = Some(now);
                send(Cmd::Cancel);
            }
        } else {
            st.mode = Mode::Idle;
            send(Cmd::Stop);
        }
    }
}

/// Returns true when the event must be swallowed.
fn handle_key(vk: usize, down: bool, auto_repeat: bool) -> bool {
    let mut g = STATE.lock().unwrap();
    let Some(st) = g.as_mut() else { return false };
    if vk >= 256 {
        return false;
    }
    let was_down = st.down[vk];
    st.down[vk] = down;
    let auto_repeat = auto_repeat || (down && was_down);

    if down && vk == VK_ESC && st.mode != Mode::Idle {
        log("hotkey esc cancel");
        st.mode = Mode::Idle;
        st.ignore_release = st.key_held;
        send(Cmd::Cancel);
        return true;
    }
    if down && vk == VK_SPACE && st.key_held && st.mode == Mode::Holding {
        log("hotkey space -> handsFree");
        st.mode = Mode::HandsFree;
        return true;
    }

    let set = ptt_vk_set(&st.ptt);
    if set.contains(&vk) {
        let held = st.ptt_held();
        let uses_win_alt = matches!(st.ptt, PttKey::CtrlWin | PttKey::RightAlt);
        if held != st.key_held {
            if held && uses_win_alt {
                st.disarm = true;
            }
            set_down(st, held);
        }
        // Releasing Win/Alt after a chord would open the Start menu / menu bar: tap an unassigned key first.
        if !down && uses_win_alt && st.disarm && matches!(vk, VK_LWIN | VK_RWIN | VK_LALT | VK_RALT) {
            st.disarm = false;
            INJECT_DISARM.store(true, Ordering::Relaxed);
        }
        // F-keys are dedicated push-to-talk keys: swallow them (including auto-repeat).
        if let PttKey::F(_) = st.ptt {
            return true;
        }
        let _ = auto_repeat;
        return false;
    }

    if down && !is_modifier(vk) {
        if st.key_held && st.mode == Mode::Holding && is_modifier_style(&st.ptt) {
            log(&format!("hotkey combo with key {vk:#x} -> cancel silently"));
            st.mode = Mode::Idle;
            st.ignore_release = true;
            send(Cmd::Cancel);
        }
    }
    false
}

fn forward_key_to_learner(vk: u32, down: bool, scan: u32) {
    if !down || !LEARNING.load(Ordering::Relaxed) {
        return;
    }
    let Some(tx) = LEARNER_TX.get() else { return };
    let mods = {
        let g = STATE.lock().unwrap();
        match g.as_ref() {
            Some(st) => crate::uia::KeyMods {
                ctrl: st.down[VK_LCTRL] || st.down[VK_RCTRL],
                alt: st.down[VK_LALT] || st.down[VK_RALT],
                shift: st.down[0xA0] || st.down[0xA1],
                win: st.down[VK_LWIN] || st.down[VK_RWIN],
            },
            None => return,
        }
    };
    let chars = crate::uia::key_chars(vk, scan);
    let _ = tx.send(crate::uia::LCmd::Key { vk, mods, chars });
}

unsafe extern "system" fn kb_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let k = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        if k.dwExtraInfo != MAGIC {
            let msg = wparam.0 as u32;
            let down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
            let up = msg == WM_KEYUP || msg == WM_SYSKEYUP;
            if down || up {
                let vk = k.vkCode as usize;
                // AltGr arrives as a fake LCtrl (scan 0x21D) followed by RAlt; ignore the fake one.
                let fake_ctrl = vk == VK_LCTRL && k.scanCode == 0x21D;
                if !fake_ctrl {
                    let swallow = handle_key(vk, down, false);
                    if INJECT_DISARM.swap(false, Ordering::Relaxed) {
                        win32::send(&[win32::key_input(0xE8, false), win32::key_input(0xE8, true)]);
                    }
                    if !swallow {
                        forward_key_to_learner(vk as u32, down, k.scanCode);
                    }
                    if swallow {
                        return LRESULT(1);
                    }
                }
            }
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

unsafe extern "system" fn mouse_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 && LEARNING.load(Ordering::Relaxed) {
        let msg = wparam.0 as u32;
        if msg == WM_LBUTTONDOWN || msg == WM_RBUTTONDOWN {
            if let Some(tx) = LEARNER_TX.get() {
                let _ = tx.send(crate::uia::LCmd::Mouse);
            }
        } else if msg == WM_LBUTTONUP || msg == WM_RBUTTONUP {
            if let Some(tx) = LEARNER_TX.get() {
                let _ = tx.send(crate::uia::LCmd::MouseUp);
            }
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

pub fn set_key(k: PttKey) {
    let mut g = STATE.lock().unwrap();
    if let Some(st) = g.as_mut() {
        if st.mode != Mode::Idle {
            send(Cmd::Cancel);
        }
        st.ptt = k;
        st.mode = Mode::Idle;
        st.key_held = false;
        st.ignore_release = false;
    }
}

/// Called by the controller when a session ends on its own (e.g. microphone failure).
pub fn reset() {
    let mut g = STATE.lock().unwrap();
    if let Some(st) = g.as_mut() {
        st.mode = Mode::Idle;
        st.ignore_release = st.key_held;
    }
}

/// Installs the hooks on the calling thread (which must run a message loop).
pub fn install(key: PttKey, tx: Sender<Cmd>, learner: Sender<crate::uia::LCmd>) -> Result<(), String> {
    *STATE.lock().unwrap() = Some(State {
        ptt: key,
        mode: Mode::Idle,
        key_held: false,
        ignore_release: false,
        down_time: Instant::now(),
        last_tap: None,
        down: [false; 256],
        disarm: false,
    });
    let _ = TX.set(tx);
    let _ = LEARNER_TX.set(learner);
    unsafe {
        let hi: HINSTANCE = GetModuleHandleW(None).map_err(|e| e.to_string())?.into();
        SetWindowsHookExW(WH_KEYBOARD_LL, Some(kb_proc), hi, 0).map_err(|e| format!("keyboard hook failed: {e}"))?;
        if let Err(e) = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_proc), hi, 0) {
            log(&format!("mouse hook failed: {e}"));
        }
    }
    Ok(())
}
