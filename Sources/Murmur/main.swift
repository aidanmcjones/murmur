import AppKit

if CommandLine.arguments.contains("--learn-selftest") {
    exit(VocabDiff.selfTest())
} else if let i = CommandLine.arguments.firstIndex(of: "--asr-boost-eval"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    Task { exit(await ParakeetEngine.boostEval(dir: dir)) }
    dispatchMain()
} else if let i = CommandLine.arguments.firstIndex(of: "--clean-text"), i + 1 < CommandLine.arguments.count {
    let a = CommandLine.arguments
    var bid = ""
    if let j = a.firstIndex(of: "--bundle-id"), j + 1 < a.count { bid = a[j + 1] }
    print(TestVectors.cleanText(a[i + 1], bundleId: bid))
    exit(0)
} else if let i = CommandLine.arguments.firstIndex(of: "--dump-test-vectors"), i + 1 < CommandLine.arguments.count {
    exit(TestVectors.dump(dir: CommandLine.arguments[i + 1]))
} else if let i = CommandLine.arguments.firstIndex(of: "--check-test-vectors"), i + 1 < CommandLine.arguments.count {
    exit(TestVectors.check(dir: CommandLine.arguments[i + 1]))
} else if CommandLine.arguments.contains("--learn-wfparity") {
    exit(VocabDiff.wfParity())
} else if let i = CommandLine.arguments.firstIndex(of: "--learn-test") {
    let a = CommandLine.arguments
    guard i + 2 < a.count else { FileHandle.standardError.write(Data("usage: --learn-test <pasted> <edited>\n".utf8)); exit(2) }
    print(VocabDiff.describe(VocabDiff.candidate(pasted: a[i + 1], edited: a[i + 2])))
    exit(0)
} else if CommandLine.arguments.contains("--transcribe") {
    let args = CommandLine.arguments
    Task {
        let code = await Headless.run(args)
        WhisperServer.shared.shutdown()
        LocalLLM.shared.shutdown()
        exit(code)
    }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
