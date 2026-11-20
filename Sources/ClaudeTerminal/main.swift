import AppKit

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--perf-bench") {
    PerfBench.run(paths: Array(CommandLine.arguments[(i + 1)...]))
}
if let i = CommandLine.arguments.firstIndex(of: "--perf-verify") {
    PerfBench.verify(paths: Array(CommandLine.arguments[(i + 1)...]))
}
if let i = CommandLine.arguments.firstIndex(of: "--perf-snapshot") {
    PerfSnapshot.run(Array(CommandLine.arguments[(i + 1)...]))
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
