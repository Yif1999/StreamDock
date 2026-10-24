import CoreGraphics
import Foundation

/// Display brightness through the private DisplayServices framework — what the keyboard
/// brightness keys and the Control Center slider use. Works for the built-in display and
/// for external displays macOS controls natively (Apple displays and compatible 5K panels).
enum DisplayBrightness {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeFunction = @convention(c) (CGDirectDisplayID) -> Bool

    nonisolated(unsafe) private static let library = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW
    )
    private static let getBrightness = library
        .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFunction.self) }
    private static let setBrightness = library
        .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFunction.self) }
    private static let canChangeBrightness = library
        .flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }
        .map { unsafeBitCast($0, to: CanChangeFunction.self) }

    /// The display the brightness keys should drive: the built-in one when it is on,
    /// otherwise the main (then any) display macOS can adjust. Nil means none can be
    /// adjusted natively and DDC is the only option.
    static func controllableDisplay() -> CGDirectDisplayID? {
        guard let canChangeBrightness else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else { return nil }
        let candidates = displays.prefix(Int(count)).filter { canChangeBrightness($0) }
        return candidates.first { CGDisplayIsBuiltin($0) != 0 }
            ?? candidates.first { CGDisplayIsMain($0) != 0 }
            ?? candidates.first
    }

    /// 0...1.
    static func get(_ display: CGDirectDisplayID) -> Float? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        return getBrightness(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float, on display: CGDirectDisplayID) {
        _ = setBrightness?(display, min(1, max(0, value)))
    }
}
