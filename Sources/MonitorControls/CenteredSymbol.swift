import SwiftUI

/// A system symbol whose drawn shape lands in the middle of a square.
///
/// macOS puts a symbol on whole pixels. One whose ink is an odd number of
/// pixels wide then sits half a pixel to the side of an even-sized circle.
/// Moving it by the fraction would blur it, so this shows the symbol at a
/// slightly larger size at which its own placement comes out centered.
struct CenteredSymbol: View {
    let name: String
    let pointSize: CGFloat
    let weight: Font.Weight
    let side: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Image(systemName: name)
            .font(.system(size: SymbolFit.shared.size(self, scale: displayScale), weight: weight))
            .frame(width: side, height: side)
    }
}

/// Finds each symbol's centered size a little at a time, so the search never
/// holds up drawing. Until a size is known the symbol shows at its plain size.
@MainActor @Observable
final class SymbolFit {
    static let shared = SymbolFit()
    private var sizes: [String: CGFloat] = [:]
    @ObservationIgnored private var started: Set<String> = []
    /// How far the symbol may grow, and the offset that counts as centered, in points.
    private static let growth = 2.0, tolerance = 0.1

    /// Works out sizes ahead of the first time the panel opens.
    func prepare(_ symbols: [CenteredSymbol], scales: Set<CGFloat>) {
        for scale in scales { for symbol in symbols { _ = size(symbol, scale: scale) } }
    }

    func size(_ symbol: CenteredSymbol, scale: CGFloat) -> CGFloat {
        let key = "\(symbol.name)|\(symbol.pointSize)|\(symbol.weight.hashValue)|\(symbol.side)|\(scale)"
        if let size = sizes[key] { return size }
        if started.insert(key).inserted {
            Task {
                var best = (size: symbol.pointSize, offset: Double.infinity)
                for step in 0...Int(Self.growth * 10) {
                    let size = symbol.pointSize + CGFloat(step) / 10
                    guard let offset = Self.offset(symbol, size: size, scale: scale) else { break }
                    if offset < best.offset - 0.02 { best = (size, offset) }
                    if offset <= Self.tolerance { break }
                    await Task.yield()
                }
                sizes[key] = best.size
            }
        }
        return symbol.pointSize
    }

    /// How far the symbol's ink sits from the middle at this screen scale.
    /// The same drawing at high resolution says where a centered symbol's
    /// weight would be, since few symbols are symmetric.
    private static func offset(_ symbol: CenteredSymbol, size: CGFloat, scale: CGFloat) -> Double? {
        let view = Image(systemName: symbol.name)
            .font(.system(size: size, weight: symbol.weight))
            .foregroundStyle(.white)
            .frame(width: symbol.side, height: symbol.side)
            .background(Color.black)
        guard let fine = ink(view, scale: 8), let shown = ink(view, scale: scale) else { return nil }
        let x = shown.weight.x - (fine.weight.x - fine.box.x), y = shown.weight.y - (fine.weight.y - fine.box.y)
        return max(abs(x), abs(y))
    }

    /// The middle of the ink's bounding box and the ink's weighted middle, in points from the center.
    private static func ink(_ view: some View, scale: CGFloat) -> (box: CGPoint, weight: CGPoint)? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, maxX = -1, minY = height, maxY = -1
        var sumX = 0.0, sumY = 0.0, sum = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let value = Double(pixels[y * width + x]) / 255
                guard value > 0 else { continue }
                if value > 0.5 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                sumX += value * (Double(x) + 0.5); sumY += value * (Double(y) + 0.5); sum += value
            }
        }
        guard maxX >= minX, maxY >= minY, sum > 0 else { return nil }
        return (CGPoint(x: (Double(minX + maxX + 1) - Double(width)) / 2 / scale,
                        y: (Double(minY + maxY + 1) - Double(height)) / 2 / scale),
                CGPoint(x: (sumX / sum - Double(width) / 2) / scale, y: (sumY / sum - Double(height) / 2) / scale))
    }
}
