import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default

func drawIcon(_ s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = s / 1024
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24 * k
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(red: 0.42, green: 0.30, blue: 0.95, alpha: 1),
               ending: NSColor(red: 0.10, green: 0.45, blue: 0.98, alpha: 1))!.draw(in: shape, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: 420 * k, weight: .bold)
    if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let size = tinted.size
        tinted.draw(in: NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2, width: size.width, height: size.height))
    }

    let dot = NSRect(x: body.maxX - 190 * k, y: body.maxY - 190 * k, width: 130 * k, height: 130 * k)
    let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -8 * k, dy: -8 * k))
    NSColor.white.setFill()
    ring.fill()
    NSColor(red: 1, green: 0.19, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let tmp = fm.temporaryDirectory.appendingPathComponent("meetrec-icon-\(getpid())")
let iconset = tmp.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }

for base in [16, 32, 128, 256, 512] {
    try write(drawIcon(CGFloat(base)), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try write(drawIcon(CGFloat(base * 2)), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let resources = root.appendingPathComponent("Resources")
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
let out = resources.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
if CommandLine.arguments.count > 1 { try write(drawIcon(1024), to: URL(fileURLWithPath: CommandLine.arguments[1])) }
print(out.path)
