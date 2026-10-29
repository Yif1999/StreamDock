import AppKit

/// What a key's state means; the only thing a module says about color. `KeyDesign` turns it
/// into the one palette every key shares.
public enum KeyTone: Hashable, Sendable {
    /// An action: white glyph, grey label.
    case normal
    /// Unavailable right now.
    case dim
    /// A toggle that is on: white key, black glyph (like Control Center).
    case on
    /// Recording, muted, destructive: red key.
    case alert
    /// Live output (streaming): green key, matching the light strip.
    case live
    /// Waiting on the user (hold countdown): amber key.
    case caution
}

/// The key design system for the M18's 64×64 keys, shown 1:1 on the panel (verified with a
/// 1-px checkerboard). Pure black ground, so a key blends into the black window around it;
/// one glyph box and one label line on a fixed grid; color only from `KeyTone`.
///
/// Glyphs and text are drawn at 4× and box-filtered down exactly, then edge contrast is raised
/// (`edge`), so strokes land as solid pixels with a thin ramp instead of a grey halo.
public enum KeyDesign {
    static let side = 64
    static let supersample = 4

    // Grid (pixels). Like Apple's small-screen layouts: an even margin all round, the label on
    /// one fixed baseline for every key (so labels line up across a row, Latin and CJK alike),
    /// and the glyph or value centered by its actual ink in the space left above it.
    static let margin = 8
    static let labelBaseline = 55.0, labelSize = 11.0, labelTracking = 0.5, labelWidth = 56.0
    /// Space between the glyph's ink and the label's top.
    static let labelGap = 6
    /// Share of the spare height above a labeled glyph or value (the rest goes below it).
    static let labelLean = 0.75
    static let glyphBox = 36, glyphBoxLabeled = 28
    static let valueSize = 23.0, valueWidth = 50.0, valueBaseline = 40.0
    /// Touch, in one language (docs/design.md, 按下与长按):
    /// - A key that acts on a tap turns over when pressed — each ground swaps with the ink on it
    ///   (black with white ink goes white with black, green with black goes black with green, a
    ///   meter's fill goes black with ink in its color) — from the edge inward, the part a
    ///   fingertip leaves in sight.
    /// - A long-press key does not turn over when pressed: its ring appears from just outside and
    ///   closes in, then sweeps round; when the hold fires, the key turns over from the ring both
    ///   ways, out over the rim and in to the middle, and fades back.
    /// - Artwork (an app icon, an album cover) is the content itself and is never recolored: a
    ///   press sinks it, shrinking `pressSink` px into a black rim — in step with the ring on a
    ///   long-press key, since both run on the same clock — and a fired hold springs it back up
    ///   (`Motion.settle`) while the closed ring fades.
    /// Pressing, closing in and their reverse all take `pressTime` on `Motion.ease`; `press` is how
    /// far a tap key is down (0 ... 1), driven by the controller on the same curve.
    public static let pressTime = 0.2, pressSink = 5.0
    /// The hold ring: this wide, settling this far in from the edge (so a light key keeps a rim
    /// of its own color between the ring and the black window), drawn from the top middle,
    /// clockwise, its head sweeping round at an even pace. It closes in over the first
    /// `pressTime` of the hold (1 s, `KeyHold.duration`).
    static let holdWidth = 3.0, holdInset = 2.0, holdCloseIn = pressTime / 1.0
    /// How far a long-press key has closed in (0 ... 1) at a point of the hold.
    static func closedIn(_ progress: Double) -> Double { Motion.ease(progress / holdCloseIn) }
    /// Where the ring's outer edge is at a point of the hold: from just outside the key (out of
    /// sight) to `holdInset`.
    static func holdRingInset(_ progress: Double) -> Double {
        let outside = -holdWidth - 1
        return holdInset + (outside - holdInset) * (1 - closedIn(progress))
    }
    /// How far a fired hold has turned the key over, and how strongly: spreading for the first
    /// 45 % of the response, fading back over the rest.
    static func turnOver(_ t: Double) -> (coverage: [Double], opacity: Double) {
        let spread = Motion.ease(t / 0.45) * Double(side) / 2
        let outer = max(0, holdInset - spread), inner = min(Double(side) / 2, holdInset + holdWidth + spread)
        return (ringMask(sweep: 1, inset: outer, width: inner - outer), 1 - Motion.ease((t - 0.45) / 0.55))
    }
    /// Alpha ramp after downsampling: coverage below `low` drops, above `high` is solid.
    static let edge = (low: 0.12, high: 0.82)

    struct Palette {
        let tile: RGB?; let glyph: RGB; let label: RGB
        /// Ground and ink swapped (a key turned over); the label is the new ink a third of the
        /// way into the new ground.
        var swapped: Palette {
            let ground = glyph, ink = tile ?? .black
            return Palette(tile: ground, glyph: ink, label: ink.mixed(with: ground, amount: 0.35))
        }
    }
    /// Ink over a meter's fill: black glyph, the fill's own color darkened for the label.
    static let meterLabelShade = 0.35

    static func palette(_ tone: KeyTone) -> Palette {
        switch tone {
        case .normal: Palette(tile: nil, glyph: .white, label: RGB(hex: "#8E8E93"))
        case .dim: Palette(tile: nil, glyph: RGB(hex: "#4A4A4E"), label: RGB(hex: "#3E3E42"))
        case .on: Palette(tile: .white, glyph: .black, label: RGB(hex: "#3A3A3C"))
        case .alert: Palette(tile: RGB(hex: "#FF3B30"), glyph: .white, label: RGB(hex: "#FFD7D4"))
        case .live: Palette(tile: RGB(hex: "#30D158"), glyph: .black, label: RGB(hex: "#0B3D1A"))
        case .caution: Palette(tile: RGB(hex: "#FF9F0A"), glyph: .black, label: RGB(hex: "#4A2C00"))
        }
    }

    /// Renders a face: artwork edge to edge, or glyph / value with an optional label.
    public static func image(symbol: String? = nil, value: String? = nil, label: String? = nil,
                             tone: KeyTone = .normal, artwork: Data? = nil, meter: KeyMeter? = nil,
                             hold: HoldPhase? = nil, press: Double = 0) -> CGImage? {
        let colors = palette(meter == nil ? tone : .normal)
        if let artwork, let picture = NSImage(data: artwork) {
            // Sinks with a press, or with the ring on a long press (same clock, so in step).
            let sunk: Double
            switch hold {
            case .holding(let progress): sunk = closedIn(progress)
            case .released(let from, let t): sunk = closedIn(from) * (1 - Motion.ease(t))
            // Fired: it springs back up, a little past full size and back (`Motion.settle`).
            case .confirmed(let t): sunk = 1 - Motion.settle(t)
            case nil: sunk = min(1, max(0, press))
            }
            var canvas = Canvas(side: side)
            canvas.draw(picture: picture, inset: pressSink * sunk)
            if let hold { canvas.drawRing(hold, ink: nil) }
            return canvas.image()
        }
        // Layout first (the same whatever the colors): the label, then the glyph or value above it.
        var labelInk: [Double]?
        var contentBottom = side - margin
        if let label {
            let text = textMask(label, size: labelSize, weight: .medium, rounded: false, baseline: labelBaseline,
                                maxWidth: labelWidth, tracking: labelTracking)
            if let ink = inkBounds(text) {
                labelInk = shifted(text, dx: side / 2 - (ink.minX + ink.maxX + 1) / 2, dy: 0)
                contentBottom = ink.minY - labelGap
            }
        }
        let main: [Double]?
        /// A value sits by its type, not its ink: centered by its advance (tabular figures, so
        /// every digit is as wide as any other) and placed by its cap height on a fixed baseline,
        /// so 52 → 55 changes only the digits, never their place.
        var valueBox: (top: Int, height: Int)?
        if let value {
            let text = textLayout(value, size: valueSize, weight: .semibold, rounded: true, tabular: true, baseline: valueBaseline,
                                  maxWidth: valueWidth, tracking: -0.3)
            main = text.mask
            let height = Int(text.capHeight.rounded())
            valueBox = (Int(valueBaseline) - height, height)
        } else if let symbol {
            main = symbolMask(symbol, box: label == nil ? glyphBox : glyphBoxLabeled)
        } else {
            main = nil
        }
        var mainInk: [Double]?
        if let main, let ink = inkBounds(main) {
            let dx = valueBox == nil ? side / 2 - (ink.minX + ink.maxX + 1) / 2 : 0
            let height = valueBox?.height ?? ink.maxY - ink.minY + 1
            let inkTop = valueBox?.top ?? ink.minY
            let top: Int
            if label != nil {
                // With a label the two read as one group: the content leans on the label, the
                // spare space split 3:1 above:below — centered, a short value floats off it.
                top = margin + Int((Double(contentBottom - margin - height) * labelLean).rounded())
            } else {
                top = margin + (contentBottom - margin - height) / 2
            }
            mainInk = shifted(main, dx: dx, dy: top - inkTop)
        }
        // A meter fills whole columns from the left; ink takes the color of whatever is under it,
        // so a value split by the edge reads in two colors (black on the fill, white on black).
        let split = meter.map { Int((min(1, max(0, $0.fraction)) * Double(side)).rounded()) } ?? 0
        /// The colors of one look: the ground and the ink on it, and the same over a meter's fill.
        struct Look { let ground: RGB, glyph: RGB, label: RGB, fill: RGB, glyphOnFill: RGB, labelOnFill: RGB }
        let fill = meter?.color ?? .black
        let normal = Look(ground: colors.tile ?? .black, glyph: colors.glyph, label: colors.label,
                          fill: fill, glyphOnFill: .black, labelOnFill: fill.scaled(by: meterLabelShade))
        func render(_ look: Look) -> Canvas {
            var canvas = Canvas(side: side)
            // A state fills the whole key (the panel's black window frames it).
            canvas.fill(look.ground)
            if meter != nil { canvas.fill(look.fill, columns: 0..<split) }
            func paint(_ coverage: [Double], _ color: RGB, onFill: RGB) {
                guard split > 0 else { return canvas.composite(coverage, color: color, sharpen: true) }
                canvas.composite(coverage, color: onFill, sharpen: true, columns: 0..<split)
                canvas.composite(coverage, color: color, sharpen: true, columns: split..<side)
            }
            if let labelInk { paint(labelInk, look.label, onFill: look.labelOnFill) }
            if let mainInk { paint(mainInk, look.glyph, onFill: look.glyphOnFill) }
            return canvas
        }
        let swapped = colors.swapped
        let turned = Look(ground: swapped.tile ?? .black, glyph: swapped.glyph, label: swapped.label,
                          fill: .black, glyphOnFill: fill, labelOnFill: fill.mixed(with: .black, amount: 0.35))
        var canvas = render(normal)
        switch hold {
        case .confirmed(let t):
            let turn = turnOver(t)
            canvas.blend(render(turned), coverage: turn.coverage, opacity: turn.opacity)
        case .holding, .released:
            // The ring is drawn in the key's own ink (black over a fill), the color the key turns
            // to when it fires.
            canvas.drawRing(hold!, ink: { i in i % side < split ? normal.glyphOnFill : normal.glyph })
        case nil where press > 0:
            // A tap key turns over from the edge inward.
            let down = min(1, press)
            canvas.blend(render(turned), coverage: down >= 1 ? nil : ringMask(sweep: 1, inset: 0, width: Double(side) / 2 * down), opacity: 1)
        case nil:
            break
        }
        return canvas.image()
    }

    /// The hold ring's coverage: a band `width` wide whose outer edge is `inset` in from the key's
    /// edge (negative: outside it), `sweep` (0...1) of the way round clockwise from the top middle.
    static func ringMask(sweep: Double, inset: Double, width: Double) -> [Double] {
        let n = Double(supersample), o = (inset + width / 2) * n, far = Double(side) * n - o, middle = Double(side) * n / 2
        let corners = [(far, o), (far, far), (o, far), (o, o), (middle, o)]
        let length = 4 * (far - o)
        return mask(side) { _ in
            let path = NSBezierPath()
            path.lineWidth = width * n
            path.lineCapStyle = .butt
            path.lineJoinStyle = .miter
            if sweep >= 1 {
                path.appendRect(NSRect(x: o, y: o, width: far - o, height: far - o))
            } else {
                var left = max(0, sweep) * length
                var at = (middle, o)
                path.move(to: NSPoint(x: at.0, y: at.1))
                for corner in corners where left > 0 {
                    let step = hypot(corner.0 - at.0, corner.1 - at.1), f = min(1, left / step)
                    at = (at.0 + (corner.0 - at.0) * f, at.1 + (corner.1 - at.1) * f)
                    path.line(to: NSPoint(x: at.0, y: at.1))
                    left -= step
                }
            }
            path.stroke()
        }
    }

    // MARK: - Masks (coverage 0...1 at 64×64)

    /// Draws into a transparent 4× context (y down) and box-filters its alpha down to 64×64.
    static func mask(_ side: Int, draw: (NSRect) -> Void) -> [Double] {
        let big = side * supersample
        var pixels = [UInt8](repeating: 0, count: big * big * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: big, height: big, bitsPerComponent: 8, bytesPerRow: big * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: 0, y: CGFloat(big)); context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            NSColor.white.setFill()
            draw(NSRect(x: 0, y: 0, width: big, height: big))
            NSGraphicsContext.restoreGraphicsState()
        }
        var coverage = [Double](repeating: 0, count: side * side)
        let n = supersample
        for y in 0..<side { for x in 0..<side {
            var sum = 0
            for dy in 0..<n { for dx in 0..<n { sum += Int(pixels[((y * n + dy) * big + x * n + dx) * 4 + 3]) } }
            coverage[y * side + x] = Double(sum) / Double(255 * n * n)
        } }
        return coverage
    }

    /// The symbol scaled to fit `box` with its size in whole pixels (placed later by its ink).
    static func symbolMask(_ name: String, box: Int) -> [Double] {
        let n = CGFloat(supersample)
        let configuration = NSImage.SymbolConfiguration(pointSize: CGFloat(box) * n * 0.8, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return textMask("?", size: 24, weight: .bold, rounded: true, baseline: 40, maxWidth: 40, tracking: 0)
        }
        let scale = min(CGFloat(box) * n / symbol.size.width, CGFloat(box) * n / symbol.size.height)
        // Whole pixels at 64×64 = multiples of `supersample` here.
        let width = (symbol.size.width * scale / n).rounded() * n
        let height = (symbol.size.height * scale / n).rounded() * n
        let x = ((CGFloat(side) * n - width) / 2 / n).rounded(.down) * n
        let y = ((CGFloat(side) * n - height) / 2 / n).rounded(.down) * n
        return mask(side) { _ in symbol.draw(in: NSRect(x: x, y: y, width: width, height: height)) }
    }

    /// One line of text on `baseline`, shrunk until it fits `maxWidth`, centered by its advance.
    /// `tracking` is extra space between characters, in pixels (small sizes read better looser).
    static func textMask(_ text: String, size: Double, weight: NSFont.Weight, rounded: Bool, baseline: Double,
                         maxWidth: Double, tracking: Double) -> [Double] {
        textLayout(text, size: size, weight: weight, rounded: rounded, tabular: false, baseline: baseline,
                   maxWidth: maxWidth, tracking: tracking).mask
    }

    /// `textMask`, with the cap height of the size it settled on (pixels). `tabular`: every
    /// figure takes the same width, so a changing number keeps its place.
    static func textLayout(_ text: String, size: Double, weight: NSFont.Weight, rounded: Bool, tabular: Bool,
                           baseline: Double, maxWidth: Double, tracking: Double) -> (mask: [Double], capHeight: Double) {
        let n = CGFloat(supersample)
        var fontSize = CGFloat(size)
        var attributed: NSAttributedString
        var font: NSFont
        repeat {
            let base = NSFont.systemFont(ofSize: fontSize * n, weight: weight)
            var descriptor = rounded ? (base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor) : base.fontDescriptor
            if tabular {
                descriptor = descriptor.addingAttributes([.featureSettings: [[
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]]])
            }
            font = NSFont(descriptor: descriptor, size: fontSize * n) ?? base
            attributed = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.white, .kern: CGFloat(tracking) * n,
            ])
            fontSize -= 0.5
        } while attributed.size().width > CGFloat(maxWidth) * n && fontSize > 7
        let x = ((CGFloat(side) * n - attributed.size().width) / 2 / n).rounded() * n
        // In this flipped context a line is drawn from its top: baseline − ascender.
        let y = CGFloat(baseline) * n - font.ascender
        return (mask(side) { _ in attributed.draw(at: NSPoint(x: x, y: y)) }, Double(font.capHeight / n))
    }

    /// The pixel rows and columns that carry ink (coverage above a quarter).
    static func inkBounds(_ coverage: [Double]) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var result: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
        for y in 0..<side { for x in 0..<side where coverage[y * side + x] > 0.25 {
            if let r = result {
                result = (min(r.minX, x), max(r.maxX, x), min(r.minY, y), max(r.maxY, y))
            } else {
                result = (x, x, y, y)
            }
        } }
        return result
    }

    /// The mask moved by whole pixels.
    static func shifted(_ coverage: [Double], dx: Int, dy: Int) -> [Double] {
        var out = [Double](repeating: 0, count: side * side)
        for y in 0..<side { for x in 0..<side {
            let sx = x - dx, sy = y - dy
            if (0..<side).contains(sx), (0..<side).contains(sy) { out[y * side + x] = coverage[sy * side + sx] }
        } }
        return out
    }

    // MARK: - Canvas

    struct Canvas {
        let side: Int
        var pixels: [Double]   // RGB 0...1

        init(side: Int) { self.side = side; pixels = Array(repeating: 0, count: side * side * 3) }

        mutating func fill(_ color: RGB, columns: Range<Int>? = nil) {
            let columns = columns ?? 0..<side
            for i in 0..<(side * side) where columns.contains(i % side) { set(i, color, 1) }
        }

        mutating func composite(_ coverage: [Double], color: RGB, sharpen: Bool, columns: Range<Int>? = nil) {
            let columns = columns ?? 0..<side
            for i in coverage.indices where columns.contains(i % side) {
                var a = coverage[i]
                if sharpen { a = min(1, max(0, (a - edge.low) / (edge.high - edge.low))) }
                if a > 0 { set(i, color, a) }
            }
        }

        /// The hold ring (`HoldPhase`) in the key's ink at each pixel; on artwork, which has none,
        /// in whichever of white or black stands out from what is under it.
        mutating func drawRing(_ phase: HoldPhase, ink: ((Int) -> RGB)?) {
            let coverage: [Double]
            switch phase {
            case .holding(let progress):
                // Closes in from just outside the key while the head sweeps round.
                coverage = ringMask(sweep: progress, inset: holdRingInset(progress), width: holdWidth)
            case .released(let from, let t):
                // Let go: the ring, as far round as it got, slips back out the way it came.
                let start = holdRingInset(from), outside = -holdWidth - 1
                coverage = ringMask(sweep: from, inset: start + (outside - start) * Motion.ease(t), width: holdWidth)
            case .confirmed(let t):
                // Only artwork draws this (other keys turn over instead): the closed ring fading.
                coverage = ringMask(sweep: 1, inset: holdInset, width: holdWidth).map { $0 * (1 - Motion.ease(t)) }
            }
            for i in coverage.indices where coverage[i] > 0 {
                if let ink {
                    set(i, ink(i), coverage[i])
                } else {
                    let luminance = 0.2126 * pixels[i * 3] + 0.7152 * pixels[i * 3 + 1] + 0.0722 * pixels[i * 3 + 2]
                    set(i, luminance > 0.55 ? .black : .white, coverage[i])
                }
            }
        }

        /// Takes `other` where `coverage` says (everywhere if nil), at `opacity`.
        mutating func blend(_ other: Canvas, coverage: [Double]?, opacity: Double) {
            guard opacity > 0 else { return }
            for i in 0..<(side * side) {
                let a = (coverage?[i] ?? 1) * opacity
                guard a > 0 else { continue }
                for k in 0..<3 { pixels[i * 3 + k] = pixels[i * 3 + k] * (1 - a) + other.pixels[i * 3 + k] * a }
            }
        }

        private mutating func set(_ i: Int, _ color: RGB, _ alpha: Double) {
            let c = [Double(color.red), Double(color.green), Double(color.blue)].map { $0 / 255 }
            for k in 0..<3 { pixels[i * 3 + k] = pixels[i * 3 + k] * (1 - alpha) + c[k] * alpha }
        }

        /// The picture filling the key, or `inset` pixels in from every edge (on black).
        mutating func draw(picture: NSImage, inset: Double = 0) {
            guard let cg = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            var raw = [UInt8](repeating: 0, count: side * side * 4)
            raw.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .high
                let crop = min(cg.width, cg.height)
                let square = cg.cropping(to: CGRect(x: (cg.width - crop) / 2, y: (cg.height - crop) / 2, width: crop, height: crop)) ?? cg
                context.draw(square, in: CGRect(x: inset, y: inset, width: Double(side) - 2 * inset, height: Double(side) - 2 * inset))
            }
            for i in 0..<(side * side) {
                for k in 0..<3 { pixels[i * 3 + k] = Double(raw[i * 4 + k]) / 255 }
            }
        }

        func image() -> CGImage? {
            var raw = [UInt8](repeating: 255, count: side * side * 4)
            for i in 0..<(side * side) {
                for k in 0..<3 { raw[i * 4 + k] = UInt8((min(1, max(0, pixels[i * 3 + k])) * 255).rounded()) }
            }
            return raw.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
            }
        }
    }
}
