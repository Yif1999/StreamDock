import AppKit
import DockCore

/// The colors album artwork gives the light strip, as the cover has them (see `palette`).
public enum ArtworkPalette {
    static let fallback = [RGB(255, 214, 170), RGB(255, 170, 120)]

    public static func colors(from data: Data, maxColors: Int = 4) -> [RGB] {
        guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }
        return colors(from: image, maxColors: maxColors)
    }

    static func colors(from image: CGImage, maxColors: Int = 4) -> [RGB] {
        let side = 32
        // Let CoreGraphics own the buffer (an `&array` pointer is only valid during the init
        // call) and pin the byte order to R, G, B, A.
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return fallback }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let buffer = context.data else { return fallback }
        let pixels = Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
        return palette(from: stride(from: 0, to: pixels.count, by: 4).map {
            OKLab(srgb: RGB(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]))
        }, maxColors: maxColors)
    }

    /// The light the cover gives off, as it is (2026-10-25: grading that lifted chroma made
    /// near-grey covers glow saturated blue, a color they do not have):
    /// - a pixel is colored when its OKLab chroma reaches `colorChroma` (HSV saturation would
    ///   call dark pixels vivid);
    /// - every pixel counts by area, except black: an uncolored pixel darker than lightness 0.3
    ///   fades out (nothing under 0.2), since black gives no light; white and grey areas count
    ///   as white light. Dark colored pixels (deep green hair, a navy sky) count in full;
    /// - a hue enters the palette only with at least `minShare` of the cover's light, so a few
    ///   stray pixels never set the colors; up to `maxColors` hues, strongest first, each the
    ///   plain average of its pixels — no chroma lift, no lightness change, no invented partner;
    /// - uncolored light with at least `whiteShare` adds a white tinted like those pixels; a
    ///   cover with no hue at all is that white alone;
    /// - a single color gets a paler shade of itself, so the flow has something to move against.
    static let colorChroma = 0.04, minShare = 0.05, whiteShare = 0.3
    static func palette(from pixels: [OKLab], maxColors: Int = 4) -> [RGB] {
        let bucketCount = 24
        var light = [Double](repeating: 0, count: bucketCount)
        var sums = [OKLab](repeating: OKLab(l: 0, a: 0, b: 0), count: bucketCount)
        var white = 0.0, whiteSum = OKLab(l: 0, a: 0, b: 0), total = 0.0
        for pixel in pixels {
            let colored = pixel.chroma >= colorChroma
            let weight = colored ? 1 : min(1, max(0, (pixel.l - 0.2) / 0.1))
            total += weight
            guard colored else {
                white += weight
                whiteSum = OKLab(l: whiteSum.l + pixel.l * weight, a: whiteSum.a + pixel.a * weight, b: whiteSum.b + pixel.b * weight)
                continue
            }
            let turn = (pixel.hue / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
            let bucket = min(bucketCount - 1, Int(turn * Double(bucketCount)))
            light[bucket] += weight
            sums[bucket] = OKLab(l: sums[bucket].l + pixel.l * weight, a: sums[bucket].a + pixel.a * weight, b: sums[bucket].b + pixel.b * weight)
        }
        guard total > 0.01 else { return fallback }

        var members: [(light: Double, color: OKLab)] = []
        for bucket in light.indices.sorted(by: { light[$0] > light[$1] }) {
            guard light[bucket] >= total * minShare, members.count < maxColors else { break }
            let w = light[bucket]
            let color = OKLab(l: sums[bucket].l / w, a: sums[bucket].a / w, b: sums[bucket].b / w)
            guard members.allSatisfy({ hueDistance($0.color.hue, color.hue) > 0.5 }) else { continue }
            members.append((w, color))
        }
        if white >= total * whiteShare || members.isEmpty {
            // The tint of the uncolored pixels, shown as light (lightness is the strip's business).
            let tint = OKLab(l: 0.9, a: whiteSum.a / max(white, 1e-6), b: whiteSum.b / max(white, 1e-6))
            members.append((white, tint))
            members.sort { $0.light > $1.light }
        }
        var colors = members.map(\.color)
        if colors.count == 1, let only = colors.first {
            colors.append(OKLab(l: min(0.95, only.l + 0.05), chroma: only.chroma * 0.7, hue: only.hue))
        }
        return colors.map(\.srgb)
    }

    /// Hue distance in radians, 0…π.
    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
        return min(d, 2 * .pi - d)
    }
}
