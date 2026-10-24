import AppKit
import DockCore

/// Picks a few vivid, distinct colors from album artwork, tuned for LEDs (see `refine`).
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

        // Hue histogram in 24 buckets, weighted towards saturated, bright pixels.
        let bucketCount = 24
        var weight = [Double](repeating: 0, count: bucketCount)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: bucketCount)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let color = NSColor(
                srgbRed: CGFloat(pixels[index]) / 255, green: CGFloat(pixels[index + 1]) / 255,
                blue: CGFloat(pixels[index + 2]) / 255, alpha: 1
            )
            let saturation = Double(color.saturationComponent)
            let brightness = Double(color.brightnessComponent)
            guard saturation > 0.2, brightness > 0.2 else { continue }
            let bucket = min(bucketCount - 1, Int(Double(color.hueComponent) * Double(bucketCount)))
            let w = saturation * saturation * brightness
            weight[bucket] += w
            sums[bucket].r += Double(color.redComponent) * w
            sums[bucket].g += Double(color.greenComponent) * w
            sums[bucket].b += Double(color.blueComponent) * w
        }

        // Strongest hues first, skipping ones too close to a color already picked.
        let total = weight.reduce(0, +)
        // Nothing colorful at all (black-and-white artwork): a soft warm white.
        guard total > 0 else { return refine([]) }
        var picked: [(hue: Double, color: NSColor)] = []
        for bucket in weight.indices.sorted(by: { weight[$0] > weight[$1] }) {
            guard weight[bucket] > total * 0.04, picked.count < maxColors else { break }
            let color = NSColor(
                srgbRed: sums[bucket].r / weight[bucket], green: sums[bucket].g / weight[bucket],
                blue: sums[bucket].b / weight[bucket], alpha: 1
            )
            let hue = Double(color.hueComponent)
            guard picked.allSatisfy({ hueDistance($0.hue, hue) > 0.08 }) else { continue }
            picked.append((hue, color))
        }
        return refine(picked.map { item in
            RGB(
                UInt8((item.color.redComponent * 255).rounded()),
                UInt8((item.color.greenComponent * 255).rounded()),
                UInt8((item.color.blueComponent * 255).rounded())
            )
        })
    }

    /// Light-strip color grading, in OKLCh. An LED shows a color at whatever brightness the
    /// glow asks for, so only hue and chroma matter here:
    /// - washed-out colors get chroma up to `minChroma` (a dull blue-grey cover still glows
    ///   blue), vivid ones a gentle boost (`chromaBoost`);
    /// - lightness is free: each color moves to the lightness where its hue can be that vivid
    ///   in sRGB (yellow is only vivid when light, blue when dark), staying near its own;
    ///   a dark brown becomes the warm amber it is a shade of;
    /// - a single hue gets an analogous partner `partnerShift` radians away, so the flow has
    ///   something to move against; no hue at all gives a soft warm white pair.
    static let minChroma = 0.1, chromaBoost = 1.15, partnerShift = 0.45
    static func refine(_ colors: [RGB]) -> [RGB] {
        let neutral = 0.02
        let labs = colors.map(OKLab.init(srgb:)).filter { $0.chroma > neutral }
        guard let first = labs.first else {
            return [OKLab(l: 0.9, chroma: 0.04, hue: 1.2), OKLab(l: 0.85, chroma: 0.06, hue: 0.9)].map(\.srgb)
        }
        var graded = labs.map { vivid(hue: $0.hue, chroma: max(minChroma, $0.chroma * chromaBoost), near: $0.l) }
        if graded.count == 1 {
            graded.append(vivid(hue: first.hue + partnerShift, chroma: graded[0].chroma * 0.8, near: graded[0].l + 0.05))
        }
        return graded.map(\.srgb)
    }

    /// The color of this hue closest to `chroma`, at the lightness (0.5…0.97) that allows it,
    /// preferring one near `near`.
    static func vivid(hue: Double, chroma: Double, near lightness: Double) -> OKLab {
        var best = OKLab(l: 0.75, a: 0, b: 0), bestScore = -Double.infinity
        for l in stride(from: 0.5, through: 0.97, by: 0.01) {
            // Largest in-gamut chroma at this lightness, by bisection.
            var low = 0.0, high = 0.4
            for _ in 0..<20 {
                let mid = (low + high) / 2
                if OKLab(l: l, chroma: mid, hue: hue).isInGamut { low = mid } else { high = mid }
            }
            let reached = min(chroma, low)
            let score = reached - 0.05 * abs(l - min(0.92, max(0.55, lightness)))
            if score > bestScore {
                bestScore = score
                best = OKLab(l: l, chroma: reached, hue: hue)
            }
        }
        return best
    }

    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }
}
