//! Tray icon + menu, the recording overlay and the vocabulary suggestion pop-up, all on the main thread.
//! Other threads talk to it through `post()`.

use crate::util::{log, wide};
use murmur_core::config::PttKey;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicIsize, AtomicU8, Ordering};
use std::sync::Mutex;
use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};
use windows::core::PCWSTR;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::GetDpiForSystem;
use windows::Win32::UI::WindowsAndMessaging::*;

pub enum UiCmd {
    Listening,
    Transcribing,
    Toast(String),
    Hide,
    Suggest { heard: String, wanted: String },
}

static QUEUE: Mutex<VecDeque<UiCmd>> = Mutex::new(VecDeque::new());
static MENU_QUEUE: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());
static MAIN: AtomicIsize = AtomicIsize::new(0);
static OVERLAY: AtomicIsize = AtomicIsize::new(0);
static SUGGEST: AtomicIsize = AtomicIsize::new(0);
static OVERLAY_KIND: AtomicU8 = AtomicU8::new(0); // 0 hidden, 1 listening, 2 busy, 3 toast
static OVERLAY_TEXT: Mutex<String> = Mutex::new(String::new());
static SUGGESTION: Mutex<Option<(String, String)>> = Mutex::new(None);

const WM_UI: u32 = WM_APP + 1;
const WM_MENU: u32 = WM_APP + 2;
const TIMER_OVERLAY: usize = 1;
const TIMER_TOAST: usize = 2;
const TIMER_SUGGEST: usize = 3;

pub fn post(c: UiCmd) {
    QUEUE.lock().unwrap().push_back(c);
    let h = MAIN.load(Ordering::Relaxed);
    if h != 0 {
        unsafe {
            let _ = PostMessageW(HWND(h as *mut _), WM_UI, WPARAM(0), LPARAM(0));
        }
    }
}

fn scale() -> f32 {
    unsafe { GetDpiForSystem() as f32 / 96.0 }
}

fn rgb(r: u8, g: u8, b: u8) -> COLORREF {
    COLORREF(r as u32 | (g as u32) << 8 | (b as u32) << 16)
}

fn work_area() -> RECT {
    let mut r = RECT { left: 0, top: 0, right: 1280, bottom: 720 };
    unsafe {
        let _ = SystemParametersInfoW(SPI_GETWORKAREA, 0, Some(&mut r as *mut RECT as *mut _), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0));
    }
    r
}

fn font(px: i32, weight: i32) -> HFONT {
    let mut lf = LOGFONTW::default();
    lf.lfHeight = -px;
    lf.lfWeight = weight;
    let face = wide("Segoe UI");
    for (i, c) in face.iter().take(31).enumerate() {
        lf.lfFaceName[i] = *c;
    }
    unsafe { CreateFontIndirectW(&lf) }
}

fn draw_text(hdc: HDC, text: &str, mut r: RECT, flags: DRAW_TEXT_FORMAT) {
    let mut t: Vec<u16> = text.encode_utf16().collect();
    unsafe {
        DrawTextW(hdc, &mut t, &mut r, flags);
    }
}

fn fill(hdc: HDC, r: &RECT, c: COLORREF) {
    unsafe {
        let b = CreateSolidBrush(c);
        FillRect(hdc, r, b);
        let _ = DeleteObject(b);
    }
}

fn disc(hdc: HDC, cx: i32, cy: i32, rad: i32, c: COLORREF) {
    unsafe {
        let b = CreateSolidBrush(c);
        let p = CreatePen(PS_NULL, 0, c);
        let ob = SelectObject(hdc, b);
        let op = SelectObject(hdc, p);
        let _ = Ellipse(hdc, cx - rad, cy - rad, cx + rad, cy + rad);
        SelectObject(hdc, ob);
        SelectObject(hdc, op);
        let _ = DeleteObject(b);
        let _ = DeleteObject(p);
    }
}

// ---- overlay ------------------------------------------------------------------------------------

unsafe extern "system" fn overlay_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_MOUSEACTIVATE => LRESULT(3), // MA_NOACTIVATE
        WM_NCHITTEST => LRESULT(-1),    // HTTRANSPARENT: clicks fall through
        WM_TIMER => {
            if wp.0 == TIMER_OVERLAY {
                let _ = InvalidateRect(hwnd, None, false);
            } else if wp.0 == TIMER_TOAST {
                hide_overlay();
            }
            LRESULT(0)
        }
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let hdc = BeginPaint(hwnd, &mut ps);
            let mut rc = RECT::default();
            let _ = GetClientRect(hwnd, &mut rc);
            let s = scale();
            fill(hdc, &rc, rgb(28, 28, 32));
            let kind = OVERLAY_KIND.load(Ordering::Relaxed);
            let dot = match kind {
                1 => rgb(235, 64, 52),
                2 => rgb(250, 190, 40),
                _ => rgb(120, 170, 255),
            };
            disc(hdc, (20.0 * s) as i32, rc.bottom / 2, (6.0 * s) as i32, dot);
            let f = font((15.0 * s) as i32, 500);
            let of = SelectObject(hdc, f);
            SetBkMode(hdc, TRANSPARENT);
            SetTextColor(hdc, rgb(240, 240, 240));
            let text = OVERLAY_TEXT.lock().unwrap().clone();
            let tr = RECT { left: (36.0 * s) as i32, top: 0, right: rc.right - (10.0 * s) as i32, bottom: rc.bottom };
            draw_text(hdc, &text, tr, DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_END_ELLIPSIS);
            SelectObject(hdc, of);
            let _ = DeleteObject(f);
            if kind == 1 {
                let lvl = f32::from_bits(crate::audio::LEVEL.load(Ordering::Relaxed)).clamp(0.0, 1.0).sqrt();
                let full = rc.right - (36.0 * s) as i32 - (12.0 * s) as i32;
                let bar = RECT {
                    left: (36.0 * s) as i32,
                    top: rc.bottom - (9.0 * s) as i32,
                    right: (36.0 * s) as i32 + (full as f32 * lvl) as i32,
                    bottom: rc.bottom - (6.0 * s) as i32,
                };
                fill(hdc, &bar, rgb(235, 64, 52));
            }
            let _ = EndPaint(hwnd, &ps);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn show_overlay(kind: u8, text: &str, toast_ms: u32) {
    OVERLAY_KIND.store(kind, Ordering::Relaxed);
    *OVERLAY_TEXT.lock().unwrap() = text.to_string();
    let h = HWND(OVERLAY.load(Ordering::Relaxed) as *mut _);
    unsafe {
        let s = scale();
        let (w, hgt) = (((if kind == 3 { 360.0 } else { 220.0 }) * s) as i32, (46.0 * s) as i32);
        let wa = work_area();
        let x = wa.left + (wa.right - wa.left - w) / 2;
        let y = wa.bottom - hgt - (56.0 * s) as i32;
        let _ = SetWindowPos(h, HWND_TOPMOST, x, y, w, hgt, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        let rgn = CreateRoundRectRgn(0, 0, w + 1, hgt + 1, (hgt as f32 * 0.5) as i32, (hgt as f32 * 0.5) as i32);
        SetWindowRgn(h, rgn, true);
        let _ = KillTimer(h, TIMER_TOAST);
        if kind == 1 {
            SetTimer(h, TIMER_OVERLAY, 50, None);
        } else {
            let _ = KillTimer(h, TIMER_OVERLAY);
        }
        if toast_ms > 0 {
            SetTimer(h, TIMER_TOAST, toast_ms, None);
        }
        let _ = InvalidateRect(h, None, true);
    }
}

fn hide_overlay() {
    OVERLAY_KIND.store(0, Ordering::Relaxed);
    let h = HWND(OVERLAY.load(Ordering::Relaxed) as *mut _);
    unsafe {
        let _ = KillTimer(h, TIMER_OVERLAY);
        let _ = KillTimer(h, TIMER_TOAST);
        let _ = ShowWindow(h, SW_HIDE);
    }
}

// ---- suggestion pop-up ---------------------------------------------------------------------------

const SUG_W: f32 = 400.0;
const SUG_H: f32 = 104.0;

fn button_rects(s: f32) -> [RECT; 3] {
    let y = (62.0 * s) as i32;
    let h = (30.0 * s) as i32;
    let xs = [(14.0, 80.0), (102.0, 100.0), (210.0, 176.0)];
    xs.map(|(x, w)| RECT { left: (x * s) as i32, top: y, right: ((x + w) * s) as i32, bottom: y + h })
}

unsafe extern "system" fn suggest_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_MOUSEACTIVATE => LRESULT(3),
        WM_TIMER => {
            if wp.0 == TIMER_SUGGEST {
                close_suggestion();
            }
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            let x = (lp.0 & 0xFFFF) as i16 as i32;
            let y = ((lp.0 >> 16) & 0xFFFF) as i16 as i32;
            let rects = button_rects(scale());
            let hit = rects.iter().position(|r| x >= r.left && x < r.right && y >= r.top && y < r.bottom);
            if let Some(i) = hit {
                let cur = SUGGESTION.lock().unwrap().clone();
                close_suggestion();
                if let Some((heard, wanted)) = cur {
                    crate::app::on_suggestion(&heard, &wanted, i);
                }
            }
            LRESULT(0)
        }
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let hdc = BeginPaint(hwnd, &mut ps);
            let mut rc = RECT::default();
            let _ = GetClientRect(hwnd, &mut rc);
            let s = scale();
            fill(hdc, &rc, rgb(32, 33, 38));
            SetBkMode(hdc, TRANSPARENT);
            let (heard, wanted) = SUGGESTION.lock().unwrap().clone().unwrap_or_default();
            let f = font((15.0 * s) as i32, 600);
            let fs = font((12.0 * s) as i32, 400);
            let of = SelectObject(hdc, f);
            SetTextColor(hdc, rgb(245, 245, 245));
            let tr = RECT { left: (14.0 * s) as i32, top: (8.0 * s) as i32, right: rc.right - (10.0 * s) as i32, bottom: (32.0 * s) as i32 };
            draw_text(hdc, &format!("Add \"{wanted}\" to vocabulary?"), tr, DT_SINGLELINE | DT_LEFT | DT_END_ELLIPSIS);
            SelectObject(hdc, fs);
            SetTextColor(hdc, rgb(170, 172, 180));
            let tr2 = RECT { left: (14.0 * s) as i32, top: (32.0 * s) as i32, right: rc.right - (10.0 * s) as i32, bottom: (54.0 * s) as i32 };
            draw_text(hdc, &format!("(heard \"{heard}\")"), tr2, DT_SINGLELINE | DT_LEFT | DT_END_ELLIPSIS);
            let labels = ["Add", "Dismiss", "Don't suggest this"];
            let fills = [rgb(60, 120, 230), rgb(64, 66, 74), rgb(64, 66, 74)];
            for (i, r) in button_rects(s).iter().enumerate() {
                fill(hdc, r, fills[i]);
                SetTextColor(hdc, rgb(245, 245, 245));
                draw_text(hdc, labels[i], *r, DT_SINGLELINE | DT_VCENTER | DT_CENTER);
            }
            SelectObject(hdc, of);
            let _ = DeleteObject(f);
            let _ = DeleteObject(fs);
            let _ = EndPaint(hwnd, &ps);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn close_suggestion() {
    *SUGGESTION.lock().unwrap() = None;
    let h = HWND(SUGGEST.load(Ordering::Relaxed) as *mut _);
    unsafe {
        let _ = KillTimer(h, TIMER_SUGGEST);
        let _ = ShowWindow(h, SW_HIDE);
    }
}

fn show_suggestion(heard: String, wanted: String) {
    *SUGGESTION.lock().unwrap() = Some((heard, wanted));
    let h = HWND(SUGGEST.load(Ordering::Relaxed) as *mut _);
    unsafe {
        let s = scale();
        let (w, hgt) = ((SUG_W * s) as i32, (SUG_H * s) as i32);
        let wa = work_area();
        let x = wa.right - w - (16.0 * s) as i32;
        let y = wa.bottom - hgt - (16.0 * s) as i32;
        let _ = SetWindowPos(h, HWND_TOPMOST, x, y, w, hgt, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        SetTimer(h, TIMER_SUGGEST, 20_000, None);
        let _ = InvalidateRect(h, None, true);
    }
}

// ---- main window / menu --------------------------------------------------------------------------

struct Menus {
    _tray: TrayIcon,
    keys: Vec<(String, CheckMenuItem)>,
    learn: CheckMenuItem,
    llm: CheckMenuItem,
    startup: CheckMenuItem,
}

thread_local! {
    static MENUS: std::cell::RefCell<Option<Menus>> = const { std::cell::RefCell::new(None) };
}

fn key_choices() -> Vec<(String, PttKey)> {
    let mut v = vec![
        ("key:right-ctrl".to_string(), PttKey::RightCtrl),
        ("key:ctrl-win".to_string(), PttKey::CtrlWin),
        ("key:right-alt".to_string(), PttKey::RightAlt),
    ];
    for n in 1..=12u8 {
        v.push((format!("key:f{n}"), PttKey::F(n)));
    }
    v
}

fn make_icon() -> Icon {
    let n = 32usize;
    let mut px = vec![0u8; n * n * 4];
    for y in 0..n {
        for x in 0..n {
            let (dx, dy) = (x as f32 - 15.5, y as f32 - 15.5);
            let d = (dx * dx + dy * dy).sqrt();
            let i = (y * n + x) * 4;
            if d <= 15.0 {
                let inner = d <= 6.0 || (dx.abs() <= 2.0 && (-10.0..=8.0).contains(&dy));
                let c = if inner { [255, 255, 255, 255] } else { [70, 110, 235, 255] };
                px[i..i + 4].copy_from_slice(&c);
            }
        }
    }
    Icon::from_rgba(px, n as u32, n as u32).expect("icon")
}

fn tooltip(k: &PttKey) -> String {
    format!("Murmur - hold {} to dictate", k.label())
}

fn build_tray() -> Result<(), String> {
    let cfg = crate::app::config();
    let menu = Menu::new();
    let status = MenuItem::with_id("status", format!("Hold {} to dictate (Esc cancels)", cfg.ptt_key.label()), false, None);
    let mut keys = vec![];
    let sub = Submenu::new("Set push-to-talk key...", true);
    for (id, k) in key_choices() {
        let it = CheckMenuItem::with_id(id.clone(), k.label(), true, k == cfg.ptt_key, None);
        sub.append(&it).map_err(|e| e.to_string())?;
        keys.push((id, it));
    }
    let learn = CheckMenuItem::with_id("learn", "Suggest vocabulary from my edits", true, cfg.learn_vocab, None);
    let llm = CheckMenuItem::with_id("llm", "AI cleanup (llama.cpp)", true, cfg.provider != "none", None);
    let startup = CheckMenuItem::with_id("startup", "Start at login", true, crate::app::startup_enabled(), None);
    let dict = MenuItem::with_id("dict", "Open dictionary file", true, None);
    let logs = MenuItem::with_id("logs", "Open data folder (logs, history)", true, None);
    let quit = MenuItem::with_id("quit", "Quit Murmur", true, None);
    menu.append_items(&[&status, &PredefinedMenuItem::separator(), &sub, &learn, &llm, &startup, &PredefinedMenuItem::separator(), &dict, &logs, &PredefinedMenuItem::separator(), &quit])
        .map_err(|e| e.to_string())?;
    let tray = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_tooltip(tooltip(&cfg.ptt_key))
        .with_icon(make_icon())
        .build()
        .map_err(|e| e.to_string())?;
    MENUS.with(|m| *m.borrow_mut() = Some(Menus { _tray: tray, keys, learn, llm, startup }));
    MenuEvent::set_event_handler(Some(|e: MenuEvent| {
        MENU_QUEUE.lock().unwrap().push_back(e.id.0.clone());
        let h = MAIN.load(Ordering::Relaxed);
        if h != 0 {
            unsafe {
                let _ = PostMessageW(HWND(h as *mut _), WM_MENU, WPARAM(0), LPARAM(0));
            }
        }
    }));
    Ok(())
}

fn handle_menu(id: &str) {
    log(&format!("menu: {id}"));
    if let Some(rest) = id.strip_prefix("key:") {
        if let Some((_, k)) = key_choices().into_iter().find(|(i, _)| i == &format!("key:{rest}")) {
            crate::app::set_ptt_key(k.clone());
            MENUS.with(|m| {
                if let Some(m) = m.borrow().as_ref() {
                    for (i, it) in &m.keys {
                        it.set_checked(i == id);
                    }
                    let _ = m._tray.set_tooltip(Some(tooltip(&k)));
                }
            });
            show_overlay(3, &format!("Push-to-talk key: {}", k.label()), 2500);
        }
        return;
    }
    match id {
        "learn" => {
            let on = MENUS.with(|m| m.borrow().as_ref().map(|m| m.learn.is_checked()).unwrap_or(true));
            crate::app::set_learn(on);
        }
        "llm" => {
            let on = MENUS.with(|m| m.borrow().as_ref().map(|m| m.llm.is_checked()).unwrap_or(true));
            crate::app::set_llm(on);
        }
        "startup" => {
            let on = MENUS.with(|m| m.borrow().as_ref().map(|m| m.startup.is_checked()).unwrap_or(false));
            crate::app::set_startup(on);
        }
        "dict" => crate::app::open_dictionary(),
        "logs" => crate::app::open_data_dir(),
        "quit" => unsafe { PostQuitMessage(0) },
        _ => {}
    }
}

unsafe extern "system" fn main_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_UI => {
            loop {
                let c = QUEUE.lock().unwrap().pop_front();
                let Some(c) = c else { break };
                match c {
                    UiCmd::Listening => show_overlay(1, "Listening...", 0),
                    UiCmd::Transcribing => show_overlay(2, "Transcribing...", 0),
                    UiCmd::Toast(t) => show_overlay(3, &t, 4000),
                    UiCmd::Hide => hide_overlay(),
                    UiCmd::Suggest { heard, wanted } => show_suggestion(heard, wanted),
                }
            }
            LRESULT(0)
        }
        WM_MENU => {
            loop {
                let id = MENU_QUEUE.lock().unwrap().pop_front();
                let Some(id) = id else { break };
                handle_menu(&id);
            }
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn make_class(name: &str, proc: WNDPROC) -> Result<(), String> {
    unsafe {
        let hi = GetModuleHandleW(None).map_err(|e| e.to_string())?;
        let n = Box::leak(wide(name).into_boxed_slice());
        let wc = WNDCLASSW {
            lpfnWndProc: proc,
            hInstance: hi.into(),
            lpszClassName: PCWSTR(n.as_ptr()),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            ..Default::default()
        };
        if RegisterClassW(&wc) == 0 {
            return Err(format!("RegisterClassW({name}) failed"));
        }
    }
    Ok(())
}

fn make_window(class: &str, ex: WINDOW_EX_STYLE, style: WINDOW_STYLE, parent: HWND) -> Result<HWND, String> {
    unsafe {
        let hi = GetModuleHandleW(None).map_err(|e| e.to_string())?;
        let c = wide(class);
        CreateWindowExW(ex, PCWSTR(c.as_ptr()), PCWSTR(c.as_ptr()), style, 0, 0, 10, 10, parent, None, hi, None)
            .map_err(|e| format!("CreateWindowExW({class}): {e}"))
    }
}

/// Creates the windows and tray icon. Call on the thread that will run `message_loop`.
pub fn init() -> Result<(), String> {
    make_class("MurmurMain", Some(main_proc))?;
    make_class("MurmurOverlay", Some(overlay_proc))?;
    make_class("MurmurSuggest", Some(suggest_proc))?;
    let main = make_window("MurmurMain", WINDOW_EX_STYLE(0), WINDOW_STYLE(0), HWND_MESSAGE)?;
    MAIN.store(main.0 as isize, Ordering::Relaxed);
    let ex = WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
    let ov = make_window("MurmurOverlay", ex, WS_POPUP, HWND::default())?;
    OVERLAY.store(ov.0 as isize, Ordering::Relaxed);
    let sg = make_window("MurmurSuggest", ex, WS_POPUP, HWND::default())?;
    SUGGEST.store(sg.0 as isize, Ordering::Relaxed);
    build_tray()?;
    Ok(())
}

pub fn message_loop() {
    unsafe {
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, HWND::default(), 0, 0).0 > 0 {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}
