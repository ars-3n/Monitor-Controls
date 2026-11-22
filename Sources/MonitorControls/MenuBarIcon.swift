import AppKit

/// What the menu-bar icon shows: a wide monitor holding two sliders, brightness
/// above volume. A level that is unknown keeps its knob at a resting position.
struct MenuBarLevels: Equatable {
    var brightness: Double?
    var volume: Double?
    var muted = false

    /// Rounded to the steps the icon can show, so small changes don't redraw it.
    var shown: MenuBarLevels {
        func step(_ value: Double?) -> Double? { value.map { (min(1, max(0, $0)) * 32).rounded() / 32 } }
        return MenuBarLevels(brightness: step(brightness), volume: step(volume), muted: muted)
    }
}

func menuBarIcon(_ levels: MenuBarLevels = MenuBarLevels()) -> NSImage {
    let image = NSImage(size: NSSize(width: 21, height: 17), flipped: true) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        // A 1x display gets thinner lines that sit on whole pixels. Without
        // that the frame turns into a grey band two pixels wide.
        let fine = abs(context.ctm.a) >= 1.5
        let frame = fine ? CGRect(x: 1.25, y: 2.25, width: 18.5, height: 10.5) : CGRect(x: 1.5, y: 2.5, width: 18, height: 10)
        let foot = fine ? 15.6 : 15.5
        context.setLineWidth(fine ? 1.5 : 1.25)
        context.addPath(CGPath(roundedRect: frame, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil))
        context.move(to: CGPoint(x: 5.6, y: foot))
        context.addLine(to: CGPoint(x: 15.4, y: foot))
        context.strokePath()
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let neck = fine ? 1.5 : 2.0
        context.fill(CGRect(x: 10.5 - neck / 2, y: frame.maxY, width: neck, height: foot - frame.maxY))

        let left = 4.0, right = 17.0, radius = fine ? 1.75 : 1.5
        let rows: [(y: Double, level: Double, dimmed: Bool)] = [
            (5.5, levels.brightness ?? 0.35, false),
            (9.5, levels.volume ?? 0.7, levels.muted),
        ]
        context.setLineWidth(fine ? 1.25 : 1.1)
        for row in rows {
            let exact = left + radius + (right - left - 2 * radius) * min(1, max(0, row.level))
            let knob = fine ? (exact * 2).rounded() / 2 : exact.rounded(.down) + 0.5
            let strength = row.dimmed ? 0.4 : 1
            context.setStrokeColor(CGColor(gray: 0, alpha: strength))
            context.move(to: CGPoint(x: left + 0.6, y: row.y))
            context.addLine(to: CGPoint(x: knob, y: row.y))
            context.strokePath()
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.4 * strength))
            context.move(to: CGPoint(x: knob, y: row.y))
            context.addLine(to: CGPoint(x: right - 0.6, y: row.y))
            context.strokePath()
            context.setFillColor(CGColor(gray: 0, alpha: strength))
            context.fillEllipse(in: CGRect(x: knob - radius, y: row.y - radius, width: 2 * radius, height: 2 * radius))
        }
        return true
    }
    image.isTemplate = true
    return image
}
