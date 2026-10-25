import AppKit
import DockCore

/// Lifts an app icon's glyph off its rounded tile and lays it on a full-bleed ground, so an
/// icon key fills the key edge to edge like every state color (no rounded tile inside a key).
///
/// The glyph is whatever differs from the tile's own color: opacity grows with the color
/// distance from the tile, and edge pixels are un-blended from it. Only the icon's middle is
/// read, which drops the tile's rim and highlights.
enum IconGlyph {
    static let side = 512
    /// The share of the icon read (centered); the tile's rounded rim lies outside it.
    static let body = 0.68
    /// Where the tile color is sampled: top middle, inside the tile, above the glyph.
    static let tileSample = (x: 0.5, y: 0.14)
    /// Color distance (0...√3) at which a pixel starts to count as glyph, and is fully glyph.
    /// Above the tile's own gradient (up to ~0.15 top to bottom), below a glyph's (white on
    /// Claude orange ≈ 0.9, the lightest Codex cloud on white ≈ 0.4).
    static let distance = (low: 0.20, high: 0.42)
    /// The glyph's size relative to the icon: a little larger, to read on a 64-px key.
    static let scale = 1.2

    static func key(icon: NSImage, ground: RGB, output: Int = 256) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: side * 4, bitsPerPixel: 32),
              let source = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        func color(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * side + x) * 4
            let alpha = max(1, Double(source[i + 3]))  // Stored premultiplied.
            return (Double(source[i]) / alpha, Double(source[i + 1]) / alpha, Double(source[i + 2]) / alpha)
        }
        let tile = color(Int(tileSample.x * Double(side)), Int(tileSample.y * Double(side)))
        // The glyph, premultiplied RGBA.
        var glyph = [UInt8](repeating: 0, count: side * side * 4)
        let inset = Int(Double(side) * (1 - body) / 2)
        for y in inset..<(side - inset) { for x in inset..<(side - inset) {
            let p = color(x, y)
            let d = ((p.0 - tile.0) * (p.0 - tile.0) + (p.1 - tile.1) * (p.1 - tile.1) + (p.2 - tile.2) * (p.2 - tile.2)).squareRoot()
            let a = min(1, max(0, (d - distance.low) / (distance.high - distance.low)))
            guard a > 0.1 else { continue }
            // Un-blend from the tile: the color this pixel would have at full coverage.
            func lift(_ v: Double, _ t: Double) -> UInt8 { UInt8((min(1, max(0, t + (v - t) / a)) * a * 255).rounded()) }
            let i = (y * side + x) * 4
            glyph[i] = lift(p.0, tile.0); glyph[i + 1] = lift(p.1, tile.1); glyph[i + 2] = lift(p.2, tile.2)
            glyph[i + 3] = UInt8((a * 255).rounded())
        } }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let lifted = glyph.withUnsafeMutableBytes({ buffer in
            CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }), let out = CGContext(data: nil, width: output, height: output, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        out.interpolationQuality = .high
        out.setFillColor(CGColor(colorSpace: space, components: [CGFloat(ground.red) / 255, CGFloat(ground.green) / 255, CGFloat(ground.blue) / 255, 1])!)
        out.fill(CGRect(x: 0, y: 0, width: output, height: output))
        let drawn = Double(output) * scale
        let origin = (Double(output) - drawn) / 2
        out.draw(lifted, in: CGRect(x: origin, y: origin, width: drawn, height: drawn))
        guard let image = out.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
