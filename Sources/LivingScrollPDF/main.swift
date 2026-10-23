import AppKit

if CommandLine.arguments.dropFirst().first == "selftest" {
    exit(SelfTest.run())
}
if CommandLine.arguments.dropFirst().first == "replay" {
    exit(Replay.run(Array(CommandLine.arguments.dropFirst(2))))
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
