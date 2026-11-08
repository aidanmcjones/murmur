import AppKit

if CommandLine.arguments.contains("--transcribe") {
    let args = CommandLine.arguments
    Task {
        let code = await Headless.run(args)
        WhisperServer.shared.shutdown()
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
