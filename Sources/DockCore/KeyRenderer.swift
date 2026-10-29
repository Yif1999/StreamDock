import AppKit
import DockKit
import ImageIO
import UniformTypeIdentifiers

/// Turns a `KeyFace` into the JPEG the M18 expects (64×64, shown 1:1), drawn by `KeyDesign`.
@MainActor
public enum KeyRenderer {
    public static func jpeg(for face: KeyFace, press: Double = 0) -> Data? {
        guard let image = image(for: face, press: press) else { return nil }
        return jpeg(image)
    }

    /// Any 64×64 picture (a `KeyField` piece, say) as the JPEG the M18 expects.
    public static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // Full quality: below it ImageIO subsamples color 4:2:0, which smears colored edges
        // over 2×2 pixels. At 64×64 this is still only a few kilobytes.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    public static func image(for face: KeyFace, press: Double = 0) -> CGImage? {
        KeyDesign.image(symbol: face.symbol, value: face.title, label: face.caption, tone: face.tone,
                        artwork: face.artwork, meter: face.meter, hold: face.hold, press: press)
    }
}
