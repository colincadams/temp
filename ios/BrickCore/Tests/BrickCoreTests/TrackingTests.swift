import XCTest
@testable import BrickCore

/// Camera-to-world transform of a camera at `position` looking straight down (world -y), image right = world +x.
func lookingDown(from position: SIMD3<Float>) -> Matrix4 {
    // Camera +x -> world +x, camera +y (image up) -> world -z, camera +z (backwards) -> world +y.
    Matrix4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(position.x, position.y, position.z, 1))
}

final class TableProjectorTests: XCTestCase {
    let fx: Float = 1500, fy: Float = 1480, cx: Float = 960, cy: Float = 720

    func projector(camera: Matrix4, tableY: Float = 0.7) -> TableProjector {
        TableProjector(fx: fx, fy: fy, cx: cx, cy: cy, camera: camera, tableY: tableY)
    }

    func assertPoint(_ a: SIMD3<Float>?, _ b: SIMD3<Float>, accuracy: Float = 1e-5, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("no point", file: file, line: line) }
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }

    func testMatrixTimesVector() {
        let m = Matrix4(SIMD4(1, 2, 3, 4), SIMD4(5, 6, 7, 8), SIMD4(9, 10, 11, 12), SIMD4(13, 14, 15, 16))
        XCTAssertEqual(m * SIMD4(1, 0, 0, 0), SIMD4(1, 2, 3, 4))
        XCTAssertEqual(m * SIMD4(1, 2, 3, 4), SIMD4(90, 100, 110, 120))
        XCTAssertEqual(Matrix4.identity * SIMD4(3, 4, 5, 1), SIMD4(3, 4, 5, 1))
        XCTAssertEqual(TableMath.distance(SIMD3(1, 2, 3), SIMD3(4, 6, 3)), 5)
        XCTAssertEqual(TableMath.mix(SIMD3(0, 0, 0), SIMD3(4, 8, -4), 0.25), SIMD3(1, 2, -1))
        XCTAssertEqual(TableMath.median([]), 0)
        XCTAssertEqual(TableMath.median([5, 1, 3]), 3)
        XCTAssertEqual(TableMath.median([4, 1, 3, 2]), 3)
    }

    func testPrincipalPointMapsToThePointBelowTheCamera() {
        let p = projector(camera: lookingDown(from: SIMD3(0.3, 1.1, -0.2)))
        assertPoint(p.point(cx, cy), SIMD3(0.3, 0.7, -0.2))
    }

    func testOffCentrePixelMapsToTheExpectedOffset() {
        let h: Float = 0.4
        let p = projector(camera: lookingDown(from: SIMD3(0.3, 0.7 + h, -0.2)))
        // 300 pixels right: h * 300 / fx along world +x. 148 pixels down the image: h * 148 / fy along world +z.
        assertPoint(p.point(cx + 300, cy), SIMD3(0.3 + h * 300 / fx, 0.7, -0.2))
        assertPoint(p.point(cx, cy + 148), SIMD3(0.3, 0.7, -0.2 + h * 148 / fy))
        assertPoint(p.point(cx - 150, cy - 74), SIMD3(0.3 - h * 150 / fx, 0.7, -0.2 - h * 74 / fy))
    }

    func testTiltedCamera() {
        // Pitched 45 degrees up from straight down, towards world -z: forward = (0, -1, -1) / sqrt 2.
        let s = Float(0.5).squareRoot()
        let camera = Matrix4(SIMD4(1, 0, 0, 0), SIMD4(0, s, -s, 0), SIMD4(0, s, s, 0), SIMD4(0, 1, 0, 1))
        let p = projector(camera: camera, tableY: 0)
        assertPoint(p.point(cx, cy), SIMD3(0, 0, -1))
    }

    func testRaysPointingUpOrLevelReturnNil() {
        // Looking straight up: camera +z (backwards) -> world -y.
        let up = Matrix4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 1.1, 0, 1))
        XCTAssertNil(projector(camera: up).point(cx, cy))
        XCTAssertNil(projector(camera: up).point(cx + 400, cy - 300))
        // Level with the horizon: identity looks along world -z.
        let level = Matrix4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 1.1, 0, 1))
        XCTAssertNil(projector(camera: level).point(cx, cy))
        XCTAssertNotNil(projector(camera: level).point(cx, cy + 600), "a pixel low in a level image does see the table")
        // Looking down, but the table is above the camera or too far below it.
        XCTAssertNil(projector(camera: lookingDown(from: SIMD3(0, 0.5, 0))).point(cx, cy))
        XCTAssertNil(projector(camera: lookingDown(from: SIMD3(0, 5, 0))).point(cx, cy))
    }

    func testLocateMeasuresTheScale() {
        let h: Float = 0.45
        let p = projector(camera: lookingDown(from: SIMD3(0, 0.7 + h, 0)))
        // Work image 3 times smaller than the full image.
        guard let spot = p.locate(workX: 400, workY: 200, step: 3) else { return XCTFail("no spot") }
        assertPoint(spot.position, SIMD3(h * (1200 - cx) / fx, 0.7, h * (600 - cy) / fy))
        let expected = (h * 3 / fx + h * 3 / fy) / 2 * 1000
        XCTAssertEqual(spot.mmPerPixel, expected, accuracy: expected * 1e-3)
        let up = Matrix4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 1.1, 0, 1))
        XCTAssertNil(projector(camera: up).locate(workX: 400, workY: 200, step: 3))
    }
}

final class PieceTrackerTests: XCTestCase {
    func observation(_ x: Float, _ z: Float, longMm: Float = 16, shortMm: Float = 8,
                     rgb: [UInt8] = [200, 20, 20], quality: Float = 100) -> PieceObservation {
        PieceObservation(position: SIMD3(x, 0, z), longMm: longMm, shortMm: shortMm, r: rgb[0], g: rgb[1], b: rgb[2], quality: quality)
    }

    /// One frame: every observation in turn, then the end-of-frame clean-up.
    @discardableResult
    func frame(_ tracker: PieceTracker, time: TimeInterval, _ observations: [PieceObservation]) -> [TrackedPiece?] {
        tracker.beginFrame()
        let pieces = observations.map { tracker.observe($0, time: time) }
        tracker.endFrame(time: time)
        return pieces
    }

    func testSamePieceFromDifferentCameraPositionsStaysOnePiece() {
        // A 2 x 4 brick at (0.10, 0, 0.05) on a table at height 0, seen through a real projection from five
        // camera positions. Its top face is 9.6 mm above the table, so its apparent table position shifts
        // with the viewing angle, as in a real sweep.
        let tracker = PieceTracker()
        let fx: Float = 1500, fy: Float = 1500, cx: Float = 960, cy: Float = 720, step: Float = 3
        let top = SIMD3<Float>(0.10, 0.0096, 0.05)
        var ids = Set<UUID>()
        let cameras: [SIMD3<Float>] = [SIMD3(0, 0.4, 0), SIMD3(0.05, 0.42, 0.02), SIMD3(0.12, 0.38, 0.06), SIMD3(0.2, 0.4, 0.1), SIMD3(0.16, 0.41, -0.04)]
        for (i, camera) in cameras.enumerated() {
            let projector = TableProjector(fx: fx, fy: fy, cx: cx, cy: cy, camera: lookingDown(from: camera), tableY: 0)
            // Pixel at which the camera sees the centre of the brick's top face.
            let depth = camera.y - top.y
            let px = cx + (top.x - camera.x) / depth * fx, py = cy + (top.z - camera.z) / depth * fy
            guard let spot = projector.locate(workX: px / step, workY: py / step, step: step) else { return XCTFail("no spot") }
            let blob = DetectedBlob(minX: 0, minY: 0, maxX: 0, maxY: 0, area: 900, cx: px / step, cy: py / step,
                                    major: 32 / spot.mmPerPixel, minor: 16 / spot.mmPerPixel, r: 200, g: 20, b: 20)
            let quality = PieceTracker.viewQuality(of: blob, frameWidth: 640, frameHeight: 480)
            let piece = frame(tracker, time: Double(i) * 0.2, [PieceObservation(blob: blob, position: spot.position, mmPerPixel: spot.mmPerPixel, quality: quality)])[0]
            if let piece { ids.insert(piece.id) }
        }
        XCTAssertEqual(tracker.pieces.count, 1)
        XCTAssertEqual(ids.count, 1)
        let piece = tracker.pieces[0]
        XCTAssertEqual(piece.sightings, 5)
        XCTAssertTrue(tracker.isConfirmed(piece))
        XCTAssertEqual(piece.longMm, 32, accuracy: 0.01)
        XCTAssertEqual(piece.shortMm, 16, accuracy: 0.01)
        XCTAssertEqual(piece.rgbHex, "c81414")
        XCTAssertLessThan(TableMath.distance(piece.position, SIMD3(0.10, 0, 0.05)), 0.006)
    }

    func testTwoPiecesTwelveMillimetresApartStayTwo() {
        let tracker = PieceTracker()
        // Two 1 x 1 plates, 12 mm centre to centre, with a millimetre of jitter and in either order.
        let jitter: [Float] = [0, 0.001, -0.001, 0.0005, -0.0005, 0.001]
        for (i, j) in jitter.enumerated() {
            var seen = [observation(0.100 + j, 0.05 - j, longMm: 8, shortMm: 8),
                        observation(0.112 - j, 0.05 + j, longMm: 8, shortMm: 8, rgb: [20, 60, 190])]
            if i % 2 == 1 { seen.reverse() }
            frame(tracker, time: Double(i) * 0.2, seen)
        }
        XCTAssertEqual(tracker.pieces.count, 2)
        XCTAssertEqual(tracker.confirmed.count, 2)
        XCTAssertEqual(tracker.pieces.map { $0.sightings }, [6, 6])
        XCTAssertEqual(Set(tracker.pieces.map { $0.rgbHex }), ["c81414", "143cbe"], "each kept its own colour")
        XCTAssertEqual(tracker.pieces[0].position.x, 0.100, accuracy: 0.001)
        XCTAssertEqual(tracker.pieces[1].position.x, 0.112, accuracy: 0.001)
    }

    func testOneDetectionPerPiecePerFrame() {
        // Two detections in one frame are two pieces even when closer than the match radius.
        let tracker = PieceTracker()
        frame(tracker, time: 0, [observation(0.100, 0.05, longMm: 32), observation(0.108, 0.05, longMm: 32)])
        XCTAssertEqual(tracker.pieces.count, 2)
        frame(tracker, time: 0.2, [observation(0.100, 0.05, longMm: 32), observation(0.108, 0.05, longMm: 32)])
        XCTAssertEqual(tracker.pieces.count, 2)
        XCTAssertEqual(tracker.pieces.map { $0.sightings }, [2, 2])
    }

    func testMatchRadiusGrowsWithThePiece() {
        let tracker = PieceTracker()
        frame(tracker, time: 0, [observation(0.100, 0.05, longMm: 64)])
        frame(tracker, time: 0.2, [observation(0.125, 0.05, longMm: 64)])     // 25 mm off: within half of 64 mm
        XCTAssertEqual(tracker.pieces.count, 1)
        XCTAssertEqual(tracker.pieces[0].position.x, 0.10625, accuracy: 1e-5, "moves a quarter of the way")
        frame(tracker, time: 0.4, [observation(0.2, 0.05, longMm: 16)])
        frame(tracker, time: 0.6, [observation(0.2105, 0.05, longMm: 16)])    // 10.5 mm off: outside the 10 mm minimum
        XCTAssertEqual(tracker.pieces.count, 3)
    }

    func testThingsTooSmallOrLargeAreIgnored() {
        let tracker = PieceTracker()
        XCTAssertNil(frame(tracker, time: 0, [observation(0, 0, longMm: 3.9)])[0])
        XCTAssertNil(frame(tracker, time: 0, [observation(0, 0, longMm: 401)])[0])
        XCTAssertNotNil(frame(tracker, time: 0, [observation(0, 0, longMm: 4)])[0])
        XCTAssertEqual(tracker.pieces.count, 1)
    }

    func testUnconfirmedBlobIsPrunedAfterThreeSecondsAndConfirmedPiecesPersist() {
        let tracker = PieceTracker()
        let real = observation(0.1, 0.05), shadow = observation(0.3, 0.2)
        frame(tracker, time: 0, [real, shadow])
        frame(tracker, time: 0.2, [real, shadow])
        frame(tracker, time: 0.4, [real])
        XCTAssertEqual(tracker.pieces.count, 2)
        XCTAssertEqual(tracker.confirmed.count, 1)
        frame(tracker, time: 3.0, [])
        XCTAssertEqual(tracker.pieces.count, 2, "not yet: exactly 3 seconds")
        tracker.beginFrame()
        let removed = tracker.endFrame(time: 3.2)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(tracker.pieces.count, 1)
        XCTAssertEqual(tracker.pieces[0].position.x, 0.1, accuracy: 1e-5)
        // The confirmed piece stays however long it goes unseen.
        frame(tracker, time: 600, [])
        XCTAssertEqual(tracker.confirmed.count, 1)
        XCTAssertNotNil(tracker.piece(id: tracker.pieces[0].id))
        XCTAssertNil(tracker.piece(id: removed[0]))
        // An old unconfirmed blob seen in this very frame is kept, and can still be confirmed.
        let late = PieceTracker()
        frame(late, time: 0, [shadow])
        frame(late, time: 5, [shadow])
        XCTAssertEqual(late.pieces.count, 1)
        frame(late, time: 5.2, [shadow])
        XCTAssertEqual(late.confirmed.count, 1)
        late.reset()
        XCTAssertTrue(late.pieces.isEmpty)
    }

    func testRunningMediansKeepTheLatestSamples() {
        let tracker = PieceTracker()
        // One wild measurement does not move the median.
        for (i, long) in [Float(16), 16.4, 40, 15.8, 16.2].enumerated() {
            frame(tracker, time: Double(i), [observation(0.1, 0.05, longMm: long, shortMm: long / 2, rgb: [UInt8(100 + i), 50, 60])])
        }
        let piece = tracker.pieces[0]
        XCTAssertEqual(piece.longMm, 16.2)
        XCTAssertEqual(piece.shortMm, 8.1)
        XCTAssertEqual(piece.rgbHex, "66323c")
        // Only the last 25 samples count.
        for i in 0..<25 { frame(tracker, time: 10 + Double(i), [observation(0.1, 0.05, longMm: 32, shortMm: 16, rgb: [0, 0, 255])]) }
        XCTAssertEqual(piece.longSamples.count, 25)
        XCTAssertEqual(piece.longMm, 32)
        XCTAssertEqual(piece.rgbHex, "0000ff")
        XCTAssertEqual(piece.sightings, 30)
    }

    func testShouldClassify() {
        let tracker = PieceTracker()
        let camera = SIMD3<Float>(0.1, 0.4, 0.05)
        let piece = frame(tracker, time: 0, [observation(0.1, 0.05)])[0]!
        XCTAssertFalse(tracker.shouldClassify(piece, cameraPosition: camera), "not confirmed yet")
        frame(tracker, time: 0.2, [observation(0.1, 0.05)])
        frame(tracker, time: 0.4, [observation(0.1, 0.05)])
        XCTAssertTrue(tracker.shouldClassify(piece, cameraPosition: camera))
        piece.addDeviceView(logProbabilities: [-1, -2], cameraPosition: camera)
        XCTAssertFalse(tracker.shouldClassify(piece, cameraPosition: camera + SIMD3(0.02, 0, 0)), "camera has barely moved")
        XCTAssertTrue(tracker.shouldClassify(piece, cameraPosition: camera + SIMD3(0.031, 0, 0)))
        for i in 1..<8 { piece.addDeviceView(logProbabilities: [-1, -2], cameraPosition: camera + SIMD3(Float(i), 0, 0)) }
        XCTAssertEqual(piece.deviceViews, 8)
        XCTAssertEqual(piece.logSum, [-8, -16])
        XCTAssertFalse(tracker.shouldClassify(piece, cameraPosition: camera + SIMD3(20, 0, 0)), "eight views are enough")
        piece.addDeviceView(logProbabilities: [-1], cameraPosition: camera)
        XCTAssertEqual(piece.deviceViews, 8, "a view of the wrong length is ignored")
    }

    func testShouldSubmit() {
        let tracker = PieceTracker()
        let camera = SIMD3<Float>(0.1, 0.4, 0.05)
        let piece = frame(tracker, time: 0, [observation(0.1, 0.05, quality: 100)])[0]!
        XCTAssertFalse(tracker.shouldSubmit(piece, quality: 100, cameraPosition: camera), "not confirmed yet")
        frame(tracker, time: 0.2, [observation(0.1, 0.05, quality: 40)])
        frame(tracker, time: 0.4, [observation(0.1, 0.05, quality: 59)])
        XCTAssertEqual(piece.bestQuality, 100)
        XCTAssertFalse(tracker.shouldSubmit(piece, quality: 59, cameraPosition: camera), "wait for a better picture")
        XCTAssertTrue(tracker.shouldSubmit(piece, quality: 61, cameraPosition: camera))

        // First view sent: the second needs the camera to have moved 8 cm.
        piece.inFlight += 1
        piece.lastSubmitCamera = camera
        XCTAssertFalse(tracker.shouldSubmit(piece, quality: 100, cameraPosition: camera + SIMD3(0.05, 0, 0)))
        XCTAssertTrue(tracker.shouldSubmit(piece, quality: 100, cameraPosition: camera + SIMD3(0.081, 0, 0)))
        // Two views answered or under way: no more.
        piece.inFlight -= 1
        piece.addServerView(scores: [("3001", 0.8), ("3002", 0.1)])
        piece.inFlight += 1
        XCTAssertFalse(tracker.shouldSubmit(piece, quality: 100, cameraPosition: camera + SIMD3(1, 0, 0)))
        piece.inFlight -= 1
        piece.addServerView(scores: [("3001", 0.6)])
        XCTAssertEqual(piece.views, 2)
        XCTAssertEqual(piece.averageScore("3001"), 0.7, accuracy: 1e-9)
        XCTAssertEqual(piece.averageScore("3002"), 0.05, accuracy: 1e-9)
        XCTAssertEqual(piece.averageScore("9999"), 0)

        // A poor picture is sent anyway once the piece has been seen ten times.
        let patient = PieceTracker()
        let other = frame(patient, time: 0, [observation(0.1, 0.05, quality: 100)])[0]!
        for i in 1..<9 { frame(patient, time: Double(i) * 0.2, [observation(0.1, 0.05, quality: 10)]) }
        XCTAssertFalse(patient.shouldSubmit(other, quality: 10, cameraPosition: camera))
        frame(patient, time: 2, [observation(0.1, 0.05, quality: 10)])
        XCTAssertTrue(patient.shouldSubmit(other, quality: 10, cameraPosition: camera))
        // Two failed requests: give up.
        other.failures = 2
        XCTAssertFalse(patient.shouldSubmit(other, quality: 100, cameraPosition: camera))
    }

    func testViewQuality() {
        let centre = DetectedBlob(minX: 0, minY: 0, maxX: 0, maxY: 0, area: 1000, cx: 320, cy: 240, major: 1, minor: 1, r: 0, g: 0, b: 0)
        var corner = centre
        corner.cx = 0; corner.cy = 0
        XCTAssertEqual(PieceTracker.viewQuality(of: centre, frameWidth: 640, frameHeight: 480), 1000)
        XCTAssertEqual(PieceTracker.viewQuality(of: corner, frameWidth: 640, frameHeight: 480), 500)
    }
}
