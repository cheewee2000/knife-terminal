import AppKit

// Process entry runs on the main thread; hop onto the main actor explicitly.
// NSApplication.delegate is unowned — the top-level `delegate` keeps it alive.
let delegate = MainActor.assumeIsolated { () -> AppDelegate in
    let d = AppDelegate()
    let app = NSApplication.shared
    app.delegate = d
    app.setActivationPolicy(.regular)
    return d
}
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
