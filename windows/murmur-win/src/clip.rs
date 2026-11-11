//! Clipboard paste with restore: set text, send Ctrl+V, restore the previous clipboard contents.

use crate::util::{log, wide};
use crate::win32;
use std::time::{Duration, Instant};
use windows::core::PCWSTR;
use windows::Win32::Foundation::{HANDLE, HGLOBAL, HWND};
use windows::Win32::System::DataExchange::*;
use windows::Win32::System::Memory::*;

const CF_UNICODETEXT: u32 = 13;

/// (format, bytes) snapshot of memory-backed clipboard formats. GDI-handle formats (bitmaps, metafiles,
/// palettes) are skipped: Windows re-synthesizes them from CF_DIB / CF_DIBV5.
type Snapshot = Vec<(u32, Vec<u8>)>;

fn open_clipboard() -> bool {
    for _ in 0..20 {
        if unsafe { OpenClipboard(HWND::default()) }.is_ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(15));
    }
    false
}

fn skippable(fmt: u32) -> bool {
    matches!(fmt, 2 | 3 | 9 | 14 | 0x80 | 0x81..=0x8E | 0x200..=0x3FF)
}

fn snapshot() -> Snapshot {
    let mut out = vec![];
    unsafe {
        let mut fmt = EnumClipboardFormats(0);
        while fmt != 0 {
            if !skippable(fmt) {
                if let Ok(h) = GetClipboardData(fmt) {
                    let g = HGLOBAL(h.0);
                    let size = GlobalSize(g);
                    if size > 0 && size < 64 * 1024 * 1024 {
                        let p = GlobalLock(g) as *const u8;
                        if !p.is_null() {
                            out.push((fmt, std::slice::from_raw_parts(p, size).to_vec()));
                        }
                        let _ = GlobalUnlock(g);
                    }
                }
            }
            fmt = EnumClipboardFormats(fmt);
        }
    }
    out
}

unsafe fn put(fmt: u32, bytes: &[u8]) -> bool {
    let Ok(g) = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1)) else { return false };
    let p = GlobalLock(g) as *mut u8;
    if p.is_null() {
        return false;
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), p, bytes.len());
    let _ = GlobalUnlock(g);
    // On success the clipboard owns the memory.
    SetClipboardData(fmt, HANDLE(g.0)).is_ok()
}

fn fmt_named(name: &str) -> u32 {
    let w = wide(name);
    unsafe { RegisterClipboardFormatW(PCWSTR(w.as_ptr())) }
}

/// Puts `text` on the clipboard, marked so Windows clipboard history / cloud sync skip it.
fn set_text(text: &str) -> bool {
    if !open_clipboard() {
        return false;
    }
    let ok = unsafe {
        let _ = EmptyClipboard();
        let mut bytes: Vec<u8> = text.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        bytes.extend_from_slice(&[0, 0]);
        let ok = put(CF_UNICODETEXT, &bytes);
        let _ = put(fmt_named("ExcludeClipboardContentFromMonitorProcessing"), &1u32.to_le_bytes());
        let _ = put(fmt_named("CanIncludeInClipboardHistory"), &0u32.to_le_bytes());
        let _ = put(fmt_named("CanUploadToCloudClipboard"), &0u32.to_le_bytes());
        ok
    };
    unsafe {
        let _ = CloseClipboard();
    }
    ok
}

fn restore(snap: &Snapshot) {
    if !open_clipboard() {
        return;
    }
    unsafe {
        let _ = EmptyClipboard();
        for (fmt, bytes) in snap {
            let _ = put(*fmt, bytes);
        }
        let _ = CloseClipboard();
    }
}

/// Waits (briefly) until the push-to-talk modifiers are physically released so Ctrl+V is not mangled.
fn wait_modifiers_up() {
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_millis(600) {
        if !(win32::is_down(0xA3) || win32::is_down(0xA2) || win32::is_down(0x5B) || win32::is_down(0x5C) || win32::is_down(0xA5) || win32::is_down(0xA4)) {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Pastes `text` into the focused window and restores the previous clipboard afterwards.
pub fn paste(text: &str, after_send: impl FnOnce()) -> bool {
    wait_modifiers_up();
    let snap = if open_clipboard() {
        let s = snapshot();
        unsafe {
            let _ = CloseClipboard();
        }
        s
    } else {
        vec![]
    };
    if !set_text(text) {
        log("paste: could not set clipboard");
        return false;
    }
    let seq = unsafe { GetClipboardSequenceNumber() };
    std::thread::sleep(Duration::from_millis(20));
    win32::send(&[
        win32::key_input(0xA2, false),
        win32::key_input(0x56, false),
        win32::key_input(0x56, true),
        win32::key_input(0xA2, true),
    ]);
    log("paste: Ctrl+V sent");
    after_send();
    // Restore after the target has had time to read the clipboard; skip if the user copied something meanwhile.
    std::thread::sleep(Duration::from_millis(900));
    if unsafe { GetClipboardSequenceNumber() } == seq {
        restore(&snap);
    }
    true
}
