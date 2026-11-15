import XCTest
@testable import BrickCore

/// The cases of `test/segment.test.js`, which tests the web app's version of the same method.
final class PieceDetectorTests: XCTestCase {
    typealias Rect = (x: Int, y: Int, w: Int, h: Int, rgb: [UInt8])

    /// Paint a W x H RGBA image: uneven light background plus solid rectangles.
    static func scene(_ w: Int, _ h: Int, _ rects: [Rect]) -> [UInt8] {
        var data = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let shade = UInt8(235 - Int((Double(x) / Double(w) * 15).rounded()) + (x * 7 + y * 13) % 5)
                data[i] = shade; data[i + 1] = shade; data[i + 2] = shade
            }
        }
        for rect in rects {
            for y in rect.y..<rect.y + rect.h {
                for x in rect.x..<rect.x + rect.w {
                    let i = (y * w + x) * 4
                    data[i] = rect.rgb[0]; data[i + 1] = rect.rgb[1]; data[i + 2] = rect.rgb[2]
                }
            }
        }
        return data
    }

    func testFindsEachSeparatePieceWithItsBoxAndColour() {
        let rects: [Rect] = [(20, 20, 60, 30, [200, 20, 20]), (150, 40, 40, 40, [20, 60, 190]), (60, 120, 80, 25, [10, 10, 10])]
        let blobs = PieceDetector.detect(rgba: Self.scene(240, 180, rects), width: 240, height: 180)
        XCTAssertEqual(blobs.count, 3)
        for rect in rects {
            guard let blob = blobs.first(where: { abs($0.minX - rect.x) <= 2 && abs($0.minY - rect.y) <= 2 }) else {
                XCTFail("no box near \(rect.x),\(rect.y)")
                continue
            }
            XCTAssertLessThanOrEqual(abs(blob.maxX - blob.minX + 1 - rect.w), 4)
            XCTAssertLessThanOrEqual(abs(blob.maxY - blob.minY + 1 - rect.h), 4)
            XCTAssertEqual([blob.r, blob.g, blob.b], rect.rgb)
            // Not in the JavaScript test: the measurements the app adds.
            XCTAssertEqual(blob.cx, Float(rect.x) + Float(rect.w - 1) / 2, accuracy: 1)
            XCTAssertEqual(blob.cy, Float(rect.y) + Float(rect.h - 1) / 2, accuracy: 1)
            XCTAssertEqual(blob.major, Float(max(rect.w, rect.h)), accuracy: 3)
            XCTAssertEqual(blob.minor, Float(min(rect.w, rect.h)), accuracy: 3)
            XCTAssertEqual(Float(blob.area), Float(rect.w * rect.h), accuracy: Float(rect.w * rect.h) * 0.15)
        }
    }

    func testIgnoresSpecksAndAnEmptyBackground() {
        XCTAssertEqual(PieceDetector.detect(rgba: Self.scene(240, 180, []), width: 240, height: 180).count, 0)
        let rects: [Rect] = [(100, 100, 2, 2, [255, 0, 0]), (20, 20, 50, 50, [0, 120, 0])]
        XCTAssertEqual(PieceDetector.detect(rgba: Self.scene(240, 180, rects), width: 240, height: 180).count, 1)
    }

    /// The app's version differs from the web app's here: a piece cut by the frame edge waits for a better frame.
    func testDropsPiecesCutByTheFrameEdge() {
        let rects: [Rect] = [(0, 60, 40, 30, [200, 20, 20]), (100, 150, 40, 30, [20, 60, 190]), (120, 60, 40, 30, [0, 120, 0])]
        let blobs = PieceDetector.detect(rgba: Self.scene(240, 180, rects), width: 240, height: 180)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(blobs.first.map { [$0.r, $0.g, $0.b] }, [0, 120, 0])
    }

    func testRejectsABufferThatIsTooSmall() {
        XCTAssertEqual(PieceDetector.detect(rgba: [UInt8](repeating: 0, count: 10), width: 240, height: 180).count, 0)
        XCTAssertEqual(PieceDetector.detect(rgba: [], width: 0, height: 0).count, 0)
    }
}
