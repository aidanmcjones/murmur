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
                mode = .idle
                DispatchQueue.main.async { self.onCancel?() }
                return nil
            }
            if code == 49, keyHeld, mode == .holding {  // hotkey + Space
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
        if down {
            switch mode {
            case .handsFree:
                mode = .idle
                ignoreRelease = true
                DispatchQueue.main.async { self.onStop?() }
            case .idle:
                mode = .holding; downTime = now
                DispatchQueue.main.async {
                    if self.onStart?() != true, self.mode != .idle {
                        self.mode = .idle; self.ignoreRelease = self.keyHeld
                    }
                }
            case .holding:
                break
            }
        } else {
            if ignoreRelease { ignoreRelease = false; return }
            guard mode == .holding else { return }
            if now - downTime < minHold {
                if now - lastTap < doubleTapWindow {
                    mode = .handsFree  // double tap: keep the recording running
                    lastTap = 0
                } else {
                    mode = .idle
                    lastTap = now
                    DispatchQueue.main.async { self.onCancel?() }
                }
            } else {
                mode = .idle
                DispatchQueue.main.async { self.onStop?() }
            }
        }
    }
}
