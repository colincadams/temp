import XCTest
@testable import BrickCore

final class HeightGeometryTests: XCTestCase {
    func testPlaneAtHeightAndUnprojectAgreeWithTheTablePlane() {
        let p = HeightScene.projector(cameraAt: SIMD3(0.05, 0.32, -0.02))
        let onTable = p.point(400, 100)!
        XCTAssertEqual(p.point(400, 100, height: 0)!, onTable)
        let raised = p.point(400, 100, height: 0.02)!
        XCTAssertEqual(raised.y, 0.02, accuracy: 1e-6)
        // The raised point lies on the same ray, nearer the camera: it projects back to the same pixel.
        let back = HeightScene.project(raised, from: p)
        XCTAssertEqual(back.x, 400, accuracy: 1e-3)
        XCTAssertEqual(back.y, 100, accuracy: 1e-3)
        let again = p.unproject(400, 100, depth: back.depth)
        XCTAssertEqual(TableMath.distance(again, raised), 0, accuracy: 1e-6)
        XCTAssertEqual(p.cameraPosition, SIMD3(0.05, 0.32, -0.02))
    }

    func testLeverAndLiftRecoverTheBaseOfATallPiece() {
        let base = SIMD3<Float>(0.06, 0, -0.04)
        let lift: Float = 0.015
        for camera in [SIMD3<Float>(0, 0.32, 0), SIMD3(0.12, 0.30, 0.05), SIMD3(-0.1, 0.33, -0.08)] {
            let p = HeightScene.projector(cameraAt: camera)
            // The pixel showing the point on the piece's axis `lift` above the table, and where its ray meets the table.
            let pixel = HeightScene.project(SIMD3(base.x, lift, base.z), from: p)
            let spot = p.point(pixel.x, pixel.y)!
            XCTAssertGreaterThan(TableMath.distance(spot, base), 0.002, "a tall piece's spot slides off its base")
            let lever = HeightGeometry.lever(position: spot, camera: camera)!
            XCTAssertEqual(TableMath.distance(HeightGeometry.base(position: spot, lever: lever, lift: lift), base), 0, accuracy: 1e-5)
            // The same as intersecting the ray with the plane at the lift and dropping the point onto the table.
            let raised = p.point(pixel.x, pixel.y, height: lift)!
            XCTAssertEqual(TableMath.distance(SIMD3(raised.x, 0, raised.z), base), 0, accuracy: 1e-5)
        }
        XCTAssertNil(HeightGeometry.lever(position: SIMD3(0, 0, 0), camera: SIMD3(0, 0.02, 0)))
    }

    func testScaleAtTheTopOfAPiece() {
        XCTAssertEqual(HeightGeometry.scale(cameraHeight: 0.32, height: 0.016), 0.95, accuracy: 1e-6)
        XCTAssertEqual(HeightGeometry.scale(cameraHeight: 0.32, height: 0), 1)
        XCTAssertEqual(HeightGeometry.scale(cameraHeight: 0, height: 0.02), 1, "unknown camera height: no change")
        // A 16 mm wide top 16 mm above the table measures 16 * 320 / 304 mm on the table plane; scaled back it is 16.
        let measured: Float = 16 * 0.32 / (0.32 - 0.016)
        XCTAssertEqual(measured * HeightGeometry.scale(cameraHeight: 0.32, height: 0.016), 16, accuracy: 1e-4)
    }

    /// Spots of a piece seen along a zig-zag sweep, with detection noise.
    private func spots(base: SIMD3<Float>, lift: Float, noiseMm: Float, seed: UInt64) -> (positions: [SIMD2<Float>], levers: [SIMD2<Float>]) {
        var random = HeightTestRandom(seed: seed)
        var positions: [SIMD2<Float>] = [], levers: [SIMD2<Float>] = []
        for camera in HeightScene.sweep(rowsZ: [-0.06, 0.06]) where HeightScene.inView(base, camera: camera) {
            var spot = HeightScene.spot(base: base, lift: lift, camera: camera)
            spot.x += random.gaussian() * noiseMm / 1000
            spot.z += random.gaussian() * noiseMm / 1000
            positions.append(SIMD2(spot.x, spot.z))
            levers.append(HeightGeometry.lever(position: spot, camera: camera)!)
        }
        return (positions, levers)
    }

    func testFittedLiftOfAFlatPieceStaysNearZero() {
        let base = SIMD3<Float>(0.03, 0, 0.01)
        for seed in 1...5 as ClosedRange<UInt64> {
            let views = spots(base: base, lift: 0.0016, noiseMm: 0.4, seed: seed)   // a plate: 3.2 mm, lift 1.6 mm
            XCTAssertGreaterThanOrEqual(views.positions.count, 8)
            let fit = HeightGeometry.fitLift(positions: views.positions, levers: views.levers)!
            XCTAssertLessThan(fit.lift, 0.003, "seed \(seed): stays under the 6 mm flat line (lift 3 mm)")
            XCTAssertEqual(fit.base.x, base.x, accuracy: 0.0008)
            XCTAssertEqual(fit.base.y, base.z, accuracy: 0.0008)
        }
        // No difference between views: no lift at all, and the base is the mean spot.
        let still = HeightGeometry.fitLift(positions: [SIMD2(0.01, 0.02), SIMD2(0.011, 0.021)], levers: [SIMD2(0.1, 0.1), SIMD2(0.1, 0.1)])!
        XCTAssertEqual(still.lift, 0)
        XCTAssertEqual(still.spread, 0)
        XCTAssertEqual(still.base.x, 0.0105, accuracy: 1e-6)
        // Spots sliding towards the camera would mean a piece below the table: clamped to 0.
        let backwards = HeightGeometry.fitLift(positions: [SIMD2(0.01, 0), SIMD2(-0.01, 0)], levers: [SIMD2(-0.3, 0), SIMD2(0.3, 0)])!
        XCTAssertEqual(backwards.lift, 0)
        XCTAssertNil(HeightGeometry.fitLift(positions: [], levers: []))
    }

    func testFittedLiftOfATallPieceFromAMovingCamera() {
        let base = SIMD3<Float>(-0.02, 0, 0.015)
        let lift: Float = 0.015   // a 30 mm tall piece
        let views = spots(base: base, lift: lift, noiseMm: 0.5, seed: 7)
        let xs = views.positions.map { $0.x }
        XCTAssertGreaterThan((xs.max()! - xs.min()!), 0.01, "the raw spot slides by more than a centimetre")
        let fit = HeightGeometry.fitLift(positions: views.positions, levers: views.levers)!
        XCTAssertEqual(fit.lift, lift, accuracy: 0.0015)
        XCTAssertEqual(fit.base.x, base.x, accuracy: 0.001)
        XCTAssertEqual(fit.base.y, base.z, accuracy: 0.001)
        // Clamped to the largest lift allowed.
        XCTAssertEqual(HeightGeometry.fitLift(positions: views.positions, levers: views.levers, maxLift: 0.01)!.lift, 0.01)
    }

    func testSlideBound() {
        XCTAssertEqual(HeightGeometry.slideBound(longMm: 30, shortestMm: 5), 0.0125, accuracy: 1e-7)
        XCTAssertEqual(HeightGeometry.slideBound(longMm: 4, shortestMm: 5), 0)
    }
}
