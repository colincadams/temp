import XCTest
@testable import BrickCore

/// Camera at `position`, pitched `tilt` radians from straight down towards world -z; image right = world +x.
private func camera(at position: SIMD3<Float>, tilt: Float = 0) -> Matrix4 {
    let c = cos(tilt), s = sin(tilt)
    // Camera +y (image up) and +z (backwards) turned about world x; at tilt 0 they are world -z and world +y.
    return Matrix4(SIMD4(1, 0, 0, 0), SIMD4(0, s, -c, 0), SIMD4(0, c, s, 0), SIMD4(position.x, position.y, position.z, 1))
}

final class CoverageMapTests: XCTestCase {
    let fx: Float = 1500, fy: Float = 1480, cx: Float = 960, cy: Float = 720
    let width: Float = 1920, height: Float = 1440

    func projector(_ camera: Matrix4, tableY: Float = 0.7) -> TableProjector {
        TableProjector(fx: fx, fy: fy, cx: cx, cy: cy, camera: camera, tableY: tableY)
    }

    func testStraightDownCoversTheExpectedRectangle() {
        // 0.5 m above the table. Inset 5%: pixels 96...1824 across and 72...1368 down, so the footprint is
        // x = ±0.5 * 864 / 1500 = ±0.288 m and z = ±0.5 * 648 / 1480 = ±0.219 m around the point below the camera.
        var map = CoverageMap(cellSize: 0.02)
        let update = map.add(view: projector(camera(at: SIMD3(0, 1.2, 0))), imageWidth: width, imageHeight: height)
        // Cell centres at odd multiples of 1 cm: x from -0.27 to 0.27 (28 columns), z from -0.21 to 0.21 (22 rows).
        XCTAssertEqual(update, CoverageUpdate(cellsInView: 28 * 22, newCells: 28 * 22))
        XCTAssertEqual(map.cells.count, 28 * 22)
        guard let bounds = map.bounds else { return XCTFail("no bounds") }
        XCTAssertEqual(bounds.minX, -0.28, accuracy: 1e-5)
        XCTAssertEqual(bounds.maxX, 0.28, accuracy: 1e-5)
        XCTAssertEqual(bounds.minZ, -0.22, accuracy: 1e-5)
        XCTAssertEqual(bounds.maxZ, 0.22, accuracy: 1e-5)
        XCTAssertEqual(map.cells[CoverageCell(x: -14, z: -11)], 1)
        XCTAssertEqual(map.cells[CoverageCell(x: 13, z: 10)], 1)
        XCTAssertEqual(map.timesSeen(at: SIMD3(0.001, 0.7, -0.001)), 1)
    }

    func testCellsOutsideTheViewAreNotMarked() {
        var map = CoverageMap()
        map.add(view: projector(camera(at: SIMD3(0, 1.2, 0))), imageWidth: width, imageHeight: height)
        XCTAssertNil(map.cells[CoverageCell(x: -15, z: 0)])
        XCTAssertNil(map.cells[CoverageCell(x: 14, z: 0)])
        XCTAssertNil(map.cells[CoverageCell(x: 0, z: -12)])
        XCTAssertNil(map.cells[CoverageCell(x: 0, z: 11)])
        XCTAssertEqual(map.timesSeen(at: SIMD3(0.5, 0.7, 0)), 0)
        // The strip along the frame edge is left out: pixel 40 is inside the image but outside the inset.
        let edge = projector(camera(at: SIMD3(0, 1.2, 0))).point(40, cy)!
        XCTAssertEqual(map.timesSeen(at: edge), 0)
    }

    func testOverlappingViewsAccumulate() {
        var map = CoverageMap()
        map.add(view: projector(camera(at: SIMD3(0, 1.2, 0))), imageWidth: width, imageHeight: height)
        // Moved 0.3 m along x: columns from 0.03 to 0.57, overlapping the first view on 0.03...0.27.
        let second = map.add(view: projector(camera(at: SIMD3(0.3, 1.2, 0))), imageWidth: width, imageHeight: height)
        XCTAssertEqual(second.cellsInView, 28 * 22)
        XCTAssertEqual(second.newCells, 15 * 22)
        XCTAssertEqual(second.revisitedShare, 13.0 / 28.0, accuracy: 1e-5)
        XCTAssertEqual(map.timesSeen(at: SIMD3(0.15, 0.7, 0.05)), 2)
        XCTAssertEqual(map.timesSeen(at: SIMD3(-0.15, 0.7, 0.05)), 1)
        XCTAssertEqual(map.timesSeen(at: SIMD3(0.45, 0.7, 0.05)), 1)
        XCTAssertEqual(map.cells.count, 43 * 22)
        XCTAssertEqual(map.bounds?.maxX ?? 0, 0.58, accuracy: 1e-5)
        // The same view again counts every cell a second time and adds nothing new.
        let again = map.add(view: projector(camera(at: SIMD3(0.3, 1.2, 0))), imageWidth: width, imageHeight: height)
        XCTAssertEqual(again.newCells, 0)
        XCTAssertEqual(again.revisitedShare, 1)
        XCTAssertEqual(map.timesSeen(at: SIMD3(0.15, 0.7, 0.05)), 3)
        map.reset()
        XCTAssertTrue(map.cells.isEmpty)
        XCTAssertNil(map.bounds)
    }

    /// Every covered cell's centre, projected back into the image, lies inside the inset and within `maxDepth`.
    func assertVisible(_ map: CoverageMap, from camera: Matrix4, inset: Float, maxDepth: Float,
                       file: StaticString = #filePath, line: UInt = #line) {
        let origin = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let c0 = SIMD3<Float>(camera.columns.0.x, camera.columns.0.y, camera.columns.0.z)
        let c1 = SIMD3<Float>(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z)
        let c2 = SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        for cell in map.cells.keys {
            let centre = map.center(of: cell)
            let d = SIMD3<Float>(centre.x, 0.7, centre.y) - origin
            let depth = -(d * c2).sum()
            XCTAssertGreaterThan(depth, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(depth, maxDepth + 1e-3, file: file, line: line)
            let px = cx + fx * (d * c0).sum() / depth, py = cy - fy * (d * c1).sum() / depth
            XCTAssertGreaterThanOrEqual(px, width * inset - 0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(px, width * (1 - inset) + 0.5, file: file, line: line)
            XCTAssertGreaterThanOrEqual(py, height * inset - 0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(py, height * (1 - inset) + 0.5, file: file, line: line)
        }
    }

    func testViewReachingAboveTheHorizonMarksOnlyGroundItSees() {
        // Pitched 80 degrees from straight down: the vertical field of view is about ±26 degrees, so the top of
        // the image looks above the horizon and the middle meets the table about 2.8 m away.
        let tilted = camera(at: SIMD3(0, 1.2, 0), tilt: 80 * .pi / 180)
        for maxDepth: Float in [1.0, 3.99, 10] {
            var map = CoverageMap()
            let update = map.add(view: projector(tilted), imageWidth: width, imageHeight: height, maxDepth: maxDepth)
            XCTAssertGreaterThan(update.cellsInView, 0, "the bottom of the image sees the table")
            XCTAssertEqual(update.cellsInView, map.cells.count)
            assertVisible(map, from: tilted, inset: 0.05, maxDepth: min(maxDepth, 4))
            for cell in map.cells.keys { XCTAssertLessThan(map.center(of: cell).y, 0, "only ground in front") }
        }
        // A deeper limit reaches further, but never past what TableProjector itself accepts.
        var near = CoverageMap(), far = CoverageMap()
        near.add(view: projector(tilted), imageWidth: width, imageHeight: height, maxDepth: 1)
        far.add(view: projector(tilted), imageWidth: width, imageHeight: height, maxDepth: 3)
        XCTAssertGreaterThan(far.cells.count, near.cells.count)
    }

    func testViewsThatMissTheTableMarkNothing() {
        var map = CoverageMap()
        // Looking straight up.
        let up = Matrix4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 1.2, 0, 1))
        XCTAssertEqual(map.add(view: projector(up), imageWidth: width, imageHeight: height), CoverageUpdate(cellsInView: 0, newCells: 0))
        // Below the table.
        XCTAssertEqual(map.add(view: projector(camera(at: SIMD3(0, 0.5, 0))), imageWidth: width, imageHeight: height).cellsInView, 0)
        // Too far above it for the depth limit.
        XCTAssertEqual(map.add(view: projector(camera(at: SIMD3(0, 2.5, 0))), imageWidth: width, imageHeight: height).cellsInView, 0)
        // Level with the horizon: only the bottom of the image could see the table, and only far away.
        let level = camera(at: SIMD3(0, 1.2, 0), tilt: .pi / 2)
        XCTAssertEqual(map.add(view: projector(level), imageWidth: width, imageHeight: height).cellsInView, 0)
        // Nonsense input.
        XCTAssertEqual(map.add(view: projector(camera(at: SIMD3(0, 1.2, 0))), imageWidth: 0, imageHeight: height).cellsInView, 0)
        XCTAssertEqual(map.add(footprint: [SIMD2(0, 0), SIMD2(.nan, 1), SIMD2(1, 1)]).cellsInView, 0)
        XCTAssertTrue(map.cells.isEmpty)
        XCTAssertNil(map.bounds)
    }

    func testPolygonFootprint() {
        // A right triangle with legs of 0.1 m: centres (x + 0.01, z + 0.01) with x + z <= 0.1 - 0.02.
        var map = CoverageMap(cellSize: 0.02)
        let update = map.add(footprint: [SIMD2(0, 0), SIMD2(0.1, 0), SIMD2(0, 0.1)])
        XCTAssertEqual(update.cellsInView, 5 + 4 + 3 + 2 + 1)
        XCTAssertNotNil(map.cells[CoverageCell(x: 4, z: 0)])
        XCTAssertNil(map.cells[CoverageCell(x: 4, z: 1)])
        XCTAssertEqual(map.cell(at: SIMD3(-0.001, 0, 0.039)), CoverageCell(x: -1, z: 1))
        XCTAssertEqual(map.center(of: CoverageCell(x: -1, z: 1)), SIMD2(-0.01, 0.03))
    }
}

final class CompletionTests: XCTestCase {
    func testQuietTimeGrowsOnlyWhileSweepingCoveredGround() {
        var quiet = CoverageQuietTime()
        func frame(_ time: TimeInterval, x: Float, new: Int, confirmed: Int = 0) {
            quiet.record(time: time, cameraPosition: SIMD3(x, 0.4, 0), update: CoverageUpdate(cellsInView: 100, newCells: new),
                         confirmedCount: confirmed)
        }
        frame(0, x: 0, new: 0)
        XCTAssertEqual(quiet.seconds, 0)
        // Moving over covered ground: each frame adds its interval. 1 new cell in 100 still counts.
        frame(0.2, x: 0.01, new: 0)
        frame(0.4, x: 0.02, new: 1)
        XCTAssertEqual(quiet.seconds, 0.4, accuracy: 1e-9)
        // Held still: nothing.
        frame(0.6, x: 0.02, new: 0)
        // New ground: nothing, and nothing for as long as it is within the last second.
        frame(0.8, x: 0.05, new: 22)
        frame(1.0, x: 0.06, new: 0)
        XCTAssertEqual(quiet.seconds, 0.4, accuracy: 1e-9)
        // Over a second later, after a gap (frames rejected): the gap adds at most half a second.
        frame(1.9, x: 0.07, new: 0)
        XCTAssertEqual(quiet.seconds, 0.9, accuracy: 1e-9)
        // A new piece starts again.
        frame(2.1, x: 0.08, new: 0, confirmed: 1)
        XCTAssertEqual(quiet.seconds, 0)
        frame(2.3, x: 0.09, new: 0, confirmed: 1)
        XCTAssertEqual(quiet.seconds, 0.2, accuracy: 1e-9)
        quiet.reset()
        XCTAssertEqual(quiet.seconds, 0)
    }

    func testCompletionRule() {
        XCTAssertEqual(CompletionGuess.assess(timesSeen: [], quietSeconds: 100), .noPieces)
        XCTAssertEqual(CompletionGuess.assess(timesSeen: [5, 1, 3, 0], quietSeconds: 100), .needsAnotherPass(pieces: 2))
        XCTAssertEqual(CompletionGuess.assess(timesSeen: [2, 7], quietSeconds: 3.9), .stillLooking(quietSeconds: 3.9, neededSeconds: 4))
        XCTAssertEqual(CompletionGuess.assess(timesSeen: [2, 7], quietSeconds: 4), .looksComplete)
        XCTAssertTrue(CompletionGuess.assess(timesSeen: [3], quietSeconds: 4.2).looksComplete)
        XCTAssertFalse(CompletionGuess.assess(timesSeen: [3], quietSeconds: 1).looksComplete)
        XCTAssertEqual(CompletionGuess.assess(timesSeen: [2], quietSeconds: 10, neededSeconds: 12, minTimesSeen: 3), .needsAnotherPass(pieces: 1))
    }

    func testSimulatedSweepEndsLookingComplete() {
        // Two pieces on a table; the camera, 0.4 m up, sweeps right then back left at 5 cm/s, 5 frames a second.
        let fx: Float = 1500, fy: Float = 1480, cx: Float = 960, cy: Float = 720
        let pieces: [SIMD3<Float>] = [SIMD3(0.05, 0, 0.02), SIMD3(0.35, 0, -0.03)]
        var map = CoverageMap()
        var quiet = CoverageQuietTime()
        var confirmed = 0
        var guesses: [CompletionGuess] = []
        let xs = (0...80).map { Float($0) * 0.01 } + (0...60).map { 0.8 - Float($0) * 0.01 }
        for (i, x) in xs.enumerated() {
            let cam = camera(at: SIMD3(x, 0.4, 0))
            let view = TableProjector(fx: fx, fy: fy, cx: cx, cy: cy, camera: cam, tableY: 0)
            let update = map.add(view: view, imageWidth: 1920, imageHeight: 1440)
            // A piece is "confirmed" the first time it is covered twice.
            confirmed = pieces.filter { map.timesSeen(at: $0) >= 2 }.count
            quiet.record(time: Double(i) * 0.2, cameraPosition: SIMD3(x, 0.4, 0), update: update, confirmedCount: confirmed)
            let seen = pieces.filter { map.timesSeen(at: $0) > 0 }.map { map.timesSeen(at: $0) }
            guesses.append(CompletionGuess.assess(timesSeen: confirmed > 0 ? seen : [], quietSeconds: quiet.seconds))
        }
        XCTAssertEqual(guesses.first, .noPieces)
        XCTAssertFalse(guesses[80].looksComplete, "new ground all the way out")
        XCTAssertEqual(guesses.last, .looksComplete, "the way back is all covered ground")
    }
}
