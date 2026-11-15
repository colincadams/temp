import XCTest
@testable import BrickCore

final class InstanceGroupingTests: XCTestCase {
    static let stride = 2

    /// A synthetic scene at the detector's output resolution: a piece-number map (0 = table) and each piece's colour.
    struct Scene {
        let ow: Int, oh: Int
        var ids: [Int]
        var colours: [Int: [UInt8]] = [:]

        init(ow: Int, oh: Int) {
            self.ow = ow; self.oh = oh
            ids = [Int](repeating: 0, count: ow * oh)
        }

        mutating func fill(_ id: Int, x: Int, y: Int, w: Int, h: Int, colour: [UInt8]? = nil) {
            for yy in max(0, y)..<min(oh, y + h) {
                for xx in max(0, x)..<min(ow, x + w) { ids[yy * ow + xx] = id }
            }
            if let colour { colours[id] = colour }
        }

        /// Ideal network output, built the way `targets_from_ids` in ml/detector.py builds training targets:
        /// piece mask, a Gaussian peak at each piece's centroid, and every piece-pixel's offset to its centroid.
        func maps() -> [Float] {
            let plane = ow * oh
            var maps = [Float](repeating: 0, count: plane * 4)
            let size = (ids.max() ?? 0) + 1
            var count = [Double](repeating: 0, count: size), sx = count, sy = count
            for y in 0..<oh {
                for x in 0..<ow {
                    let id = ids[y * ow + x]
                    count[id] += 1; sx[id] += Double(x); sy[id] += Double(y)
                }
            }
            let cx = (0..<size).map { sx[$0] / max(count[$0], 1) }, cy = (0..<size).map { sy[$0] / max(count[$0], 1) }
            for y in 0..<oh {
                for x in 0..<ow {
                    let i = y * ow + x, id = ids[i]
                    guard id > 0 else { continue }
                    maps[i] = 1
                    maps[2 * plane + i] = Float(cx[id] - Double(x))
                    maps[3 * plane + i] = Float(cy[id] - Double(y))
                }
            }
            for id in 1..<max(size, 1) where count[id] > 0 {
                let sigma = 1.0 + 0.12 * count[id].squareRoot()   // bigger pieces get broader peaks
                let r = Int(3 * sigma) + 1
                for y in max(0, Int(cy[id]) - r)..<min(oh, Int(cy[id]) + r + 1) {
                    for x in max(0, Int(cx[id]) - r)..<min(ow, Int(cx[id]) + r + 1) {
                        let dx = Double(x) - cx[id], dy = Double(y) - cy[id]
                        let g = Float(exp(-(dx * dx + dy * dy) / (2 * sigma * sigma)))
                        maps[plane + y * ow + x] = max(maps[plane + y * ow + x], g)
                    }
                }
            }
            return maps
        }

        /// The frame the maps describe, `stride` times larger: grey table, each piece in its colour.
        func frame() -> [UInt8] {
            let s = InstanceGroupingTests.stride
            let w = ow * s, h = oh * s
            var rgba = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let colour = colours[ids[(y / s) * ow + x / s]] ?? [230, 230, 230]
                    let p = (y * w + x) * 4
                    rgba[p] = colour[0]; rgba[p + 1] = colour[1]; rgba[p + 2] = colour[2]
                }
            }
            return rgba
        }

        func detect(validRows: Int? = nil) -> [DetectedBlob] {
            InstanceGrouping.group(maps: maps(), outputWidth: ow, validRows: validRows ?? oh,
                                   rgba: frame(), frameWidth: ow * InstanceGroupingTests.stride, stride: InstanceGroupingTests.stride)
        }
    }

    func blob(_ blobs: [DetectedBlob], colour: [UInt8], file: StaticString = #filePath, line: UInt = #line) -> DetectedBlob? {
        let hits = blobs.filter { [$0.r, $0.g, $0.b] == colour }
        XCTAssertEqual(hits.count, 1, "pieces coloured \(colour)", file: file, line: line)
        return hits.first
    }

    /// Box of an output-resolution rectangle in frame pixels.
    func assertBox(_ blob: DetectedBlob?, x: Int, y: Int, w: Int, h: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let blob else { return }
        let s = Self.stride
        XCTAssertEqual([blob.minX, blob.minY, blob.maxX, blob.maxY], [x * s, y * s, (x + w) * s - 1, (y + h) * s - 1], file: file, line: line)
    }

    func testTouchingRectanglesRingAndCutPiece() {
        var scene = Scene(ow: 160, oh: 120)
        let red: [UInt8] = [200, 20, 20], blue: [UInt8] = [20, 60, 190], green: [UInt8] = [0, 120, 0]
        let yellow: [UInt8] = [240, 200, 0], black: [UInt8] = [10, 10, 10]
        // Two rectangles sharing an edge.
        scene.fill(1, x: 20, y: 20, w: 30, h: 20, colour: red)
        scene.fill(2, x: 50, y: 20, w: 30, h: 20, colour: blue)
        // A ring: its centroid, and so its centre peak, is in the hole.
        scene.fill(3, x: 100, y: 60, w: 30, h: 30, colour: green)
        scene.fill(0, x: 107, y: 67, w: 16, h: 16)
        // A piece standing alone, and one cut by the left frame edge.
        scene.fill(4, x: 30, y: 80, w: 12, h: 24, colour: yellow)
        scene.fill(5, x: 0, y: 50, w: 14, h: 10, colour: black)
        XCTAssertEqual(scene.ids[75 * scene.ow + 115], 0, "the ring's centroid is in its hole")

        let blobs = scene.detect()
        XCTAssertEqual(blobs.count, 4)
        XCTAssertTrue(blobs.allSatisfy { [$0.r, $0.g, $0.b] != black }, "the piece cut by the frame edge is dropped")

        let a = blob(blobs, colour: red), b = blob(blobs, colour: blue)
        assertBox(a, x: 20, y: 20, w: 30, h: 20)
        assertBox(b, x: 50, y: 20, w: 30, h: 20)
        for (piece, centreX) in [(a, Float(70)), (b, Float(130))] {
            guard let piece else { continue }
            XCTAssertEqual(piece.area, 30 * 20 * 4)
            XCTAssertEqual(piece.cx, centreX, accuracy: 0.01)
            XCTAssertEqual(piece.cy, 60, accuracy: 0.01)
            XCTAssertEqual(piece.major, 60, accuracy: 0.5)
            XCTAssertEqual(piece.minor, 40, accuracy: 0.5)
        }

        let ring = blob(blobs, colour: green)
        assertBox(ring, x: 100, y: 60, w: 30, h: 30)
        XCTAssertEqual(ring?.area, (30 * 30 - 16 * 16) * 4)
        XCTAssertEqual(ring?.cx ?? 0, 230, accuracy: 0.01)
        XCTAssertEqual(ring?.cy ?? 0, 150, accuracy: 0.01)

        let lone = blob(blobs, colour: yellow)
        assertBox(lone, x: 30, y: 80, w: 12, h: 24)
        XCTAssertEqual(lone?.major ?? 0, 48, accuracy: 0.5)
        XCTAssertEqual(lone?.minor ?? 0, 24, accuracy: 0.5)
    }

    func testPiecesCutByEachEdgeAreDropped() {
        var scene = Scene(ow: 96, oh: 64)
        scene.fill(1, x: 40, y: 0, w: 10, h: 8, colour: [1, 1, 1])     // top
        scene.fill(2, x: 86, y: 30, w: 10, h: 8, colour: [2, 2, 2])    // right
        scene.fill(3, x: 40, y: 56, w: 10, h: 8, colour: [3, 3, 3])    // bottom
        scene.fill(4, x: 0, y: 30, w: 10, h: 8, colour: [4, 4, 4])     // left
        scene.fill(5, x: 40, y: 28, w: 10, h: 8, colour: [5, 5, 5])    // whole
        let blobs = scene.detect()
        XCTAssertEqual(blobs.map { $0.r }, [5])
    }

    /// Frames shorter than the model's input are padded; rows of padding must be ignored, and a piece that
    /// reaches the last real row counts as cut off.
    func testPaddingRowsAreIgnored() {
        var scene = Scene(ow: 96, oh: 64)
        scene.fill(1, x: 20, y: 10, w: 12, h: 8, colour: [200, 20, 20])
        scene.fill(2, x: 60, y: 44, w: 12, h: 8, colour: [20, 60, 190])    // touches row 51
        scene.fill(3, x: 30, y: 56, w: 12, h: 6, colour: [0, 120, 0])      // wholly in the padding
        XCTAssertEqual(scene.detect().count, 3)
        let blobs = scene.detect(validRows: 52)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(blobs.first?.r, 200)
    }

    func testSpecksAndEmptyMaps() {
        var scene = Scene(ow: 96, oh: 64)
        XCTAssertEqual(scene.detect().count, 0)
        scene.fill(1, x: 20, y: 20, w: 2, h: 2, colour: [200, 20, 20])     // 4 pixels: below the minimum area
        scene.fill(2, x: 50, y: 20, w: 3, h: 2, colour: [20, 60, 190])     // 6 pixels: just enough
        let blobs = scene.detect()
        XCTAssertEqual(blobs.map { $0.r }, [20])
    }

    /// A pixel whose offset points far from every peak still goes to the nearest one, as in `group_instances`.
    func testFarVotesGoToTheNearestPeak() {
        var scene = Scene(ow: 160, oh: 120)
        scene.fill(1, x: 10, y: 50, w: 10, h: 10, colour: [200, 20, 20])
        scene.fill(2, x: 120, y: 50, w: 10, h: 10, colour: [20, 60, 190])
        var maps = scene.maps()
        let plane = 160 * 120
        // Piece 2's pixels vote 60 pixels left of their own centre. Peak 1 is at x = 14.5 and peak 2 at 124.5,
        // so a vote at 64.5 is 50 from peak 1 and 60 from peak 2, and far from both.
        for i in 0..<plane where scene.ids[i] == 2 { maps[2 * plane + i] -= 60 }
        let blobs = InstanceGrouping.group(maps: maps, outputWidth: 160, validRows: 120, rgba: scene.frame(), frameWidth: 320, stride: 2)
        // Both pieces' pixels now belong to peak 1, giving one wide blob.
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(blobs.first?.minX, 20)
        XCTAssertEqual(blobs.first?.maxX, 259)
        // Offsets that are not numbers, or absurdly large, are survived.
        maps = scene.maps()
        for i in 0..<plane where scene.ids[i] == 2 { maps[2 * plane + i] = i % 2 == 0 ? .nan : 1e30 }
        let rest = InstanceGrouping.group(maps: maps, outputWidth: 160, validRows: 120, rgba: scene.frame(), frameWidth: 320, stride: 2)
        XCTAssertEqual(rest.filter { $0.r == 200 }.count, 1)
    }

    func testMismatchedSizesGiveNothing() {
        var scene = Scene(ow: 96, oh: 64)
        scene.fill(1, x: 20, y: 20, w: 10, h: 10, colour: [200, 20, 20])
        let maps = scene.maps(), frame = scene.frame()
        XCTAssertEqual(InstanceGrouping.group(maps: maps, outputWidth: 96, validRows: 64, rgba: frame, frameWidth: 192, stride: 2).count, 1)
        XCTAssertEqual(InstanceGrouping.group(maps: maps, outputWidth: 96, validRows: 65, rgba: frame, frameWidth: 192, stride: 2).count, 0)
        XCTAssertEqual(InstanceGrouping.group(maps: maps, outputWidth: 100, validRows: 64, rgba: frame, frameWidth: 192, stride: 2).count, 0)
        XCTAssertEqual(InstanceGrouping.group(maps: Array(maps.dropLast()), outputWidth: 96, validRows: 64, rgba: frame, frameWidth: 192, stride: 2).count, 0)
        XCTAssertEqual(InstanceGrouping.group(maps: maps, outputWidth: 96, validRows: 64, rgba: Array(frame.prefix(1000)), frameWidth: 192, stride: 2).count, 0)
        XCTAssertEqual(InstanceGrouping.group(maps: [], outputWidth: 0, validRows: 0, rgba: [], frameWidth: 0, stride: 2).count, 0)
    }
}
