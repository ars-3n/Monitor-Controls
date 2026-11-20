import AppKit

func soundLevelsIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(1.45)
        context.setLineCap(.round)
        let screen = CGRect(x: 0.85, y: 3.8, width: 16.3, height: 11.1)
        context.addPath(CGPath(roundedRect: screen, cornerWidth: 1.7, cornerHeight: 1.7, transform: nil))
        context.move(to: CGPoint(x: 9, y: 3.8))
        context.addLine(to: CGPoint(x: 9, y: 1))
        context.move(to: CGPoint(x: 6, y: 1))
        context.addLine(to: CGPoint(x: 12, y: 1))

        for (x, height) in [(5.6, 2.1), (9.0, 5.5), (12.4, 3.4)] {
            context.move(to: CGPoint(x: x, y: screen.midY - height / 2))
            context.addLine(to: CGPoint(x: x, y: screen.midY + height / 2))
        }
        context.strokePath()
        return true
    }
    image.isTemplate = true
    return image
}
