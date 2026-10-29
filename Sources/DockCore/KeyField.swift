import CoreGraphics
import DockKit

/// One picture across all 15 keys, laid out as they really sit on the screen
/// (`M18Layout.keyField`, gaps included), cut into one 64×64 image per key. Anything that moves
/// from key to key draws here, so it travels at one speed over keys and gaps alike and is
/// hidden in a gap the way it would be behind the faceplate, instead of jumping key to key.
public struct KeyField {
    public let context: CGContext
    public let width = M18Layout.keyFieldWidth, height = M18Layout.keyFieldHeight

    /// A black field; draw with y down (key 1 at the top left).
    public init() {
        context = CGContext(data: nil, width: M18Layout.keyFieldWidth, height: M18Layout.keyFieldHeight, bitsPerComponent: 8,
                            bytesPerRow: M18Layout.keyFieldWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        clear()
    }

    public func clear() {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Draws a picture upright with its top-left corner at (x, y) on the field.
    public func draw(_ image: CGImage, x: Double, y: Double) {
        let height = Double(image.height)
        context.saveGState()
        // The field is drawn y down; a picture drawn straight in would come out upside down.
        context.translateBy(x: x, y: y + height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: Double(image.width), height: height))
        context.restoreGState()
    }

    /// Each key's piece of the field.
    public func keyImages() -> [Int: CGImage] {
        guard let whole = context.makeImage() else { return [:] }
        var images: [Int: CGImage] = [:]
        for key in 1...M18Layout.lcdKeyCount {
            let origin = M18Layout.keyOrigin(key), side = M18Layout.keyImageSize
            // makeImage is in raster order (top row first), the same as the field's y down.
            if let piece = whole.cropping(to: CGRect(x: origin.x, y: origin.y, width: side, height: side)) { images[key] = piece }
        }
        return images
    }
}
