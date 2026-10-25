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
    static let valueSize = 23.0, valueWidth = 50.0
    /// A pressed key, whatever it shows, goes this much darker — pressed in, like an iOS button.
    /// (Lightening would turn the black ground grey and do nothing to a white "on" key.)
    static let pressedDim = 0.3
    /// The hold line: this wide, this far in from the edge (so a light key keeps a rim of its
    /// own color between the line and the black window), from the top middle, clockwise.
    static let holdWidth = 3, holdInset = 2
    /// Alpha ramp after downsampling: coverage below `low` drops, above `high` is solid.
    static let edge = (low: 0.12, high: 0.82)

    struct Palette { let tile: RGB?; let glyph: RGB; let label: RGB }
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
                             hold: Double? = nil, pressed: Bool = false) -> CGImage? {
        let colors = palette(meter == nil ? tone : .normal)
        var canvas = Canvas(side: side)
        canvas.fill(.black)
        if let artwork, let picture = NSImage(data: artwork) {
            canvas.draw(picture: picture)
            if pressed { canvas.darken(pressedDim) }
            if let hold { canvas.traceEdge(hold) }
            return canvas.image()
        }
        // A state fills the whole key (the panel's black window frames it).
        if let tile = colors.tile { canvas.fill(tile) }
        // A meter fills whole columns from the left; ink takes the color of whatever is under it,
        // so a value split by the edge reads in two colors (black on the fill, white on black).
        var split = 0
        if let meter {
            split = Int((min(1, max(0, meter.fraction)) * Double(side)).rounded())
            canvas.fill(meter.color, columns: 0..<split)
        }
        func paint(_ coverage: [Double], _ color: RGB, onFill: RGB) {
            guard split > 0 else { return canvas.composite(coverage, color: color, sharpen: true) }
            canvas.composite(coverage, color: onFill, sharpen: true, columns: 0..<split)
            canvas.composite(coverage, color: color, sharpen: true, columns: split..<side)
        }
        let meterLabel = meter?.color.scaled(by: meterLabelShade) ?? colors.label
        // Label first: its ink top bounds the area left for the glyph.
        var contentBottom = side - margin
        if let label {
            let text = textMask(label, size: labelSize, weight: .medium, rounded: false, baseline: labelBaseline,
                                maxWidth: labelWidth, tracking: labelTracking)
            if let ink = inkBounds(text) {
                paint(shifted(text, dx: side / 2 - (ink.minX + ink.maxX + 1) / 2, dy: 0), colors.label, onFill: meterLabel)
                contentBottom = ink.minY - labelGap
            }
        }
        let main: [Double]?
        if let value {
            main = textMask(value, size: valueSize, weight: .semibold, rounded: true, baseline: 40, maxWidth: valueWidth, tracking: -0.3)
        } else if let symbol {
            main = symbolMask(symbol, box: label == nil ? glyphBox : glyphBoxLabeled)
        } else {
            main = nil
        }
        if let main, let ink = inkBounds(main) {
            let dx = side / 2 - (ink.minX + ink.maxX + 1) / 2
            let height = ink.maxY - ink.minY + 1
            let top: Int
            if label != nil {
                // With a label the two read as one group: the content leans on the label, the
                // spare space split 3:1 above:below — centered, a short value floats off it.
                top = margin + Int((Double(contentBottom - margin - height) * labelLean).rounded())
            } else {
                top = margin + (contentBottom - margin - height) / 2
            }
            let dy = top - ink.minY
            paint(shifted(main, dx: dx, dy: dy), colors.glyph, onFill: .black)
        }
        if pressed { canvas.darken(pressedDim) }
        if let hold { canvas.traceEdge(hold) }
        return canvas.image()
    }

    /// The key's edge band as a clockwise path from the top middle: one entry per step along
    /// the band's centerline, each the band's cross-section there.
    static let edgePath: [[Int]] = {
        let w = holdWidth, o = holdInset, lo = o, hi = side - 1 - o
        func column(_ x: Int, rows: Range<Int>) -> [Int] { rows.map { $0 * side + x } }
        func row(_ y: Int, columns: Range<Int>) -> [Int] { columns.map { y * side + $0 } }
        let top = lo..<(lo + w), bottom = (hi - w + 1)..<(hi + 1), left = lo..<(lo + w), right = (hi - w + 1)..<(hi + 1)
        var steps: [[Int]] = []
        for x in (side / 2)...hi { steps.append(column(x, rows: top)) }                                   // top, right half
        for y in (lo + w)...hi { steps.append(row(y, columns: right)) }                                   // right side, down
        for x in stride(from: hi - w, through: lo, by: -1) { steps.append(column(x, rows: bottom)) }      // bottom, leftward
        for y in stride(from: hi - w, through: lo + w, by: -1) { steps.append(row(y, columns: left)) }    // left side, up
        for x in lo..<(side / 2) { steps.append(column(x, rows: top)) }                                   // top, left half
        return steps
    }()

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
        let n = CGFloat(supersample)
        var fontSize = CGFloat(size)
        var attributed: NSAttributedString
        var font: NSFont
        repeat {
            let base = NSFont.systemFont(ofSize: fontSize * n, weight: weight)
            font = rounded ? (base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize * n) } ?? base) : base
            attributed = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.white, .kern: CGFloat(tracking) * n,
            ])
            fontSize -= 0.5
        } while attributed.size().width > CGFloat(maxWidth) * n && fontSize > 7
        let x = ((CGFloat(side) * n - attributed.size().width) / 2 / n).rounded() * n
        // In this flipped context a line is drawn from its top: baseline − ascender.
        let y = CGFloat(baseline) * n - font.ascender
        return mask(side) { _ in attributed.draw(at: NSPoint(x: x, y: y)) }
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

        /// Traces `progress` (0...1) of the edge band, each pixel in whichever of white or black
        /// stands out from what is under it; the leading step is partly drawn, so it glides.
        mutating func traceEdge(_ progress: Double) {
            let path = KeyDesign.edgePath
            let reach = min(1, max(0, progress)) * Double(path.count)
            for (index, step) in path.enumerated() {
                let alpha = min(1, max(0, reach - Double(index)))
                guard alpha > 0 else { break }
                for i in step {
                    let luminance = 0.2126 * pixels[i * 3] + 0.7152 * pixels[i * 3 + 1] + 0.0722 * pixels[i * 3 + 2]
                    set(i, luminance > 0.55 ? .black : .white, alpha)
                }
            }
        }

        mutating func darken(_ amount: Double) {
            for i in pixels.indices { pixels[i] *= 1 - amount }
        }

        private mutating func set(_ i: Int, _ color: RGB, _ alpha: Double) {
            let c = [Double(color.red), Double(color.green), Double(color.blue)].map { $0 / 255 }
            for k in 0..<3 { pixels[i * 3 + k] = pixels[i * 3 + k] * (1 - alpha) + c[k] * alpha }
        }

        mutating func draw(picture: NSImage) {
            guard let cg = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            var raw = [UInt8](repeating: 0, count: side * side * 4)
            raw.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .high
                let crop = min(cg.width, cg.height)
                let square = cg.cropping(to: CGRect(x: (cg.width - crop) / 2, y: (cg.height - crop) / 2, width: crop, height: crop)) ?? cg
                context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
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
