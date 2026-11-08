import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case idle, recording, processing }

    private var statusItem: NSStatusItem!
    private let hotkey = Hotkey()
    private let recorder = AudioRecorder()
    private let hud = HUD()
    private var state: State = .idle
    private var ctx = AppContext(bundleId: "", appName: "", before: "")
    private var probe: Task<String, Never>?
    private var startedAt = Date()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        setIcon(.idle)

        recorder.onLevel = { [weak self] v in self?.hud.level(v) }
        recorder.onLimit = { [weak self] in self?.hotkey.reset(); self?.finishRecording() }
        hotkey.onStart = { [weak self] in self?.beginRecording() ?? false }
        hotkey.onStop = { [weak self] in self?.finishRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }
        if !hotkey.start() { checkPermissions() }

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { WhisperServer.shared.shutdown(); exit(0) }
            src.resume()
            signalSources.append(src)
        }

        Task { await WhisperServer.shared.ensureRunning() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WhisperServer.shared.shutdown()
    }

    // MARK: Recording flow

    private func setIcon(_ s: State) {
        let name: String
        switch s {
        case .idle: name = "waveform"
        case .recording: name = "record.circle.fill"
        case .processing: name = "ellipsis.circle"
        }
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Murmur")
    }

    private func beginRecording() -> Bool {
        guard state == .idle else { return false }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return false
        }
        let app = NSWorkspace.shared.frontmostApplication
        ctx = AppContext(bundleId: app?.bundleIdentifier ?? "", appName: app?.localizedName ?? "", before: "")
        guard recorder.start() else { return false }
        probe = Task {
            await withCheckedContinuation { (k: CheckedContinuation<String, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { k.resume(returning: ContextProbe.textBeforeCursor()) }
            }
        }
        state = .recording
        startedAt = Date()
        setIcon(.recording)
        hud.showRecording()
        let c = ctx
        Task { await Cleanup.prewarm(bundleId: c.bundleId, name: c.appName) }
        return true
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()
        probe?.cancel(); probe = nil
        state = .idle
        setIcon(.idle)
        hud.hide()
    }

    private func finishRecording() {
        guard state == .recording else { return }
        let samples = recorder.stop()
        if samples.count < 4800 {  // under 0.3 s
            state = .idle; probe = nil; setIcon(.idle); hud.hide(); return
        }
        state = .processing
        setIcon(.processing)
        hud.showProcessing()
        let c0 = ctx
        let probe = self.probe
        self.probe = nil
        let t0 = Date()
        Task {
            var c1 = c0
            if let probe { c1.before = await probe.value }
            let c = c1
            let result = await Pipeline.run(samples: samples, ctx: c)
            await MainActor.run {
                if let r = result {
                    Inserter.insert(r.final, bundleId: c.bundleId)
                    History.append(HistoryEntry(ts: ISO8601DateFormatter().string(from: t0), raw: r.raw, cleaned: r.final,
                                                app: c.bundleId, asrMs: r.asrMs, llmMs: r.llmMs,
                                                totalMs: Int(Date().timeIntervalSince(t0) * 1000)))
                }
                self.state = .idle
                self.setIcon(.idle)
                self.hud.hide()
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let prov = NSMenuItem(title: "Cleanup provider", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for p in Provider.allCases {
            let i = NSMenuItem(title: p.rawValue, action: #selector(setProvider(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = p.rawValue
            i.state = Settings.provider == p ? .on : .off
            sub.addItem(i)
        }
        prov.submenu = sub
        menu.addItem(prov)
        add(menu, "Set Anthropic key…", #selector(setKey))

        let hk = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        let hs = NSMenu()
        for (title, c) in [("Fn / Globe", HotkeyChoice.fn), ("Right Option", .rightOption)] {
            let i = NSMenuItem(title: title, action: #selector(setHotkey(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = c.rawValue
            i.state = Settings.hotkey == c ? .on : .off
            hs.addItem(i)
        }
        hk.submenu = hs
        menu.addItem(hk)
        add(menu, "Disable Globe emoji popup", #selector(disableEmojiPopup))
        menu.addItem(.separator())

        add(menu, "Edit vocabulary", #selector(editVocabulary))
        add(menu, "Import from Wispr Flow", #selector(importWispr))

        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let rs = NSMenu()
        let items = History.recent(20)
        if items.isEmpty { let e = NSMenuItem(title: "(none)", action: nil, keyEquivalent: ""); e.isEnabled = false; rs.addItem(e) }
        for h in items {
            let one = h.cleaned.replacingOccurrences(of: "\n", with: " ")
            let i = NSMenuItem(title: one.count > 60 ? String(one.prefix(60)) + "…" : one,
                               action: #selector(copyRecent(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = h.cleaned
            rs.addItem(i)
        }
        recent.submenu = rs
        menu.addItem(recent)
        menu.addItem(.separator())

        add(menu, "Check permissions", #selector(checkPermissions))
        let login = add(menu, "Launch at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add(menu, "Quit", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ m: NSMenu, _ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        m.addItem(i)
        return i
    }

    @objc private func setProvider(_ s: NSMenuItem) {
        if let r = s.representedObject as? String, let p = Provider(rawValue: r) { Settings.provider = p }
    }

    @objc private func setHotkey(_ s: NSMenuItem) {
        if let r = s.representedObject as? String, let c = HotkeyChoice(rawValue: r) { Settings.hotkey = c; hotkey.reset() }
    }

    @objc private func setKey() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Anthropic API key"
        a.informativeText = "Stored in your login Keychain. Leave empty to remove."
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            Keychain.set(f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @objc private func disableEmojiPopup() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["write", "com.apple.HIToolbox", "AppleFnUsageType", "-int", "0"]
        try? p.run()
        p.waitUntilExit()
        alert("Globe emoji popup disabled", p.terminationStatus == 0 ? "You may need to log out and back in." : "The defaults command failed.")
    }

    @objc private func editVocabulary() {
        UserDictionary.ensureFile()
        NSWorkspace.shared.open(Paths.dictionary)
    }

    @objc private func importWispr() {
        if let n = UserDictionary.importWispr() {
            alert("Import from Wispr Flow", "Added \(n) entries.")
        } else {
            alert("Import from Wispr Flow", "Could not read the Wispr Flow database.")
        }
    }

    @objc private func copyRecent(_ s: NSMenuItem) {
        guard let t = s.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    @objc private func checkPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        alert("Permissions",
              "Microphone: \(mic ? "granted" : "not granted")\nAccessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")\nInput Monitoring: \(CGPreflightListenEventAccess() ? "granted" : "not granted")\n\nRestart Murmur after granting Accessibility or Input Monitoring.")
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { alert("Launch at login", "\(error.localizedDescription)") }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
