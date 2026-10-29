import CoreGraphics
import DockKit
import Foundation
import Testing
@testable import DockCore

struct KeyFieldTests {
    @Test func layoutPutsAKeyEveryPitchWithHalfAKeyBetween() {
        #expect(M18Layout.keyFieldWidth == 448 && M18Layout.keyFieldHeight == 256)
        #expect(M18Layout.keyOrigin(1) == (0, 0) && M18Layout.keyOrigin(7) == (96, 96) && M18Layout.keyOrigin(15) == (384, 192))
        #expect(M18Layout.key(atFieldX: 63.9, y: 10) == 1 && M18Layout.key(atFieldX: 64, y: 10) == nil)
        #expect(M18Layout.key(atFieldX: 96, y: 96) == 7 && M18Layout.key(atFieldX: 447, y: 255) == 15)
        #expect(M18Layout.key(atFieldX: 200, y: 70) == nil)
    }

    @Test func keyImagesAreCutWhereTheKeysSit() throws {
        let field = KeyField()
        // A white block straddling the gap between keys 1 and 2: x 60..<100, y 10..<20.
        field.context.setFillColor(CGColor(gray: 1, alpha: 1))
        field.context.fill(CGRect(x: 60, y: 10, width: 40, height: 10))
        let images = field.keyImages()
        #expect(images.count == 15)
        func at(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
            let data = image.dataProvider!.data! as Data
            return data[y * image.bytesPerRow + x * 4]
        }
        let one = try #require(images[1]), two = try #require(images[2]), six = try #require(images[6])
        // Key 1 shows its last four columns lit (60–63), key 2 its first four (96–99), rows 10–19, top down.
        #expect(at(one, 60, 10) == 255 && at(one, 63, 19) == 255 && at(one, 59, 10) == 0 && at(one, 60, 20) == 0)
        #expect(at(two, 0, 10) == 255 && at(two, 3, 19) == 255 && at(two, 4, 10) == 0 && at(two, 0, 9) == 0)
        #expect(at(six, 60, 10) == 0)
    }

    @Test func picturesLandUprightWhereTheyAreDrawn() throws {
        // A 64×64 picture, white in its top 16 rows (raster order), drawn half a key into key 2.
        let picture = KeyField()
        picture.context.setFillColor(CGColor(gray: 1, alpha: 1))
        picture.context.fill(CGRect(x: 0, y: 0, width: 64, height: 16))
        let source = try #require(picture.keyImages()[1])
        let field = KeyField()
        field.draw(source, x: 96 + 32, y: 0)
        let two = try #require(field.keyImages()[2])
        let data = two.dataProvider!.data! as Data
        func at(_ x: Int, _ y: Int) -> UInt8 { data[y * two.bytesPerRow + x * 4] }
        #expect(at(40, 5) == 255 && at(40, 20) == 0 && at(20, 5) == 0)
    }
}
