// Draws AirSCP's app icon (a terminal prompt with an up and a down arrow on a teal rounded square) and writes
// Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// An arrow pointing up (or down) with its shaft centred on x, between y1 and y2 (y up).
func arrow(_ cg: CGContext, x: CGFloat, from y1: CGFloat, to y2: CGFloat, up: Bool, fill: CGColor) {
    let shaft: CGFloat = 34, head: CGFloat = 96, headLength: CGFloat = 92
    let tip = up ? y2 : y1, base = up ? y2 - headLength : y1 + headLength, tail = up ? y1 : y2
    let path = CGMutablePath()
    path.addLines(between: [
        CGPoint(x: x - shaft / 2, y: tail), CGPoint(x: x - shaft / 2, y: base), CGPoint(x: x - head / 2, y: base),
        CGPoint(x: x, y: tip), CGPoint(x: x + head / 2, y: base), CGPoint(x: x + shaft / 2, y: base),
        CGPoint(x: x + shaft / 2, y: tail),
    ])
    path.closeSubpath()
    cg.addPath(path)
    cg.setFillColor(fill)
    cg.fillPath()
}

/// Draws the icon on a 1024×1024 canvas (y up).
func draw(_ cg: CGContext) {
    // Background: Apple's macOS icon grid, an 824-point rounded square with a soft drop shadow.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.35))
    cg.addPath(body)
    cg.setFillColor(color(12, 92, 98))
    cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(body)
    cg.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(34, 168, 160), color(10, 74, 92)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    cg.restoreGState()

    // A dark terminal panel with a title bar.
    let panel = CGRect(x: 196, y: 250, width: 632, height: 520)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0, 20, 30, 0.45))
    cg.addPath(CGPath(roundedRect: panel, cornerWidth: 56, cornerHeight: 56, transform: nil))
    cg.setFillColor(color(18, 28, 36))
    cg.fillPath()
    cg.restoreGState()
    for (index, dot) in [color(255, 95, 87), color(254, 188, 46), color(40, 200, 64)].enumerated() {
        cg.setFillColor(dot)
        cg.fillEllipse(in: CGRect(x: 246 + CGFloat(index) * 54, y: 696, width: 34, height: 34))
    }

    // The prompt: a chevron and a cursor bar.
    let prompt = color(226, 248, 244)
    cg.setStrokeColor(prompt)
    cg.setLineWidth(42)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.addLines(between: [CGPoint(x: 268, y: 590), CGPoint(x: 368, y: 500), CGPoint(x: 268, y: 410)])
    cg.strokePath()
    cg.setFillColor(prompt)
    cg.fill(CGRect(x: 402, y: 360, width: 120, height: 40))

    // Upload and download.
    arrow(cg, x: 620, from: 330, to: 640, up: true, fill: color(64, 214, 196))
    arrow(cg, x: 740, from: 330, to: 640, up: false, fill: color(255, 196, 92))
}

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let cg = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        draw(cg)
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let destination = CGImageDestinationCreateWithURL(iconset.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("can't write \(name)") }
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output)")
