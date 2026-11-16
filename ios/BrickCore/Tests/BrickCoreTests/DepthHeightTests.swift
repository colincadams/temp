import XCTest
@testable import BrickCore

final class DepthHeightTests: XCTestCase {
    /// A 256 x 192 depth map of the table with one box-shaped piece `topHeight` above it, `halfSide` either side of
    /// `centre`, seen by `projector`; noise of `noiseMm` (standard deviation) and `outlierShare` of wild values.
    /// Pixels within one depth pixel of the box's edge are marked low confidence, as ARKit does at depth steps.
    private func depthMap(projector: TableProjector, centre: SIMD3<Float>, halfSide: Float, topHeight: Float,
                          noiseMm: Float, outlierShare: Float, seed: UInt64) -> DepthMap {
        let w = 256, h = 192
        var random = HeightTestRandom(seed: seed)
        var depth = [Float](repeating: 0, count: w * h), confidence = [UInt8](repeating: 2, count: w * h)
        let sx = HeightScene.width / Float(w), sy = HeightScene.height / Float(h)
        let edge: Float = 0.0015
        for v in 0..<h {
            for u in 0..<w {
                let x = (Float(u) + 0.5) * sx - 0.5, y = (Float(v) + 0.5) * sy - 0.5
                let top = projector.point(x, y, height: topHeight)!
                let dx = abs(top.x - centre.x), dz = abs(top.z - centre.z)
                let surface = dx <= halfSide && dz <= halfSide ? top : projector.point(x, y)!
                let i = v * w + u
                depth[i] = HeightScene.project(surface, from: projector).depth + random.gaussian() * noiseMm / 1000
                if abs(max(dx, dz) - halfSide) < edge { confidence[i] = 0 }
                if random.uniform() < outlierShare { depth[i] += (random.uniform() < 0.5 ? -1 : 1) * (0.03 + 0.1 * random.uniform()) }
            }
        }
        return DepthMap(width: w, height: h, depth: depth, confidence: confidence)!
    }

    private func blob(at pixel: (x: Float, y: Float), sidePixels: Float) -> DetectedBlob {
        let half = Int(sidePixels / 2)
        return DetectedBlob(minX: Int(pixel.x) - half, minY: Int(pixel.y) - half, maxX: Int(pixel.x) + half, maxY: Int(pixel.y) + half,
                            area: Int(sidePixels * sidePixels), cx: pixel.x, cy: pixel.y, major: sidePixels, minor: sidePixels,
                            r: 200, g: 0, b: 0)
    }

    func testDepthMapChecksItsSize() {
        XCTAssertNil(DepthMap(width: 2, height: 2, depth: [1, 1, 1], confidence: nil))
        XCTAssertNil(DepthMap(width: 2, height: 2, depth: [1, 1, 1, 1], confidence: [2]))
        XCTAssertNotNil(DepthMap(width: 2, height: 2, depth: [1, 1, 1, 1], confidence: nil))
    }

    func testHeightFromNoisySamplesWithOutliers() {
        let projector = HeightScene.projector(cameraAt: SIMD3(0.04, 0.32, 0.02))
        var random = HeightTestRandom(seed: 3)
        for trueHeight: Float in [0, 0.0032, 0.0112, 0.03] {
            var heights: [Float] = []
            for _ in 0..<15 {   // a piece followed over 15 frames
                var samples: [DepthHeight.Sample] = []
                for _ in 0..<30 {
                    let point = SIMD3<Float>(random.uniform() * 0.01, trueHeight, random.uniform() * 0.01)
                    let seen = HeightScene.project(point, from: projector)
                    var depth = seen.depth + random.gaussian() * 0.010   // 1 cm noise at about 30 cm
                    if random.uniform() < 0.1 { depth += random.uniform() < 0.5 ? 0.08 : -0.08 }   // wild values
                    samples.append(DepthHeight.Sample(x: seen.x, y: seen.y, depth: depth))
                }
                heights.append(DepthHeight.heightMm(samples, projector: projector)!)
            }
            // One frame is rough; the median over the frames, as the tracker takes it, is close.
            XCTAssertEqual(TableMath.median(heights), trueHeight * 1000, accuracy: 3, "true height \(trueHeight * 1000) mm")
        }
        XCTAssertNil(DepthHeight.heightMm([DepthHeight.Sample(x: 320, y: 240, depth: 0.3)], projector: projector), "too few samples")
    }

    func testSamplesComeFromTheHighConfidenceMiddleOfTheBlob() {
        let camera = SIMD3<Float>(0.01, 0.32, -0.01)
        let projector = HeightScene.projector(cameraAt: camera)
        let centre = SIMD3<Float>(0.03, 0, 0.02), halfSide: Float = 0.008, top: Float = 0.0112   // a 2 x 2 brick
        let map = depthMap(projector: projector, centre: centre, halfSide: halfSide, topHeight: top, noiseMm: 3,
                           outlierShare: 0.01, seed: 11)
        let pixel = HeightScene.project(SIMD3(centre.x, top, centre.z), from: projector)
        let side = 2 * halfSide * HeightScene.fx / (camera.y - top)
        let b = blob(at: (pixel.x, pixel.y), sidePixels: side)
        let samples = DepthHeight.samples(in: map, blob: b, step: 1, imageWidth: HeightScene.width, imageHeight: HeightScene.height)
        XCTAssertGreaterThanOrEqual(samples.count, 10)
        let radius = DepthHeight.Settings().coreFraction * side
        for s in samples {
            XCTAssertLessThanOrEqual(((s.x - pixel.x) * (s.x - pixel.x) + (s.y - pixel.y) * (s.y - pixel.y)).squareRoot(), radius + 1e-3)
        }
        let height = DepthHeight.heightMm(map: map, blob: b, step: 1, imageWidth: HeightScene.width, imageHeight: HeightScene.height,
                                          projector: projector)!
        XCTAssertEqual(height, 11.2, accuracy: 2.5)

        // Only low-confidence depth there: no answer, and the caller falls back.
        let doubtful = DepthMap(width: map.width, height: map.height, depth: map.depth,
                                confidence: [UInt8](repeating: 1, count: map.depth.count))!
        XCTAssertNil(DepthHeight.heightMm(map: doubtful, blob: b, step: 1, imageWidth: HeightScene.width, imageHeight: HeightScene.height,
                                          projector: projector))
        // A thin bar's middle covers too few depth pixels.
        XCTAssertNil(DepthHeight.heightMm(map: map, blob: blob(at: (pixel.x, pixel.y), sidePixels: 4), step: 1,
                                          imageWidth: HeightScene.width, imageHeight: HeightScene.height, projector: projector))
    }

    func testPlacementByTheTopCentre() {
        // Seen from well off to one side, a 30 mm tall piece's top is far from where its middle pixel's ray meets the table.
        let camera = SIMD3<Float>(-0.12, 0.32, -0.05)
        let projector = HeightScene.projector(cameraAt: camera)
        let base = SIMD3<Float>(0.03, 0, 0.02), top: Float = 0.03
        let pixel = HeightScene.project(SIMD3(base.x, top, base.z), from: projector)
        let naive = projector.point(pixel.x, pixel.y)!
        XCTAssertGreaterThan(TableMath.distance(naive, base), 0.01)
        var random = HeightTestRandom(seed: 5)
        var samples: [DepthHeight.Sample] = []
        for _ in 0..<25 {
            let p = SIMD3<Float>(base.x + (random.uniform() - 0.5) * 0.008, top, base.z + (random.uniform() - 0.5) * 0.008)
            let seen = HeightScene.project(p, from: projector)
            samples.append(DepthHeight.Sample(x: seen.x, y: seen.y, depth: seen.depth + random.gaussian() * 0.001))
        }
        let placed = DepthHeight.topCentreBase(samples, pixelX: pixel.x, pixelY: pixel.y, projector: projector)!
        XCTAssertEqual(placed.y, 0)
        XCTAssertEqual(TableMath.distance(placed, base), 0, accuracy: 0.0015)
        XCTAssertNil(DepthHeight.topCentreBase(Array(samples.prefix(2)), pixelX: pixel.x, pixelY: pixel.y, projector: projector))
    }
}
