import CoreGraphics
import Foundation
import Testing
@testable import DockCore

struct KeyDesignTests {
    private func pixels(_ image: CGImage) -> (Int, Int) -> RGB {
        let data = image.dataProvider!.data! as Data
        let row = image.bytesPerRow
        return { x, y in RGB(data[y * row + x * 4], data[y * row + x * 4 + 1], data[y * row + x * 4 + 2]) }
    }

    @Test func meterFillsWholeColumnsAndInkFollowsTheGround() throws {
        let fill = RGB(hex: "#7D72FF")
        let image = try #require(KeyDesign.image(value: "50%", label: "Week", meter: KeyMeter(fraction: 0.5, color: fill)))
        let at = pixels(image)
        // Half of 64 is exactly 32 columns: a hard edge, no blended column.
        #expect(at(0, 0) == fill && at(31, 0) == fill && at(32, 0) == .black && at(63, 63) == .black)
        // The value straddles the edge: black ink over the fill, white ink over black.
        let rows = 12..<44
        #expect(rows.contains { y in (8..<32).contains { at($0, y) == .black } })
        #expect(rows.contains { y in (32..<56).contains { at($0, y) == .white } })
        // Empty and full meters leave no stray column.
        let empty = pixels(try #require(KeyDesign.image(value: "0%", meter: KeyMeter(fraction: 0, color: fill))))
        let full = pixels(try #require(KeyDesign.image(value: "100%", meter: KeyMeter(fraction: 1, color: fill))))
        #expect(empty(0, 0) == .black && full(63, 0) == fill)
    }

    @Test func holdTracesTheEdgeClockwiseFromTheTopMiddleInContrast() throws {
        let quarter = pixels(try #require(KeyDesign.image(symbol: "moon.fill", label: "Sleep", hold: 0.25)))
        // A quarter of the way: the top's right half and most of the right side, nothing on the left.
        #expect(quarter(40, 3) == .white && quarter(60, 20) == .white)
        #expect(quarter(20, 3) == .black && quarter(3, 40) == .black && quarter(40, 0) == .black)
        // Full: every edge pixel, in black over a white "on" key.
        let full = pixels(try #require(KeyDesign.image(symbol: "power", tone: .on, hold: 1)))
        #expect([(2, 2), (61, 2), (61, 61), (2, 61), (31, 4), (4, 31)].allSatisfy { full($0.0, $0.1) == .black })
        #expect(full(0, 0) == .white && full(7, 7) == .white) // Rim and inside keep the key's color.
    }
}
