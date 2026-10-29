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

    @Test func holdRingClosesInThenTracesTheEdgeClockwiseInContrast() throws {
        // Early on the ring is still outside the key: nothing shows.
        let early = pixels(try #require(KeyDesign.image(symbol: "moon.fill", label: "Sleep", hold: .holding(0.03))))
        #expect(early(40, 0) == .black && early(40, 3) == .black && early(63, 20) == .black)
        // Half way: settled 2 px in, the top's right half, the right side and the bottom's right half.
        let half = pixels(try #require(KeyDesign.image(symbol: "moon.fill", label: "Sleep", hold: .holding(0.5))))
        #expect(half(40, 3) == .white && half(60, 20) == .white && half(40, 60) == .white)
        #expect(half(20, 3) == .black && half(3, 40) == .black && half(20, 60) == .black && half(40, 0) == .black)
        // Fired, at the start of the response: the whole edge, in black over a white "on" key.
        let full = pixels(try #require(KeyDesign.image(symbol: "power", tone: .on, hold: .confirmed(0))))
        let edge = [(2, 2), (61, 2), (61, 61), (2, 61), (31, 4), (4, 31)]
        #expect(edge.allSatisfy { full($0.0, $0.1) == .black })
        #expect(full(0, 0) == .white && full(7, 7) == .white) // Rim and inside keep the key's color.
        // The response has faded by its end.
        let faded = pixels(try #require(KeyDesign.image(symbol: "moon.fill", label: "Sleep", hold: .confirmed(1))))
        #expect(faded(40, 3) == .black && faded(3, 40) == .black)
        // Let go: the ring slips back out of sight.
        let gone = pixels(try #require(KeyDesign.image(symbol: "moon.fill", label: "Sleep", hold: .released(from: 0.5, 1))))
        #expect(gone(40, 3) == .black && gone(60, 20) == .black)
    }

    @Test func aTapKeyTurnsOverFromTheEdgeInward() throws {
        // Fully down: black with white ink goes white with black ink; red with white goes white.
        let down = pixels(try #require(KeyDesign.image(symbol: "circle.fill", press: 1)))
        #expect(down(1, 1) == .white && down(32, 32) != .white)
        #expect(pixels(try #require(KeyDesign.image(symbol: "mic.slash.fill", tone: .alert, press: 1)))(1, 1) == .white)
        // Part way: the edge has turned, the middle not yet.
        let part = pixels(try #require(KeyDesign.image(value: "45", press: 0.3)))
        #expect(part(1, 32) == .white && part(31, 31) == .black)
        // A long-press key does not turn over while held: only its ring shows.
        let held = pixels(try #require(KeyDesign.image(symbol: "moon.fill", hold: .holding(0.5), press: 1)))
        #expect(held(10, 10) == .black && held(40, 3) == .white)
    }

    @MainActor @Test func artworkSinksInStepWithTheRing() throws {
        let art = try #require(KeyRenderer.jpeg(for: KeyFace(symbol: "star.fill", tone: .on)))
        // Tapped: a black rim round the picture (white here).
        let tapped = pixels(try #require(KeyDesign.image(artwork: art, press: 1)))
        #expect(tapped(1, 32) == .black && tapped(10, 10).red > 200)
        // Held: sunk exactly as far as the ring has closed in.
        let early = pixels(try #require(KeyDesign.image(artwork: art, hold: .holding(0.05))))
        let late = pixels(try #require(KeyDesign.image(artwork: art, hold: .holding(0.5))))
        #expect(early(1, 32).red > late(1, 32).red && late(1, 32) == .black)
        // Fired: springs back to full size, never recolored.
        let fired = pixels(try #require(KeyDesign.image(artwork: art, hold: .confirmed(0.5))))
        #expect(fired(1, 32).red > 200 && fired(32, 10).red > 200)
    }

    @Test func firingTurnsTheWholeKeyOverFromTheRingBothWays() throws {
        // Part way: the ring has spread over the rim and inward, the middle not yet reached.
        let early = pixels(try #require(KeyDesign.image(symbol: "moon.fill", label: "Sleep", hold: .confirmed(0.25))))
        #expect(early(0, 30) == .white && early(8, 30) == .white)
        // Spread out: the whole key, rim and middle, in contrast — white over a black key.
        let full = pixels(try #require(KeyDesign.image(value: "45", hold: .confirmed(0.45))))
        #expect(full(0, 0) == .white && full(63, 63) == .white && full(5, 32) == .white)
    }

    @Test func aChangingNumberKeepsItsPlace() throws {
        // 52 → 55 → 59: the first digit does not move, and every value sits on the same rows.
        func render(_ value: String) throws -> CGImage { try #require(KeyDesign.image(value: value, label: "Volume")) }
        let images = try ["52", "55", "59", "11", "88"].map(render)
        let first = pixels(images[0])
        for image in images[1...2] {
            let other = pixels(image)
            #expect((0..<31).allSatisfy { x in (0..<64).allSatisfy { y in first(x, y) == other(x, y) } })
        }
        // A narrow "11" sits on the same rows as "88".
        func rows(_ image: CGImage) -> Set<Int> {
            let at = pixels(image)
            return Set((0..<44).filter { y in (0..<64).contains { at($0, y) != .black } })
        }
        #expect(rows(images[3]).min() == rows(images[4]).min())
    }
}
