// Porter Screenshot.app: takes one screenshot of the main display, scaled to points, into the path in argv[1].
// It is an app of its own so that Screen Recording can be granted to it alone; `ui shot` opens it.
import AppKit

let args = CommandLine.arguments
guard args.count > 1 else { exit(2) }
if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess(); exit(3) }
let tmp = args[1] + ".full.png"
func run(_ tool: String, _ a: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = a
    try? p.run(); p.waitUntilExit()
}
run("/usr/sbin/screencapture", ["-x", "-m", "-t", "png", tmp])
let width = Int(NSScreen.main?.frame.width ?? 1728)
run("/usr/bin/sips", ["--resampleWidth", String(width), tmp, "--out", args[1]])
try? FileManager.default.removeItem(atPath: tmp)
