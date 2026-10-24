import AppKit
import DockKit
import ImageIO
import UniformTypeIdentifiers

/// Draws a `KeyFace` into the JPEG the M18 expects.
@MainActor
public enum KeyRenderer {
    static let size = CGFloat(M18Layout.keyImageSize)

    public static func jpeg(for face: KeyFace, pressed: Bool = false) -> Data? {
        guard let image = image(for: face, pressed: pressed) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    public static func image(for face: KeyFace, pressed: Bool = false) -> CGImage? {
        let pixels = Int(size)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Top-left origin, like AppKit's flipped views.
        context.translateBy(x: 0, y: size)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let background = pressed ? face.background.mixed(with: .white, amount: 0.35) : face.background
        background.nsColor.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        let contentRect = face.caption == nil
            ? NSRect(x: 4, y: 4, width: size - 8, height: size - 8)
            : NSRect(x: 4, y: 4, width: size - 8, height: size - 22)
        if let symbol = face.symbol {
            drawSymbol(symbol, color: face.foreground, in: contentRect, pointSize: face.caption == nil ? 30 : 24)
        } else if let title = face.title {
            drawText(title, color: face.foreground, in: contentRect, maxFontSize: 26, weight: .bold)
        }
        if let caption = face.caption {
            drawText(caption, color: face.foreground, in: NSRect(x: 2, y: size - 18, width: size - 4, height: 15), maxFontSize: 12, weight: .semibold)
        }
        return context.makeImage()
    }

    private static func drawSymbol(_ name: String, color: RGB, in rect: NSRect, pointSize: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color.nsColor]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            drawText("?", color: color, in: rect, maxFontSize: 26, weight: .bold)
            return
        }
        var drawSize = image.size
        let scale = min(1, rect.width / drawSize.width, rect.height / drawSize.height)
        drawSize = NSSize(width: drawSize.width * scale, height: drawSize.height * scale)
        image.draw(in: NSRect(
            x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2,
            width: drawSize.width, height: drawSize.height
        ))
    }

    /// Centers a single line, shrinking the font until it fits the width.
    private static func drawText(_ text: String, color: RGB, in rect: NSRect, maxFontSize: CGFloat, weight: NSFont.Weight) {
        var fontSize = maxFontSize
        var attributed: NSAttributedString
        repeat {
            let base = NSFont.systemFont(ofSize: fontSize, weight: weight)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
            attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color.nsColor])
            fontSize -= 1
        } while attributed.size().width > rect.width && fontSize > 7
        let textSize = attributed.size()
        attributed.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
    }
}

extension RGB {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    func mixed(with other: RGB, amount: Double) -> RGB {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) * (1 - amount) + Double(b) * amount).rounded()) }
        return RGB(mix(red, other.red), mix(green, other.green), mix(blue, other.blue))
    }
}
