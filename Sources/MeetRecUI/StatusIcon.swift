import AppKit

public enum StatusIconState: Equatable {
    case idle
    case recording
    case processing(fraction: Double?)
}

public enum StatusIcon {
    public static let size = NSSize(width: 18, height: 18)
    static let red = NSColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
    static let heights: [CGFloat] = [0.35, 0.75, 0.55, 0.9]

    private static func drawBars(in rect: NSRect, color: NSColor, alphas: [CGFloat]) {
        let w: CGFloat = 2.2, gap: CGFloat = 1.8
        let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
        var x = rect.midX - total / 2
        for (i, h) in heights.enumerated() {
            let bh = h * 13
            color.withAlphaComponent(alphas[i]).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - bh / 2, width: w, height: bh), xRadius: w / 2, yRadius: w / 2).fill()
            x += w + gap
        }
    }

    static func alphas(_ fraction: Double?) -> [CGFloat] {
        guard let fraction else { return Array(repeating: 0.4, count: heights.count) }
        return heights.indices.map { fraction >= Double($0 + 1) / Double(heights.count) - 0.125 ? 1 : 0.4 }
    }

    public static func image(_ state: StatusIconState, dark: Bool) -> NSImage {
        let ink = dark ? NSColor.white : NSColor.black
        let image = NSImage(size: size, flipped: false) { rect in
            switch state {
            case .idle:
                drawBars(in: rect, color: .black, alphas: Array(repeating: 1, count: heights.count))
            case .recording:
                drawBars(in: rect, color: ink, alphas: Array(repeating: 1, count: heights.count))
                red.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 6, height: 6)).fill()
            case let .processing(fraction):
                drawBars(in: rect, color: ink, alphas: alphas(fraction))
            }
            return true
        }
        image.isTemplate = state == .idle
        image.accessibilityDescription = "MeetRec"
        return image
    }
}
