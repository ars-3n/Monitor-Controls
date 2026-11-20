// Run with: swift scripts/draw-icon.swift /tmp/MonitorControls.iconset
import AppKit
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
}
for size in [16, 32, 128, 256, 512] {
    for scale in 1...2 {
        let pixels = size * scale
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(pixels) / 128, y: CGFloat(pixels) / 128)
        let base = CGPath(roundedRect: CGRect(x: 7, y: 8, width: 114, height: 114),
                          cornerWidth: 26, cornerHeight: 26, transform: nil)
        ctx.saveGState()
        ctx.addPath(base)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [color(0.14, 0.31, 0.39), color(0.045, 0.14, 0.19)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 15, y: 124), end: CGPoint(x: 105, y: 6), options: [])
        ctx.restoreGState()
        ctx.setLineWidth(5)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color(0.91, 0.97, 0.95))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 27, y: 43, width: 74, height: 50),
                           cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: 64, y: 42))
        ctx.addLine(to: CGPoint(x: 64, y: 34))
        ctx.move(to: CGPoint(x: 49, y: 33))
        ctx.addLine(to: CGPoint(x: 79, y: 33))
        ctx.strokePath()
        for (y, thumb): (CGFloat, CGFloat) in [(76, 57), (60, 75)] {
            ctx.setStrokeColor(color(0.43, 0.72, 0.72))
            ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: 40, y: y))
            ctx.addLine(to: CGPoint(x: 88, y: y))
            ctx.strokePath()
            ctx.setFillColor(color(0.65, 0.97, 0.85))
            ctx.fillEllipse(in: CGRect(x: thumb-4, y: y-4, width: 8, height: 8))
        }
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
    }
}
