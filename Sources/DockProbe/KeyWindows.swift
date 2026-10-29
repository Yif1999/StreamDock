import AppKit
import DockKit
import ImageIO
import UniformTypeIdentifiers

/// `dock-probe keywindows [--keep-background | --seam]`: puts a ruler on every key for a photo, from which
/// the key layout is measured (`M18Layout`). Each key image is white with a black line every
/// 8 px, so the photo carries its own scale on every key; the background (what shows between a
/// key image and the edge of its window) is set to black first. Holds until the middle round key.
///
/// Why a photo and not an interactive search over the background: uploading a background makes
/// the M18 drop off USB and come back a second or two later, so one background per step would
/// take seconds a step. See docs/design.md, 按键屏布局.
enum KeyWindows {
    static func run(_ arguments: [String]) throws {
        final class Presses: @unchecked Sendable {
            private let lock = NSLock()
            private var keys: [Int] = []
            func add(_ key: Int) { lock.lock(); keys.append(key); lock.unlock() }
            func take() -> [Int] { lock.lock(); defer { keys = []; lock.unlock() }; return keys }
        }
        let presses = Presses()
        let onInput: @Sendable (DockInputEvent) -> Void = { event in
            if event.pressed, case .round(let key) = event.key { presses.add(key) }
        }
        guard let identity = M18Device.attached().first else { print("no M18 attached"); return }
        var device = try M18Device(opening: identity, onInput: onInput)
        if !arguments.contains("--keep-background") {
            print("black background (the device reconnects after it)")
            device.setBackgroundImage(fullScreen { _ in })
            device.waitUntilIdle()
            device = try reopen(after: device, onInput: onInput)
        }
        device.setScreenBrightness(80)
        if arguments.contains("--seam") {
            // One grid over the whole screen and the same grid in every key image: where a key
            // image sits on a multiple of 4 px the lines run on unbroken from the window's rim
            // into the image; a break shows how far off it is.
            print("seam grid: background, then the same grid on every key")
            device.setBackgroundImage(fullScreen { context in
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                for x in stride(from: 3, to: M18Layout.screenWidth, by: 4) { context.fill(CGRect(x: x, y: 0, width: 1, height: M18Layout.screenHeight)) }
                for y in stride(from: 3, to: M18Layout.screenHeight, by: 4) { context.fill(CGRect(x: 0, y: y, width: M18Layout.screenWidth, height: 1)) }
            })
            device.waitUntilIdle()
            device = try reopen(after: device, onInput: onInput)
            device.setKeyImages(Dictionary(uniqueKeysWithValues: (1...15).map { ($0, seam) }))
        } else {
            device.setKeyImages(Dictionary(uniqueKeysWithValues: (1...15).map { ($0, ruler) }))
        }
        print("rulers on all keys: take a photo from straight above, then press the middle round key")
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: ["请从正上方拍一张照片，拍完按中间圆键"])
        while !presses.take().contains(2) { Thread.sleep(forTimeInterval: 0.05) }
        device.clearKeys(Array(1...15))
        device.waitUntilIdle()
        device.close(notifyDevice: true)
    }

    /// Waits for the device to leave and come back after a background upload, then opens it again.
    static func reopen(after device: M18Device, onInput: @escaping @Sendable (DockInputEvent) -> Void) throws -> M18Device {
        let old = device.identity.path
        let deadline = Date().addingTimeInterval(8)
        var gone = false
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            let attached = M18Device.attached()
            if !attached.contains(where: { $0.path == old }) { gone = true }
            if gone, let fresh = attached.first {
                device.close(notifyDevice: false)
                Thread.sleep(forTimeInterval: 0.5)
                print("reconnected")
                return try M18Device(opening: fresh, onInput: onInput)
            }
        }
        print("device did not reconnect within 8 s; carrying on with the old connection")
        return device
    }

    /// White, a black line every 8 px (at 7, 15, … 55, so the outer pixels stay white), as JPEG.
    static let ruler: Data = {
        let side = M18Layout.keyImageSize
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for at in stride(from: 7, to: side - 1, by: 8) {
            context.fill(CGRect(x: at, y: 0, width: 1, height: side))
            context.fill(CGRect(x: 0, y: at, width: side, height: 1))
        }
        return jpeg(context.makeImage()!, quality: 1)
    }()

    /// Black, a white line every 4 px (at 3, 7, … 63), as JPEG: the `--seam` grid.
    static let seam: Data = {
        let side = M18Layout.keyImageSize
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        // y up here: row 3 from the top is y = side - 4.
        for at in stride(from: 3, to: side, by: 4) {
            context.fill(CGRect(x: at, y: 0, width: 1, height: side))
            context.fill(CGRect(x: 0, y: side - 1 - at, width: side, height: 1))
        }
        return jpeg(context.makeImage()!, quality: 1)
    }()

    /// A full-screen picture, drawn y down onto black.
    static func fullScreen(_ draw: (CGContext) -> Void) -> Data {
        let width = M18Layout.screenWidth, height = M18Layout.screenHeight
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        // 85 % like the vendor SDK.
        return jpeg(context.makeImage()!, quality: 0.85)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
