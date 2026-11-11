import CoreGraphics
import Foundation

final class Hotkey {
    enum Mode { case idle, holding, handsFree }

    /// onStart returns false if recording could not begin.
    var onStart: (() -> Bool)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private var tap: CFMachPort?
    private var mode: Mode = .idle
    private var keyHeld = false
    private var ignoreRelease = false
    private var downTime: TimeInterval = 0
    private var lastTap: TimeInterval = 0
    private var activeSource = 0

    /// When set, the next key press is delivered here (code, or nil for cancel) instead of acting as a hotkey.
    var capture: ((Int?) -> Void)?

    private let minHold: TimeInterval = 0.25
    private let doubleTapWindow: TimeInterval = 0.5

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<Hotkey>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: cb,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    /// Called by the controller if it ends a session on its own.
    /// Non-modifier keys allowed as a push-to-talk key: F1–F20 and Help/Insert only. Typing keys
    /// (letters, digits, space, return, arrows…) would be swallowed and break normal typing.
    static let allowedPlainKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                              105, 107, 113, 106, 64, 79, 80, 90, 114]

    /// keyUp to swallow because its keyDown was consumed by key capture.
    private var swallowUpCode: Int?

    func reset() { mode = .idle; ignoreRelease = keyHeld }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            DebugLog.log("hotkey tap disabled (\(type.rawValue)), re-enabling")
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            let f = CGEventSource.flagsState(.combinedSessionState)
            if Settings.useFn { setDown(f.contains(.maskSecondaryFn), source: 63) }
            if let c = Settings.customKey {
                setDown(CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(c)), source: c)
            }
            return pass
        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            if let cap = capture {
                DebugLog.log("capture flagsChanged code=\(code) flags=0x\(String(flags.rawValue, radix: 16))")
                if let bit = KeyInfo.modifierBits[code], flags.rawValue & bit != 0 {
                    capture = nil
                    DispatchQueue.main.async { cap(code) }
                }
                return pass
            }
            if code == 63 || KeyInfo.modifierBits[code] != nil { DebugLog.log("flagsChanged code=\(code) flags=0x\(String(flags.rawValue, radix: 16)) keyHeld=\(keyHeld) mode=\(mode)") }
            if code == 63, Settings.useFn {
                setDown(flags.contains(.maskSecondaryFn), source: 63)
            } else if code == Settings.customKey, let bit = KeyInfo.modifierBits[code] {
                setDown(flags.rawValue & bit != 0, source: code)
            }
            return pass
        case .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if let s = swallowUpCode, code == s { swallowUpCode = nil; return nil }
            if code == Settings.customKey, KeyInfo.modifierBits[code] == nil {
                setDown(false, source: code)
                return nil
            }
            return pass
        case .keyDown:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if let cap = capture {
                DebugLog.log("capture keyDown code=\(code)")
                swallowUpCode = code
                if code == 53 {
                    capture = nil
                    DispatchQueue.main.async { cap(nil) }
                } else if Self.allowedPlainKeys.contains(code) {
                    capture = nil
                    DispatchQueue.main.async { cap(code) }
                } else {
                    DebugLog.log("capture rejected code=\(code)")
                }
                return nil
            }
            if code == 53, mode != .idle {  // Esc
                DebugLog.log("hotkey esc cancel")
                mode = .idle
                DispatchQueue.main.async { self.onCancel?() }
                return nil
            }
            if code == 49, keyHeld, mode == .holding {  // hotkey + Space
                DebugLog.log("hotkey space -> handsFree")
                mode = .handsFree
                return nil
            }
            if code == Settings.customKey, KeyInfo.modifierBits[code] == nil {  // non-modifier hotkey
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { setDown(true, source: code) }
                return nil
            }
            if keyHeld, mode == .holding, activeSource == 63 || KeyInfo.modifierBits[activeSource] != nil {  // fn/modifier + other key = shortcut, not dictation
                DebugLog.log("hotkey combo with key \(code) -> cancel silently")
                mode = .idle
                ignoreRelease = true
                DispatchQueue.main.async { self.onCancel?() }
            }
            if VocabLearner.shared.recording { VocabLearner.shared.observeKey(code: code, flags: event.flags, event: event) }
            return pass
        case .leftMouseDown, .rightMouseDown:
            if VocabLearner.shared.recording { VocabLearner.shared.observeMouse() }
            return pass
        default:
            return pass
        }
    }

    private func setDown(_ down: Bool, source: Int) {
        if down == keyHeld { return }
        if down { activeSource = source } else if source != activeSource { return }
        keyHeld = down
        let now = ProcessInfo.processInfo.systemUptime
        DebugLog.log("hotkey \(down ? "down" : "up") mode=\(mode) ignoreRelease=\(ignoreRelease) held=\(String(format: "%.3f", now - downTime))s sinceLastTap=\(String(format: "%.3f", now - lastTap))s")
        if down {
            switch mode {
            case .handsFree:
                DebugLog.log("hotkey down in handsFree -> stop")
                mode = .idle
                ignoreRelease = true
                DispatchQueue.main.async { self.onStop?() }
            case .idle:
                mode = .holding; downTime = now
                DispatchQueue.main.async {
                    let ok = self.onStart?() == true
                    DebugLog.log("hotkey onStart ok=\(ok) mode=\(self.mode)")
                    if !ok, self.mode != .idle {
                        self.mode = .idle; self.ignoreRelease = self.keyHeld
                    }
                }
            case .holding:
                break
            }
        } else {
            if ignoreRelease { ignoreRelease = false; DebugLog.log("hotkey release swallowed (ignoreRelease)"); return }
            guard mode == .holding else { DebugLog.log("hotkey release ignored, mode=\(mode)"); return }
            if now - downTime < minHold {
                if now - lastTap < doubleTapWindow {
                    DebugLog.log("hotkey -> handsFree (double tap)")
                    mode = .handsFree  // double tap: keep the recording running
                    lastTap = 0
                } else {
                    DebugLog.log("hotkey short hold -> cancel")
                    mode = .idle
                    lastTap = now
                    DispatchQueue.main.async { self.onCancel?() }
                }
            } else {
                DebugLog.log("hotkey -> stop")
                mode = .idle
                DispatchQueue.main.async { self.onStop?() }
            }
        }
    }
}
