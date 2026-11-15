import XCTest
@testable import BrickCore

/// A tiny sweep built in code: coloured rectangles on a plain table, seen straight down from two camera positions.
final class ReplayRunnerTests: XCTestCase {
    struct Rect {
        var x: Float, z: Float          // centre on the table, metres
        var w: Float, d: Float          // size along x and z, metres
        var rgb: [UInt8]
    }

    static let width = 320, height = 240
    static let fx: Float = 600, height0: Float = 0.3   // half a millimetre per pixel on the table
    static let background: [UInt8] = [228, 226, 220]

    /// One true piece only camera A sees, one only B sees, three both see, one neither sees.
    static let rects = [
        Rect(x: -0.080, z: 0.020, w: 0.016, d: 0.008, rgb: [200, 30, 30]),
        Rect(x: 0.000, z: 0.000, w: 0.024, d: 0.016, rgb: [30, 60, 190]),
        Rect(x: 0.020, z: -0.030, w: 0.032, d: 0.008, rgb: [20, 120, 40]),
        Rect(x: 0.090, z: 0.030, w: 0.012, d: 0.012, rgb: [240, 200, 20]),
        Rect(x: -0.025, z: -0.035, w: 0.008, d: 0.008, rgb: [20, 20, 20]),
        Rect(x: 0.000, z: 0.120, w: 0.016, d: 0.016, rgb: [200, 30, 30]),
    ]

    static func sweep(cameras: [(x: Float, time: Double)]) -> ReplaySweep {
        let pieces = rects.enumerated().map { i, r in
            ReplaySweep.Piece(id: i, partNum: "rect\(i)", x: r.x, z: r.z,
                              radiusMm: (r.w * r.w + r.d * r.d).squareRoot() / 2 * 1000,
                              longMm: max(r.w, r.d) * 1000, shortMm: min(r.w, r.d) * 1000, heightMm: 0,
                              rgb: r.rgb.map { String(format: "%02x", $0) }.joined())
        }
        let frames = cameras.enumerated().map { i, c -> ReplaySweep.Frame in
            let m = lookingDown(from: SIMD3(c.x, height0, 0))
            let t = [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
            return ReplaySweep.Frame(file: String(format: "%04d.jpg", i), time: c.time, transform: t,
                                     rgba: String(format: "%04d.rgba", i), ids: String(format: "%04d.ids", i))
        }
        return ReplaySweep(width: width, height: height, fx: fx, fy: fx, cx: Float(width) / 2, cy: Float(height) / 2, tableY: 0,
                           frames: frames, pieces: pieces)
    }

    /// The frame and its piece-number map, by casting a ray through every pixel.
    static func render(_ sweep: ReplaySweep, frame: ReplaySweep.Frame) -> (rgba: [UInt8], ids: [UInt16]) {
        let projector = sweep.projector(frame)!
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var ids = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * width + x
                var colour = background
                if let point = projector.point(Float(x), Float(y)),
                   let hit = rects.firstIndex(where: { abs(point.x - $0.x) <= $0.w / 2 && abs(point.z - $0.z) <= $0.d / 2 }) {
                    colour = rects[hit].rgb
                    ids[p] = UInt16(hit + 1)
                } else {
                    // A little texture so the table is not perfectly flat.
                    colour = colour.map { UInt8(Int($0) - (x * 7 + y * 13) % 4) }
                }
                rgba[p * 4] = colour[0]; rgba[p * 4 + 1] = colour[1]; rgba[p * 4 + 2] = colour[2]
            }
        }
        return (rgba, ids)
    }

    /// Ideal detector output at half resolution, built like `targets_from_ids` in ml/detector.py.
    static func idealMaps(ids: [UInt16], width w: Int, height h: Int) -> [Float] {
        let ow = w / 2, oh = h / 2, plane = ow * oh
        var count: [Int: Float] = [:], sx: [Int: Float] = [:], sy: [Int: Float] = [:]
        for y in 0..<oh {
            for x in 0..<ow {
                let n = Int(ids[2 * y * w + 2 * x])
                if n == 0 { continue }
                count[n, default: 0] += 1; sx[n, default: 0] += Float(x); sy[n, default: 0] += Float(y)
            }
        }
        var maps = [Float](repeating: 0, count: plane * 4)
        for y in 0..<oh {
            for x in 0..<ow {
                let i = y * ow + x
                let n = Int(ids[2 * y * w + 2 * x])
                if n > 0, let c = count[n] {
                    maps[i] = 1
                    maps[2 * plane + i] = sx[n]! / c - Float(x)
                    maps[3 * plane + i] = sy[n]! / c - Float(y)
                }
                var peak: Float = 0
                for (k, c) in count {
                    let dx = Float(x) - sx[k]! / c, dy = Float(y) - sy[k]! / c
                    peak = max(peak, exp(-(dx * dx + dy * dy) / (2 * 1.5 * 1.5)))
                }
                maps[plane + i] = peak
            }
        }
        return maps
    }

    /// Writes the sweep the way ml/render_sweep.py and ml/sweep_frames.py do, plus ideal maps.
    static func writeSweep(_ sweep: ReplaySweep) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("replay-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for frame in sweep.frames {
            let (rgba, ids) = render(sweep, frame: frame)
            try Data(rgba).write(to: folder.appendingPathComponent(frame.rgba!))
            try Data(ids.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }).write(to: folder.appendingPathComponent(frame.ids!))
            let maps = idealMaps(ids: ids, width: width, height: height)
            try Data(maps.flatMap { v -> [UInt8] in
                let b = v.bitPattern
                return [UInt8(b & 255), UInt8(b >> 8 & 255), UInt8(b >> 16 & 255), UInt8(b >> 24)]
            }).write(to: folder.appendingPathComponent(frame.stem + ".maps"))
        }
        try JSONEncoder().encode(sweep).write(to: folder.appendingPathComponent("sweep.json"))
        return folder
    }

    /// Camera A at x = -3 cm for three frames, then B at x = +4 cm for four. The jump between them is 0.35 m/s,
    /// faster than the app allows, so the first frame at B is skipped: each camera position gives three processed frames.
    static let twoPositions: [(x: Float, time: Double)] = [(-0.03, 0), (-0.03, 0.2), (-0.03, 0.4),
                                                          (0.04, 0.6), (0.04, 0.8), (0.04, 1.0), (0.04, 1.2)]

    func testSyntheticSweepCountsEveryPieceOnceWithEachDetector() throws {
        let sweep = Self.sweep(cameras: Self.twoPositions)
        let folder = try ReplayFolder(url: try Self.writeSweep(sweep))
        defer { try? FileManager.default.removeItem(at: folder.url) }
        XCTAssertTrue(folder.hasPieceMaps)
        XCTAssertEqual(folder.sweep.work.step, 1)

        var settings = ReplayRunner.Settings()
        // The test frames are 320 x 240; the real model takes 640 x 480.
        settings.mapsInputWidth = Self.width
        settings.mapsInputHeight = Self.height
        for detector in ReplayDetector.allCases {
            let run = try ReplayRunner.run(folder: folder, detector: detector, settings: settings)
            XCTAssertEqual(run.frames.map { $0.skipped }, [nil, nil, nil, ReplayRunner.skippedFast, nil, nil, nil], "\(detector)")
            XCTAssertEqual(run.visibilityMethod, "piece maps")
            XCTAssertEqual(run.wholeFrames[0], 3, "only camera A sees piece 0")
            XCTAssertEqual(run.wholeFrames[3], 3, "only camera B sees piece 3")
            XCTAssertEqual(run.wholeFrames[1], 6)
            XCTAssertNil(run.wholeFrames[5], "no camera sees piece 5")

            let report = ReplayScoring.report(sweep: folder.sweep, run: run, detector: detector)
            XCTAssertEqual(report.piecesOnTable, 6)
            XCTAssertEqual(report.piecesCouldBeSeen, 5, "\(detector)")
            XCTAssertEqual(report.piecesCounted, 5, "\(detector)")
            XCTAssertEqual([report.found, report.missed, report.countedTwice, report.merged, report.phantom], [5, 0, 0, 0, 0], "\(detector)")
            // Flat rectangles seen straight down measure true to within a couple of pixels.
            XCTAssertLessThan(report.longError.meanAbsolute, 1.5, "\(detector)")
            XCTAssertLessThan(report.positionError.mean, 1.5, "\(detector)")
            XCTAssertLessThan(report.colourDistance.mean, 2, "\(detector)")
        }
    }

    func testTruthDetectorDropsPiecesCutByTheFrameEdge() {
        // 6 x 4 frame: piece 1 (id 0) inside, piece 2 (id 1) touching the right edge.
        let w = 6, h = 4
        var ids = [UInt16](repeating: 0, count: w * h)
        for (x, y) in [(1, 1), (2, 1), (1, 2), (2, 2)] { ids[y * w + x] = 1 }
        for (x, y) in [(4, 1), (5, 1)] { ids[y * w + x] = 2 }
        var rgba = [UInt8](repeating: 200, count: w * h * 4)
        for p in 0..<w * h where ids[p] == 1 { rgba[p * 4] = 10; rgba[p * 4 + 1] = 20; rgba[p * 4 + 2] = 30 }
        let blobs = ReplayTruthDetector.blobs(ids: ids, rgba: rgba, width: w, height: h)
        XCTAssertEqual(blobs.map { $0.id }, [0])
        let blob = blobs[0].blob
        XCTAssertEqual([blob.minX, blob.minY, blob.maxX, blob.maxY, blob.area], [1, 1, 2, 2, 4])
        XCTAssertEqual(blob.cx, 1.5)
        XCTAssertEqual(blob.cy, 1.5)
        XCTAssertEqual(blob.major, Float(12).squareRoot() / 2, accuracy: 1e-5)   // same measure as PieceDetector
        XCTAssertEqual([blob.r, blob.g, blob.b], [10, 20, 30])
        XCTAssertEqual(ReplayTruthDetector.wholePieces(ids: ids, width: w, height: h), [0])
    }

    func testGatingFollowsTheApp() throws {
        let sweep = Self.sweep(cameras: [(-0.03, 0), (-0.03, 0.2), (-0.03, 0.3), (-0.03, 0.4), (-0.03, 0.6), (-0.03, 0.8), (-0.03, 1.0)])
        var tilted = sweep
        // Frame 4 is pitched 45 degrees: facing down at only cos 45 = 0.71 < 0.8.
        let s = Float(0.5).squareRoot()
        tilted.frames[4].transform = [1, 0, 0, 0, 0, s, -s, 0, 0, s, s, 0, -0.03, 0.3, 0, 1]
        let frame = Self.render(sweep, frame: sweep.frames[0])
        var loaded: [Int] = []
        let run = try ReplayRunner.run(sweep: tilted, detector: .colour) { index in
            loaded.append(index)
            return ReplayFrameData(rgba: frame.rgba, ids: frame.ids)
        }
        // 0.3 s comes 0.1 s after the last processed frame. 1.0 is processed although 1.0 - 0.8 < 0.2 in floating point.
        XCTAssertLessThan(1.0 - 0.8, 0.2)
        XCTAssertEqual(run.frames.map { $0.skipped }, [nil, nil, ReplayRunner.skippedTooSoon, nil, ReplayRunner.skippedTilted, nil, nil])
        XCTAssertEqual(loaded, [0, 1, 3, 5, 6], "skipped frames are not even read")
        XCTAssertEqual(run.frames[0].detections, 4)
        XCTAssertEqual(run.tracked.filter { $0.confirmed }.count, 4)
    }

    func testMapsNeedTheModelsFrameSize() throws {
        let sweep = Self.sweep(cameras: [(0, 0)])
        let frame = Self.render(sweep, frame: sweep.frames[0])
        XCTAssertThrowsError(try ReplayRunner.run(sweep: sweep, detector: .maps) { _ in
            ReplayFrameData(rgba: frame.rgba, maps: Self.idealMaps(ids: frame.ids, width: Self.width, height: Self.height))
        }) { error in
            XCTAssertTrue("\(error)".contains("fall back to the colour detector"))
        }
    }

    func testOlderSweepJSONStillReads() throws {
        // As written before working-resolution frames and footprints were added.
        let json = """
        {"width": 1920, "height": 1440, "fx": 1500.5, "fy": 1500.5, "cx": 960.0, "cy": 720.0, "tableY": 0.0,
         "frames": [{"file": "0000.jpg", "time": 0.0, "transform": [1,0,0,0, 0,0,-1,0, 0,1,0,0, 0,0.3,0,1]}],
         "pieces": [{"id": 0, "partNum": "3023", "classId": 0, "colorId": 4, "x": 0.01, "z": -0.02, "radiusMm": 9.1}]}
        """
        let sweep = try JSONDecoder().decode(ReplaySweep.self, from: Data(json.utf8))
        XCTAssertEqual(sweep.work.step, 3)
        XCTAssertEqual(sweep.work.width, 640)
        XCTAssertEqual(sweep.work.height, 480)
        XCTAssertEqual(sweep.camera(sweep.frames[0]), lookingDown(from: SIMD3(0, 0.3, 0)))
        XCTAssertNil(sweep.pieces[0].longMm)
    }
}
