import AppKit
import Darwin

if let exitCode = SleepHelperCommandLine.runIfRequested() {
    exit(exitCode)
}

if let exitCode = CodexActivityCommandLine.runIfRequested() {
    exit(exitCode)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
