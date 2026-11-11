import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case idle, recording, processing }

    private var statusItem: NSStatusItem!
    private var hotkeyRetry: Timer?
    private let hotkey = Hotkey()
    private let recorder = AudioRecorder()
    private let hud = HUD()
    private var state: State = .idle
    private var ctx = AppContext(bundleId: "", appName: "", before: "")
    private var probe: Task<String, Never>?
    private var startedAt = Date()

    // Speculative finish: run the pipeline during a pause, before the key is released.
    private struct SpecJob { let cut: Int; let task: Task<PipelineResult?, Never>; let speechEnd: Int; let raw: RawBox }
    /// Upper bound on cleanup time after the key is released. Wispr Flow measures 322 ms p50 / 530 ms p90
    /// release-to-paste on this Mac; past this budget Murmur pastes the deterministic cleanup of the transcript.
    static let releaseBudget: TimeInterval = 0.9

    private static func value(of task: Task<PipelineResult?, Never>, within t: TimeInterval) async -> PipelineResult? {
        await withTaskGroup(of: PipelineResult?.self) { g in
            g.addTask { await task.value }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000)); return nil }
            let r = await g.next() ?? nil
            g.cancelAll()  // stops waiting; does not cancel `task` itself
            return r
        }
    }

    private static func fallback(raw: String, asrMs: Int, ctx: AppContext) -> PipelineResult {
        let cleaned = Cleanup.basicClean(raw)
        return PipelineResult(raw: raw, cleaned: cleaned,
                              final: Post.finalize(cleaned, before: ctx.before, dictionary: UserDictionary.load()),
                              asrMs: asrMs, llmMs: -1, mode: .timeout)
    }
    private var specJob: SpecJob?
    private var specHadSpeech = false
    private var specPeak: Float = 0
    private var specSpeechEnd = 0
    private static let specSilence = 2400  // 150 ms at 16 kHz

    private func specThreshold() -> Float { max(0.006, 0.2 * specPeak) }

    private func specReset() {
        specJob?.task.cancel(); specJob = nil
        specHadSpeech = false; specPeak = 0; specSpeechEnd = 0
    }

    private func specBuffer(rms: Float, count: Int) {
        guard state == .recording else { return }
        specPeak = max(specPeak, rms)
        if rms > specThreshold() {
            specHadSpeech = true
            specSpeechEnd = count
            if let j = specJob { j.task.cancel(); specJob = nil; DebugLog.log("spec job stale (speech resumed)") }  // speech resumed: stale
            return
        }
        guard specHadSpeech, specJob == nil, count - specSpeechEnd >= Self.specSilence else { return }
        let snap = Array(recorder.samplesSoFar().prefix(count))
        guard snap.count == count else { return }
        let c0 = ctx, probe = self.probe
        DebugLog.log("spec job launched cut=\(count)")
        let box = RawBox()
        let task = Task { () -> PipelineResult? in
            var c = c0
            if let probe { c.before = await probe.value }
            return await Pipeline.run(samples: snap, ctx: c, llmTimeout: 4, rawBox: box)
        }
        specJob = SpecJob(cut: count, task: task, speechEnd: specSpeechEnd, raw: box)
    }

    private func tailHasSpeech(_ all: [Float], from cut: Int) -> Bool {
        let th = specThreshold()
        var i = cut
        while i < all.count {
            let e = min(all.count, i + 320)  // 20 ms frames
            if SpeechGate.rms(all[i..<e]) > th { return true }
            i = e
        }
        return false
    }
    private var signalSources: [DispatchSourceSignal] = []

    /// Opening the app again (Finder/Spotlight/`open`) pops the menu at the pointer,
    /// so it's reachable even when macOS hides the menu-bar icon behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let menu = statusItem.menu {
            menuNeedsUpdate(menu)
            NSApp.activate(ignoringOtherApps: true)
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        setIcon(.idle)

        recorder.onLevel = { [weak self] v in self?.hud.level(v) }
        recorder.onBuffer = { [weak self] r, n in self?.specBuffer(rms: r, count: n) }
        recorder.onLimit = { [weak self] in self?.hotkey.reset(); self?.finishRecording() }
        Settings.migrateHotkey()
        VocabLearner.installDebugHooks()
        hotkey.onStart = { [weak self] in self?.beginRecording() ?? false }
        hotkey.onStop = { [weak self] in self?.finishRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }
        if hotkey.start() {
            Toast.show("Murmur ready — hold fn to talk")
        } else {
            checkPermissions()
            Toast.show("Murmur needs Accessibility — enable it in System Settings", seconds: 6)
            // Retry until the user grants Accessibility; no relaunch needed.
            hotkeyRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                if self.hotkey.start() { t.invalidate(); Toast.show("Murmur ready — hold fn to talk") }
            }
        }

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { WhisperServer.shared.shutdown(); LocalLLM.shared.shutdown(); exit(0) }
            src.resume()
            signalSources.append(src)
        }

        Task {
            if Settings.asrEngine == .fast {
                if await ParakeetEngine.shared.load() { return }  // Whisper stays lazy (1.6 GB RAM)
            }
            await WhisperServer.shared.ensureRunning()
        }
        // One-time: an Ollama provider setting stalls 4 s per dictation after Ollama unloads its model
        // (30 min idle) and under swap; Murmur's own mlocked llama-server stays resident.
        if !UserDefaults.standard.bool(forKey: "migratedProviderV2") {
            if Settings.provider == .ollama, LocalLLM.modelPath() != nil { Settings.provider = .local }
            UserDefaults.standard.set(true, forKey: "migratedProviderV2")
        }
        Task { if Settings.provider == .local { await LocalLLM.shared.ensureRunning() } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WhisperServer.shared.shutdown()
        LocalLLM.shared.shutdown()
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
        specReset()
        VocabLearner.shared.stop(evaluate: true)
        guard recorder.start() else {
            DebugLog.log("beginRecording: recorder.start failed")
            Toast.show(recorder.lastError ?? "Microphone failed to start", seconds: 4)
            return false
        }
        DebugLog.log("beginRecording ok app=\(ctx.bundleId)")
        probe = Task {
            await withCheckedContinuation { (k: CheckedContinuation<String, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { k.resume(returning: ContextProbe.textBeforeCursor()) }
            }
        }
        state = .recording
        startedAt = Date()
        setIcon(.recording)
        let started = startedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            if let self, self.state == .recording, self.startedAt == started { self.hud.showRecording() }
        }
        let c = ctx
        Task { await Cleanup.prewarm(bundleId: c.bundleId, name: c.appName) }
        return true
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()
        DebugLog.log("cancelRecording")
        specReset()
        probe?.cancel(); probe = nil
        state = .idle
        setIcon(.idle)
        hud.hide()
    }

    private func finishRecording() {
        guard state == .recording else { return }
        let samples = recorder.stop()
        let job = specJob
        specJob = nil
        DebugLog.log("finishRecording samples=\(samples.count) peak=\(specPeak) job=\(job == nil ? "none" : "cut=\(job!.cut)")")
        let useSpec = job != nil && tailHasSpeech(samples, from: job!.cut) == false
        DebugLog.log("finishRecording useSpec=\(useSpec)")
        if !useSpec { job?.task.cancel() }
        specHadSpeech = false
        if samples.count < 4800 {  // under 0.3 s
            job?.task.cancel()
            DebugLog.log("finishRecording: too short, ignored")
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
            var result: PipelineResult?
            if useSpec, let job {
                result = await Self.value(of: job.task, within: Self.releaseBudget)
                if result == nil, let (raw, asrMs) = job.raw.value {
                    job.task.cancel()
                    DebugLog.log("finish: spec cleanup missed budget -> deterministic")
                    result = Self.fallback(raw: raw, asrMs: asrMs, ctx: c)
                } else if result == nil {
                    result = await job.task.value
                }
            } else {
                result = await Pipeline.run(samples: samples, ctx: c, llmTimeout: Self.releaseBudget)
            }
            await MainActor.run {
                DebugLog.log("finish: result=\(result == nil ? "nil" : "len=\(result!.final.count)") spec=\(useSpec) total=\(Int(Date().timeIntervalSince(t0) * 1000))ms")
                if let r = result {
                    Inserter.insert(r.final, bundleId: c.bundleId)
                    VocabLearner.shared.pasted(r.final, bundleId: c.bundleId)
                    History.append(HistoryEntry(ts: ISO8601DateFormatter().string(from: t0), raw: r.raw, cleaned: r.final,
                                                app: c.bundleId, asrMs: r.asrMs, llmMs: r.llmMs,
                                                totalMs: Int(Date().timeIntervalSince(t0) * 1000), spec: useSpec,
                                                mode: r.mode.rawValue))
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

        let eng = NSMenuItem(title: "Speech engine", action: nil, keyEquivalent: "")
        let es = NSMenu()
        for (e, title) in [(AsrEngine.fast, "Parakeet Ultra (recommended)"), (AsrEngine.accurate, "Whisper (slower, less accurate)")] {
            let i = NSMenuItem(title: title, action: #selector(setEngine(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = e.rawValue
            i.state = Settings.asrEngine == e ? .on : .off
            es.addItem(i)
        }
        eng.submenu = es
        menu.addItem(eng)

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

        let hk = NSMenuItem(title: "Push-to-talk key", action: nil, keyEquivalent: "")
        let hs = NSMenu()
        let fnItem = NSMenuItem(title: "Use fn/🌐 key", action: #selector(toggleFn), keyEquivalent: "")
        fnItem.target = self
        fnItem.state = Settings.useFn ? .on : .off
        hs.addItem(fnItem)
        let cur = NSMenuItem(title: "Custom: " + (Settings.customKey.map { KeyInfo.name($0) } ?? "none"), action: nil, keyEquivalent: "")
        cur.isEnabled = false
        hs.addItem(cur)
        let setItem = NSMenuItem(title: "Set custom key…", action: #selector(setCustomKey), keyEquivalent: "")
        setItem.target = self
        hs.addItem(setItem)
        let clearItem = NSMenuItem(title: "Clear", action: #selector(clearCustomKey), keyEquivalent: "")
        clearItem.target = self
        clearItem.isEnabled = Settings.customKey != nil
        hs.addItem(clearItem)
        hk.submenu = hs
        menu.addItem(hk)
        add(menu, "Disable Globe emoji popup", #selector(disableEmojiPopup))
        menu.addItem(.separator())

        add(menu, "Edit vocabulary", #selector(editVocabulary))
        add(menu, "Learn vocabulary from my edits", #selector(toggleLearn)).state = Settings.learnVocab ? .on : .off
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

    @objc private func setEngine(_ s: NSMenuItem) {
        guard let r = s.representedObject as? String, let e = AsrEngine(rawValue: r) else { return }
        Settings.asrEngine = e
        Task {
            if e == .accurate { await WhisperServer.shared.ensureRunning() }
            else {
                _ = await ParakeetEngine.shared.load()
                WhisperServer.shared.shutdown()  // frees ~1.6 GB; only stops a server Murmur started
            }
        }
    }

    @objc private func setProvider(_ s: NSMenuItem) {
        if let r = s.representedObject as? String, let p = Provider(rawValue: r) { Settings.provider = p }
    }

    @objc private func toggleLearn() {
        Settings.learnVocab.toggle()
        if !Settings.learnVocab { VocabLearner.shared.stop() }
    }
    @objc private func toggleFn() {
        Settings.useFn.toggle(); hotkey.reset()
    }

    @objc private func clearCustomKey() {
        Settings.customKey = nil; hotkey.reset()
    }

    private var capturePanel: NSPanel?

    @objc private func setCustomKey() {
        capturePanel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 70),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Murmur"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Press a modifier (e.g. right ⌥ or right ⌘) or an F-key. Esc cancels.")
        label.frame = NSRect(x: 20, y: 20, width: 420, height: 20)
        label.alignment = .center
        panel.contentView?.addSubview(label)
        panel.center()
        panel.orderFrontRegardless()
        capturePanel = panel
        hotkey.reset()
        hotkey.capture = { [weak self, weak panel] code in
            panel?.close()
            guard let code else { DebugLog.log("capture cancelled"); return }
            DebugLog.log("capture set custom key code=\(code)")
            Settings.customKey = code
            self?.hotkey.reset()
            Toast.show("Push-to-talk key: \(KeyInfo.name(code))")
        }
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
