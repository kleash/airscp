// ui: drives the Mac's GUI for AirSCP's GUI tests (clicks, keys, text, the accessibility tree, menus, screenshots).
// Needs Accessibility for the terminal that runs it, and Screen Recording for "Porter Screenshot.app" (see README.md).
//
//   ui shot PATH                     screenshot of the main display, scaled to points (1 image px = 1 click point)
//   ui click X Y [right|double]      mouse click at screen point X Y (top-left origin, same as the screenshot)
//   ui drag X1 Y1 X2 Y2              press at X1 Y1, move, release at X2 Y2
//   ui scroll DY [X Y]               scroll wheel by DY lines (negative = down), optionally at X Y
//   ui type TEXT                     type TEXT as Unicode (any layout)
//   ui key COMBO                     e.g. cmd+n, cmd+shift+period, return, esc, tab, down, f5, cmd+1
//   ui tree APP [DEPTH]              accessibility tree of APP's windows: role, title/description/value, identifier, frame
//   ui press APP TEXT [N]            AXPress the Nth (default 1st) element whose title, description or identifier is TEXT
//   ui menu APP "Menu>Item>Sub"      choose a menu bar item by titles
//   ui activate APP                  bring APP to the front
//   ui windows APP                   window titles and frames
import AppKit
import ApplicationServices

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { die("usage: see the top of ui.swift") }
if cmd != "shot" && !AXIsProcessTrusted() { die("ui: no Accessibility permission for this terminal (System Settings > Privacy & Security > Accessibility)") }

func num(_ i: Int) -> Double { guard i < args.count, let v = Double(args[i]) else { die("ui \(cmd): number expected at argument \(i)") }; return v }

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(15_000) }

func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
    e?.setIntegerValueField(.mouseEventClickState, value: clicks)
    post(e)
}

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
    "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25, "7": 26,
    "minus": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38,
    "'": 39, "k": 40, ";": 41, "\\": 42, "comma": 43, "/": 44, "slash": 44, "n": 45, "m": 46, "period": 47, ".": 47,
    "tab": 48, "space": 49, "`": 50, "delete": 51, "esc": 53, "escape": 53, "f5": 96, "f3": 99, "f2": 120, "f1": 122,
    "f4": 118, "f6": 97, "f7": 98, "f8": 100, "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119,
    "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126, "enter": 76,
]
func keyCode(_ k: String) -> CGKeyCode {
    guard let c = keyCodes[k] else { die("ui key: unknown key \(k)") }
    return c
}

func press(_ combo: String) {
    var parts = combo.lowercased().split(separator: "+").map(String.init)
    let key = parts.removeLast()
    var flags = CGEventFlags()
    for m in parts {
        switch m {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "opt", "option": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "fn": flags.insert(.maskSecondaryFn)
        default: die("ui key: unknown modifier \(m)")
        }
    }
    let code = keyCode(key)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        e?.flags = flags
        post(e)
    }
}

func typeText(_ s: String) {
    for ch in s {
        let u = Array(String(ch).utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
            post(e)
        }
    }
}

func app(_ name: String) -> NSRunningApplication {
    let apps = NSWorkspace.shared.runningApplications
    if let a = apps.first(where: { $0.localizedName == name || $0.bundleIdentifier == name }) { return a }
    if let pid = pid_t(name), let a = NSRunningApplication(processIdentifier: pid) { return a }
    die("ui: no running app named \(name)")
}

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ a: String) -> String? {
    guard let v = attr(e, a) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

func describe(_ e: AXUIElement) -> String {
    var s = str(e, kAXRoleAttribute) ?? "?"
    if let sr = str(e, kAXSubroleAttribute) { s += "/" + sr }
    for (label, a) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute), ("id", kAXIdentifierAttribute),
                       ("help", kAXHelpAttribute)] {
        if let v = str(e, a) { s += " \(label)=\"\(v.prefix(80))\"" }
    }
    if let v = str(e, kAXValueAttribute) { s += " value=\"\(v.replacingOccurrences(of: "\n", with: "⏎").prefix(80))\"" }
    if let en = attr(e, kAXEnabledAttribute) as? Bool, !en { s += " disabled" }
    if let f = frame(e) { s += " @\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))" }
    return s
}

func dump(_ e: AXUIElement, _ depth: Int, _ max: Int, _ budget: inout Int) {
    guard budget > 0 else { return }
    budget -= 1
    print(String(repeating: "  ", count: depth) + describe(e))
    if depth < max { for c in children(e) { dump(c, depth + 1, max, &budget) } }
}

func find(_ e: AXUIElement, _ text: String, _ hits: inout [AXUIElement], _ depth: Int = 0) {
    guard depth < 40 else { return }
    for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute] where str(e, a) == text {
        hits.append(e); break
    }
    for c in children(e) { find(c, text, &hits, depth + 1) }
}

switch cmd {
case "shot":
    guard args.count > 1 else { die("ui shot PATH") }
    let path = URL(fileURLWithPath: args[1]).standardizedFileURL.path
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("Porter Screenshot.app").path
    try? FileManager.default.removeItem(atPath: path)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-W", "-n", "-g", helper, "--args", path]
    try! p.run(); p.waitUntilExit()
    guard FileManager.default.fileExists(atPath: path) else { die("ui shot: no image (Screen Recording for Porter Screenshot.app?)") }
    print(path)
case "click":
    let p = CGPoint(x: num(1), y: num(2))
    let kind = args.count > 3 ? args[3] : "left"
    mouse(.mouseMoved, p)
    switch kind {
    case "right": mouse(.rightMouseDown, p, .right); mouse(.rightMouseUp, p, .right)
    case "double": mouse(.leftMouseDown, p); mouse(.leftMouseUp, p); mouse(.leftMouseDown, p, clicks: 2); mouse(.leftMouseUp, p, clicks: 2)
    default: mouse(.leftMouseDown, p); mouse(.leftMouseUp, p)
    }
case "drag":
    let a = CGPoint(x: num(1), y: num(2)), b = CGPoint(x: num(3), y: num(4))
    mouse(.mouseMoved, a); mouse(.leftMouseDown, a)
    for i in 1...20 {
        let t = Double(i) / 20
        mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)); usleep(20_000)
    }
    usleep(300_000); mouse(.leftMouseUp, b)
case "scroll":
    if args.count > 3 { mouse(.mouseMoved, CGPoint(x: num(2), y: num(3))) }
    post(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(num(1)), wheel2: 0, wheel3: 0))
case "type":
    typeText(args.dropFirst().joined(separator: " "))
case "key":
    for combo in args.dropFirst() { press(combo) }
case "activate":
    guard args.count > 1 else { die("ui activate APP") }
    app(args[1]).activate(options: [.activateAllWindows])
case "windows", "tree":
    guard args.count > 1 else { die("ui \(cmd) APP") }
    let root = AXUIElementCreateApplication(app(args[1]).processIdentifier)
    let wins = (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if cmd == "windows" { for w in wins { print(describe(w)) } } else {
        var budget = 4000
        let depth = args.count > 2 ? Int(args[2]) ?? 12 : 12
        for w in wins { dump(w, 0, depth, &budget) }
        if budget == 0 { print("… (truncated at 4000 elements; pass a smaller DEPTH)") }
    }
case "press":
    guard args.count > 2 else { die("ui press APP TEXT [N]") }
    let root = AXUIElementCreateApplication(app(args[1]).processIdentifier)
    var hits: [AXUIElement] = []
    find(root, args[2], &hits)
    let n = args.count > 3 ? (Int(args[3]) ?? 1) : 1
    guard hits.count >= n else { die("ui press: \(hits.count) element(s) match \"\(args[2])\"") }
    let r = AXUIElementPerformAction(hits[n - 1], kAXPressAction as CFString)
    guard r == .success else { die("ui press: AXPress failed (\(r.rawValue)) on \(describe(hits[n - 1]))") }
    print(describe(hits[n - 1]))
case "menu":
    guard args.count > 2 else { die("ui menu APP \"Menu>Item\"") }
    let target = app(args[1])
    target.activate(options: [])
    usleep(200_000)
    var el: AXUIElement = attr(AXUIElementCreateApplication(target.processIdentifier), kAXMenuBarAttribute) as! AXUIElement
    for title in args[2].split(separator: ">").map({ $0.trimmingCharacters(in: .whitespaces) }) {
        var next: AXUIElement?
        var queue = children(el)
        while !queue.isEmpty, next == nil {
            let c = queue.removeFirst()
            if str(c, kAXTitleAttribute) == title { next = c } else if str(c, kAXRoleAttribute) == "AXMenu" { queue += children(c) }
        }
        guard let n = next else { die("ui menu: no item \"\(title)\"") }
        AXUIElementPerformAction(n, kAXPressAction as CFString)
        usleep(150_000)
        el = n
    }
default:
    die("ui: unknown command \(cmd)")
}
