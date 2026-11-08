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

    private let minHold: TimeInterval = 0.25
    private let doubleTapWindow: TimeInterval = 0.5

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
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
    func reset() { mode = .idle; ignoreRelease = keyHeld }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            DebugLog.log("hotkey tap disabled (\(type.rawValue)), re-enabling")
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            let f = CGEventSource.flagsState(.combinedSessionState)
            switch Settings.hotkey {
            case .fn: setDown(f.contains(.maskSecondaryFn))
            case .rightOption: setDown(f.contains(.maskAlternate))
            }
            return pass
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if code == 63 || code == 61 { DebugLog.log("flagsChanged code=\(code) flags=0x\(String(flags.rawValue, radix: 16)) keyHeld=\(keyHeld) mode=\(mode)") }
            switch Settings.hotkey {
            case .fn:
                guard code == 63 else { return pass }
                setDown(flags.contains(.maskSecondaryFn))
            case .rightOption:
                guard code == 61 else { return pass }
                setDown(flags.contains(.maskAlternate))
            }
            return pass
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
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
            return pass
        default:
            return pass
        }
    }

    private func setDown(_ down: Bool) {
        if down == keyHeld { return }
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
