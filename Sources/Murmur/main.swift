import AppKit

/// Headless flags run and exit; they never reach NSApplication, the event tap or the recorder.
/// Any other "--" argument is a usage error, so a binary without a flag cannot fall through into the GUI app.
let args = CommandLine.arguments
let usage = """
    usage: Murmur [--learn-selftest | --learn-wfparity | --check-test-vectors DIR | --dump-test-vectors DIR
                   | --clean-text TEXT [--bundle-id ID] | --learn-test PASTED EDITED | --asr-boost-eval DIR
                   | --transcribe FILE [--bundle-id ID] [--before TEXT] [--release-budget]]
    (no arguments: the menu-bar app)

    """

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(((msg.isEmpty ? "" : "murmur: \(msg)\n") + usage).utf8))
    exit(2)
}

/// Hard deadline for headless runs: a hang exits 124 instead of lingering (MURMUR_HEADLESS_TIMEOUT overrides, seconds).
func watchdog(_ seconds: Double) {
    let s = ProcessInfo.processInfo.environment["MURMUR_HEADLESS_TIMEOUT"].flatMap(Double.init) ?? seconds
    DispatchQueue.global().asyncAfter(deadline: .now() + s) {
        FileHandle.standardError.write(Data("murmur: headless run exceeded \(Int(s)) s\n".utf8))
        exit(124)
    }
}

/// Value after `flag`, or a usage error.
func arg(_ flag: String, _ n: Int = 1) -> [String] {
    guard let i = args.firstIndex(of: flag), i + n < args.count else { fail("\(flag) needs \(n) argument(s)") }
    return Array(args[(i + 1)...(i + n)])
}

/// Single instance: an exclusive non-blocking flock on <support>/instance.lock, held for the process lifetime
/// (the fd stays open) and released by the kernel when the process dies, so simultaneous launches yield exactly one
/// winner and a relaunch succeeds as soon as the old instance is gone.
var instanceLockFD: Int32 = -1
func acquireInstanceLock() -> Bool {
    let path = Paths.support.appendingPathComponent("instance.lock").path
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { return true }  // cannot lock (unwritable folder): never block the app on it
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
    instanceLockFD = fd
    return true
}

let known: Set<String> = ["--instance-guard-test", "--learn-selftest", "--learn-wfparity", "--check-test-vectors", "--dump-test-vectors", "--clean-text",
                          "--learn-test", "--asr-boost-eval", "--transcribe"]
let modifiers: Set<String> = ["--bundle-id", "--before", "--release-budget"]
let dashed = args.dropFirst().filter { $0.hasPrefix("--") }
let mode = dashed.first { known.contains($0) }

if let mode {
    switch mode {
    case "--instance-guard-test":  // test only: the GUI's instance guard, then hold it SECONDS and exit (0 won, 10 lost)
        let secs = Double(arg(mode)[0]) ?? 0
        watchdog(secs + 30)
        guard acquireInstanceLock() else { print("lost"); exit(10) }
        print("won"); fflush(stdout)
        Thread.sleep(forTimeInterval: secs)
        exit(0)
    case "--learn-selftest": watchdog(120); exit(VocabDiff.selfTest())
    case "--learn-wfparity": watchdog(120); exit(VocabDiff.wfParity())
    case "--check-test-vectors": let d = arg(mode)[0]; watchdog(120); exit(TestVectors.check(dir: d))
    case "--dump-test-vectors": let d = arg(mode)[0]; watchdog(120); exit(TestVectors.dump(dir: d))
    case "--clean-text":
        let t = arg(mode)[0]
        watchdog(30)
        print(TestVectors.cleanText(t, bundleId: args.contains("--bundle-id") ? arg("--bundle-id")[0] : ""))
        exit(0)
    case "--learn-test":
        let a = arg(mode, 2)
        watchdog(30)
        print(VocabDiff.describe(VocabDiff.candidate(pasted: a[0], edited: a[1])))
        exit(0)
    case "--asr-boost-eval":
        let d = arg(mode)[0]
        watchdog(3600)
        Task { exit(await ParakeetEngine.boostEval(dir: d)) }
        dispatchMain()
    default:  // --transcribe
        _ = arg(mode)
        watchdog(600)
        Task {
            let code = await Headless.run(args)
            WhisperServer.shared.shutdown()
            LocalLLM.shared.shutdown()
            exit(code)
        }
        dispatchMain()
    }
} else if let bad = dashed.first {
    fail(modifiers.contains(bad) ? "\(bad) needs a mode flag" : "unknown option \(bad)")
} else {
    if ProcessInfo.processInfo.environment["MURMUR_ASSERT_NO_TAP"] != nil {
        FileHandle.standardError.write(Data("murmur: MURMUR_ASSERT_NO_TAP set but the GUI app was reached\n".utf8))
        exit(3)
    }
    // Single instance: a second GUI copy would install a second event tap and paste every dictation twice.
    guard acquireInstanceLock() else {
        DebugLog.log("startup: another Murmur holds the instance lock, exiting")
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
